#!/usr/bin/env bash
# Construit le package de déploiement de la Lambda de purge RGPD.
#
# Copie quasi identique de modules/aws/secret-rotation/lambda/build.sh — même besoin exact
# (vendoriser psycopg2-binary pour le runtime Lambda Python, produire un zip reproductible
# octet pour octet). Voir ce script pour le détail de chaque choix ; les commentaires ne sont
# pas dupliqués ligne à ligne ici pour éviter que les deux copies divergent silencieusement au
# fil des correctifs — se référer à l'original en cas de doute sur le "pourquoi".
set -euo pipefail

cd "$(dirname "$0")"

PSYCOPG2_VERSION="2.9.10"

PY=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys; sys.exit(0)" >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "Aucun interpréteur Python fonctionnel trouvé (essayés : python3, python, py)." >&2
  echo "Requis pour pip et pour l'archivage déterministe." >&2
  echo "Sous Windows : installer Python depuis python.org, pas le stub du Microsoft Store." >&2
  exit 1
fi

echo "Interpréteur Python : $PY ($("$PY" --version 2>&1))"

rm -rf build
mkdir -p build/package

"$PY" -m pip install \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  --target build/package \
  "psycopg2-binary==${PSYCOPG2_VERSION}"

tr -d '\r' < purge.py > build/package/purge.py

find build/package -name '__pycache__' -type d -prune -exec rm -rf {} +
find build/package -name '*.pyc' -delete
find build/package -maxdepth 1 -iname '*.dist-info' -type d -exec rm -rf {} +

"$PY" - "$PWD/build/package" "$PWD/build/purge.zip" <<'PYEOF'
import hashlib, os, sys, zipfile

src, dst = sys.argv[1], sys.argv[2]

FIXED_DATE = (2026, 1, 1, 0, 0, 0)

paths = []
for root, dirs, files in os.walk(src):
    dirs.sort()
    for f in sorted(files):
        full = os.path.join(root, f)
        rel = os.path.relpath(full, src).replace(os.sep, "/")
        paths.append((rel, full))
paths.sort(key=lambda p: p[0])

with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_STORED) as z:
    for rel, full in paths:
        info = zipfile.ZipInfo(rel, date_time=FIXED_DATE)
        info.external_attr = 0o644 << 16
        info.compress_type = zipfile.ZIP_STORED
        info.create_system = 3
        with open(full, "rb") as fh:
            z.writestr(info, fh.read())

manifest = os.path.join(os.path.dirname(dst), "manifest.txt")
with open(manifest, "w", newline="\n") as mf:
    for rel, full in paths:
        h = hashlib.sha256(open(full, "rb").read()).hexdigest()
        mf.write(f"{h}  {rel}\n")

print(f"{len(paths)} fichiers archivés")
print("manifest :", manifest)
print("sha256 :", hashlib.sha256(open(dst, "rb").read()).hexdigest())
PYEOF

test -f build/purge.zip
