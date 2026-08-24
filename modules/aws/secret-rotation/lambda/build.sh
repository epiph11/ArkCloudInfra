#!/usr/bin/env bash
# Construit le package de déploiement de la Lambda de rotation.
#
# Source unique de vérité : appelé par la CI (.github/workflows/terraform-ci.yml, jobs validate
# ET apply) et documenté pour l'usage local (voir README.md à côté). Dupliquer ces commandes
# ailleurs ferait diverger les deux chemins, ce qui est précisément le problème que la
# reproductibilité ci-dessous cherche à éviter.
#
# --- Pourquoi ce build doit être REPRODUCTIBLE -------------------------------------------------
# modules/aws/secret-rotation référence le zip via filebase64sha256(). Si deux constructions du
# même code produisent deux hashes différents, Terraform voit la Lambda comme modifiée à chaque
# fois que le build change de machine — un apply local puis un apply CI se contrediraient
# indéfiniment. C'est exactement le flip-flop rencontré (et corrigé) sur la règle de security
# group de ce même module : deux sources d'autorité pour un seul objet.
#
# Trois sources de non-déterminisme sont donc neutralisées :
#   1. la version de la dépendance      -> épinglée exactement
#   2. les dates de modification        -> normalisées à une date fixe avant l'archivage
#   3. l'ordre des fichiers dans le zip -> tri explicite, et -X pour ne pas stocker
#                                          d'attributs spécifiques à la plateforme
set -euo pipefail

cd "$(dirname "$0")"

# Épinglée : une montée de version silencieuse changerait le hash sans qu'aucun code n'ait bougé.
# À faire évoluer délibérément, en connaissant l'effet (un apply qui met à jour la fonction).
PSYCOPG2_VERSION="2.9.10"

# Détection de l'interpréteur Python — on VÉRIFIE qu'il s'exécute, on ne se contente pas de sa
# présence dans le PATH. Sous Windows, `command -v python` trouve le stub du Microsoft Store, qui
# masque une installation réelle : il est bien dans le PATH, mais affiche un message d'aide au
# lieu d'exécuter quoi que ce soit. Tester `-c "import sys"` élimine ce cas.
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

# Les contraintes de plateforme ne sont pas optionnelles : sans elles, pip produit une wheel pour
# la machine de build et non pour le runtime Lambda (Amazon Linux, x86_64, Python 3.12). L'erreur
# d'import ne se manifesterait qu'à la première rotation réelle, dans 90 jours.
"$PY" -m pip install \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  --target build/package \
  "psycopg2-binary==${PSYCOPG2_VERSION}"

# Fins de ligne forcées en LF plutôt qu'un simple `cp` : sous Windows, Git peut checkouter
# rotate.py en CRLF (core.autocrlf), et le même code source produirait alors un zip différent
# de celui construit sur le runner Linux. .gitattributes couvre le cas au checkout ; ceci le
# couvre aussi pour un dépôt cloné avant son ajout, ou avec une configuration Git locale
# divergente. Constaté pour de vrai : premier build CI vs local, hashes différents.
tr -d '\r' < rotate.py > build/package/rotate.py

# Le bytecode compilé n'est pas nécessaire à l'exécution et son contenu varie — il ferait varier
# le hash sans raison.
find build/package -name '__pycache__' -type d -prune -exec rm -rf {} +
find build/package -name '*.pyc' -delete

# Cause RÉELLE de la divergence local/CI, trouvée via le manifeste par fichier (pas devinée) :
# psycopg2_binary-2.9.10.dist-info/RECORD différait entre un build local (Python 3.14.6) et un
# build CI — SEUL fichier différent sur les 34, rotate.py compris (hash identique des deux
# côtés). RECORD n'est pas du contenu téléchargé de PyPI : pip le GÉNÈRE lui-même à
# l'installation, et deux versions de pip le formatent différemment. La théorie CRLF
# (.gitattributes, tr -d '\r' sur rotate.py) était donc fausse depuis le début — rotate.py
# n'a jamais divergé. Rien dans *.dist-info (RECORD, INSTALLER, METADATA, WHEEL, LICENSE,
# REQUESTED, top_level.txt) n'est lu à l'exécution par le runtime Lambda — uniquement par pip
# pour la désinstallation/mise à jour, inutile ici. Le supprimer élimine la source de
# non-déterminisme au lieu d'essayer de la neutraliser fichier par fichier.
find build/package -maxdepth 1 -iname '*.dist-info' -type d -exec rm -rf {} +

# Archivage via le module zipfile de Python plutôt que le binaire `zip` : ce dernier n'est pas
# livré avec Git Bash sous Windows, et surtout Python permet de fixer explicitement date,
# permissions et ordre des entrées — ce qui rend le zip identique octet pour octet quelle que
# soit la plateforme. Compress-Archive (PowerShell) et `zip` (Linux) ne produisent PAS le même
# flux d'octets pour un même contenu, ce qui suffirait à recréer le flip-flop qu'on cherche
# précisément à éviter.
"$PY" - "$PWD/build/package" "$PWD/build/rotate.zip" <<'PYEOF'
import hashlib, os, sys, zipfile

src, dst = sys.argv[1], sys.argv[2]

# Date fixe et arbitraire — seule sa stabilité compte, pas sa valeur.
FIXED_DATE = (2026, 1, 1, 0, 0, 0)

paths = []
for root, dirs, files in os.walk(src):
    dirs.sort()
    for f in sorted(files):
        full = os.path.join(root, f)
        rel = os.path.relpath(full, src).replace(os.sep, "/")
        paths.append((rel, full))
paths.sort(key=lambda p: p[0])

with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for rel, full in paths:
        info = zipfile.ZipInfo(rel, date_time=FIXED_DATE)
        # Permissions figées : celles du système de fichiers local varient (Windows vs Linux)
        # et seraient sinon stockées telles quelles dans l'archive.
        info.external_attr = 0o644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3  # Unix, quel que soit l'OS de build
        with open(full, "rb") as fh:
            z.writestr(info, fh.read())

# Empreinte par fichier, pas seulement du zip final : quand deux plateformes produisent des
# hashes différents, cette liste localise immédiatement LE fichier responsable au lieu de
# laisser deviner. Écrite dans build/manifest.txt, et non affichée en entier — quelques
# centaines de lignes pollueraient les logs CI pour rien.
manifest = os.path.join(os.path.dirname(dst), "manifest.txt")
with open(manifest, "w", newline="\n") as mf:
    for rel, full in paths:
        h = hashlib.sha256(open(full, "rb").read()).hexdigest()
        mf.write(f"{h}  {rel}\n")

print(f"{len(paths)} fichiers archivés")
print("manifest :", manifest)
print("sha256 :", hashlib.sha256(open(dst, "rb").read()).hexdigest())
PYEOF

test -f build/rotate.zip
