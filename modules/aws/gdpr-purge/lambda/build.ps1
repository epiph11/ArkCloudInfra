# Equivalent PowerShell de build.sh, pour les machines sans bash fonctionnel (WSL absent/casse,
# pas de Git Bash). Meme logique : vendoriser psycopg2-binary pour le runtime Lambda Python,
# produire un zip deterministe (ZIP_STORED, date fixe, ordre trie) via le module zipfile de Python
# -- voir build.sh pour le detail complet de chaque choix, non duplique ici.
#
# Note : ce zip n'est pas garanti octet-pour-octet identique a celui que produira build.sh en CI
# (differences possibles de version pip/OS). Suffisant pour un `terraform apply` local ; le
# prochain apply déclenché par la CI verra potentiellement la Lambda comme "modifiee" une fois --
# sans consequence, juste un redeploiement du meme code.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$PsycopgVersion = "2.9.10"

$py = $null
foreach ($candidate in @("python3", "python", "py")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            & $candidate -c "import sys; sys.exit(0)" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $py = $candidate; break }
        } catch {}
    }
}
if (-not $py) {
    Write-Error "Aucun interpreteur Python fonctionnel trouve (essayes : python3, python, py). Installer Python depuis python.org (pas le stub du Microsoft Store)."
    exit 1
}
Write-Host "Interpreteur Python : $py ($(& $py --version 2>&1))"

if (Test-Path build) { Remove-Item -Recurse -Force build }
New-Item -ItemType Directory -Force -Path build/package | Out-Null

& $py -m pip install `
    --platform manylinux2014_x86_64 `
    --implementation cp `
    --python-version 3.12 `
    --only-binary=:all: `
    --target build/package `
    "psycopg2-binary==$PsycopgVersion"
if ($LASTEXITCODE -ne 0) { Write-Error "pip install a echoue."; exit 1 }

# Normalise purge.py en LF (equivalent de `tr -d '\r'`), au cas ou Git l'aurait checkoute en CRLF.
$content = Get-Content -Raw -Path purge.py
$content = $content -replace "`r`n", "`n"
[System.IO.File]::WriteAllText("build/package/purge.py", $content)

Get-ChildItem build/package -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Get-ChildItem build/package -Recurse -Filter "*.pyc" -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem build/package -Directory -Filter "*.dist-info" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

$zipScript = @'
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

print(f"{len(paths)} fichiers archives")
print("manifest :", manifest)
print("sha256 :", hashlib.sha256(open(dst, "rb").read()).hexdigest())
'@

$zipScriptPath = Join-Path $env:TEMP "gdpr_purge_zip_$([guid]::NewGuid().ToString('N')).py"
[System.IO.File]::WriteAllText($zipScriptPath, $zipScript)

try {
    & $py $zipScriptPath "$PWD/build/package" "$PWD/build/purge.zip"
    if ($LASTEXITCODE -ne 0) { Write-Error "La creation du zip a echoue."; exit 1 }
}
finally {
    Remove-Item $zipScriptPath -ErrorAction SilentlyContinue
}

if (-not (Test-Path build/purge.zip)) {
    Write-Error "build/purge.zip n'a pas ete cree."
    exit 1
}
Write-Host "OK : build/purge.zip cree."
