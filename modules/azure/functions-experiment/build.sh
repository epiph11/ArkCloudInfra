#!/usr/bin/env bash
# Zips src/ into build/function.zip -- NOT deployed by Terraform (see main.tf's comment on why
# zip_deploy_file isn't used: real, currently-open azurerm provider bug, wrong endpoint for Flex
# Consumption). Deploy this zip yourself after `terraform apply` succeeds:
#
#   az functionapp deployment source config-zip \
#     --resource-group rg-arkcloud-dev \
#     --name func-arkcloud-dev-app-role-experiment \
#     --src modules/azure/functions-experiment/build/function.zip \
#     --build-remote true
#
# --build-remote true is what actually triggers Azure's remote builder (Oryx) to run
# `pip install -r requirements.txt` against the real Linux/Python 3.11 target -- so this zip only
# needs the three source files, no dependencies, no reproducibility concerns (unlike the AWS
# Lambda zip in modules/aws/secret-rotation/lambda/build.sh, this one isn't referenced by a
# content hash, so nothing here needs to be byte-for-byte deterministic).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

rm -rf build
mkdir -p build

# `zip` isn't on PATH in a stock Git Bash on Windows (unlike WSL/Linux/macOS) -- same category
# of cross-environment gap as the RandomNumberGenerator.Fill() and PowerShell encoding issues
# already hit elsewhere in this project. Three fallbacks, in order of preference; the last one
# (PowerShell's Compress-Archive) needs nothing pre-installed, since it ships with Windows
# itself -- that's deliberately the most reliable rung of this ladder, not the first choice,
# since it's slower to invoke than a native zip/python call.
# `command -v python` can find a WORKING stub even when Python isn't really installed --
# Windows' "App Execution Alias" puts a python.exe/python3.exe placeholder on PATH that opens
# the Microsoft Store instead of running anything. Checking `--version` actually succeeds is
# the only reliable test; `command -v` alone was tried first here and false-positived on it.
python_bin=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" --version >/dev/null 2>&1; then
        python_bin="$candidate"
        break
    fi
done

if command -v zip >/dev/null 2>&1; then
    (cd src && zip -r ../build/function.zip host.json requirements.txt function_app.py)
elif [ -n "$python_bin" ]; then
    echo "==> 'zip' not found on PATH, using Python's zipfile module instead."
    "$python_bin" -c "
import zipfile
with zipfile.ZipFile('build/function.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for name in ('host.json', 'requirements.txt', 'function_app.py'):
        z.write(f'src/{name}', name)
"
else
    echo "==> Neither 'zip' nor a working Python found on PATH, using PowerShell's Compress-Archive instead."
    powershell.exe -NoProfile -Command "Compress-Archive -Path 'src\\host.json','src\\requirements.txt','src\\function_app.py' -DestinationPath 'build\\function.zip' -Force"
fi

echo "==> Built build/function.zip"
