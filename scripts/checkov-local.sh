#!/usr/bin/env bash
# Fait tourner Checkov en local, avec exactement la même image et la même liste de skip que la
# CI (.github/workflows/terraform-ci.yml) — pas une copie qu'on pourrait oublier de tenir à jour :
# la liste de skip est extraite directement du fichier de workflow à chaque exécution.
#
# Pourquoi ça manquait : `terraform plan` en local valide la syntaxe et l'état, mais ne dit rien
# sur la posture sécurité — Checkov ne tournait qu'en CI, donc chaque finding se découvrait après
# un push plutôt qu'avant.
set -euo pipefail

cd "$(dirname "$0")/.."

CHECKOV_IMAGE="ghcr.io/bridgecrewio/checkov:3.3.13"
WORKFLOW_FILE=".github/workflows/terraform-ci.yml"
ENVIRONMENT="${1:-dev}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker introuvable — Checkov tourne dans un conteneur pour éviter d'installer une" >&2
  echo "version Python locale de Checkov qui pourrait diverger de celle de la CI (même" >&2
  echo "principe que le fix de reproductibilité du build Lambda : une seule source de vérité," >&2
  echo "pas deux chemins qui peuvent dériver l'un de l'autre)." >&2
  exit 1
fi

# Extrait le bloc skip_check du workflow (entre "skip_check: >-" et la prochaine étape) plutôt
# que de dupliquer la liste ici — sinon les deux listes divergent tôt ou tard, exactement le
# genre de double source de vérité qu'on a appris à éviter ce sprint (voir le commentaire sur
# aws_sns_topic_policy.alerts dans environments/dev/main.tf pour un autre exemple du même principe).
#
# tr -d '\n ' supprime les retours à la ligne ET tous les espaces en un seul passage — pas juste
# les compresser ou trimmer les extrémités. Bug réel rencontré avec une version plus prudente de
# cette ligne (squeeze + trim des bords seulement) : chaque ID qui commençait une nouvelle ligne
# dans le YAML gardait un espace devant (" CKV_AZURE_189" au lieu de "CKV_AZURE_189"), Checkov
# comparait la chaîne telle quelle, l'ID ne matchait jamais, et la moitié des skips de la CI ne
# s'appliquait pas en local — silencieusement, en faisant échouer des checks déjà arbitrés.
# Aucun ID de check Checkov ne contient d'espace, donc les supprimer tous est toujours sûr ici.
SKIP_CHECK=$(awk '/skip_check: >-/{flag=1; next} /^\s*- name:/{flag=0} flag' "$WORKFLOW_FILE" \
  | tr -d '\n ')

if [ -z "$SKIP_CHECK" ]; then
  echo "Impossible d'extraire skip_check depuis $WORKFLOW_FILE — vérifier que le format n'a" >&2
  echo "pas changé (le script cherche la ligne 'skip_check: >-' suivie du bloc indenté)." >&2
  exit 1
fi

echo "Image Checkov : $CHECKOV_IMAGE"
echo "Environnement : environments/$ENVIRONMENT"
echo "Skip check    : $SKIP_CHECK"
echo

# MSYS_NO_PATHCONV=1 : sous Git Bash (Windows), MSYS traduit automatiquement tout argument
# commençant par "/" en chemin Windows avant de l'exécuter — y compris "/tf" ci-dessous, qui
# doit rester un chemin LITTÉRAL à l'intérieur du conteneur Linux, pas un chemin de l'hôte.
# Sans ça, "-w /tf" devient quelque chose comme "C:/Program Files/Git/tf" et docker échoue
# avec "the working directory ... is invalid". Sans effet sous Linux/macOS (variable
# simplement ignorée), donc sûr de laisser toujours actif plutôt que de le conditionner à l'OS.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$PWD:/tf" \
  -w /tf \
  "$CHECKOV_IMAGE" \
  -d "environments/$ENVIRONMENT" \
  --framework terraform \
  --skip-check "$SKIP_CHECK" \
  --compact
