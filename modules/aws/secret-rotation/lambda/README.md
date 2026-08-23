# Build du package de rotation

`rotate.py` importe `psycopg2`, qui n'est **pas** fourni par le runtime Python de Lambda (contrairement à `boto3`). Le package de déploiement doit donc être construit une fois avant le premier `terraform apply` de ce module, et reconstruit à chaque modification de `rotate.py`.

Pourquoi ce n'est pas fait par Terraform via `local-exec` : ça rendrait `terraform plan` dépendant de la présence de `pip`/Docker sur la machine qui l'exécute — y compris le runner CI — ce qui casse plus souvent et plus discrètement qu'une commande de build documentée.

## Construire (PowerShell, depuis ce dossier)

```powershell
# Nettoyer un build précédent
Remove-Item -Recurse -Force .\build -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path .\build\package | Out-Null

# psycopg2-binary compilé pour le runtime Lambda (Amazon Linux 2023, x86_64, Python 3.12) —
# PAS pour Windows : un `pip install` sans ces contraintes produirait une wheel inutilisable
# sur Lambda, avec une erreur d'import qui n'apparaîtrait qu'à la première rotation.
pip install `
  --platform manylinux2014_x86_64 `
  --implementation cp `
  --python-version 3.12 `
  --only-binary=:all: `
  --target .\build\package `
  psycopg2-binary

Copy-Item .\rotate.py .\build\package\
Compress-Archive -Path .\build\package\* -DestinationPath .\build\rotate.zip -Force
```

Le module lit `build/rotate.zip` par défaut (surchargeable via la variable `lambda_zip_path`).

## Vérifier après une rotation

Le déclenchement initial est automatique (attacher la rotation à un secret provoque une première rotation immédiate — voir le commentaire dans `main.tf`). Pour suivre :

```powershell
aws logs tail /aws/lambda/secret-rotation-arkcloud-dev --follow
```

Les quatre étapes (`createSecret`, `setSecret`, `testSecret`, `finishSecret`) doivent apparaître dans l'ordre. Si `testSecret` échoue, rien n'est promu — l'ancien mot de passe reste valide, c'est le comportement voulu.

`setSecret` affiche des lignes `waiting (status=..., password_pending=...)` : c'est normal, la modification RDS est asynchrone et la fonction attend qu'elle soit réellement appliquée (typiquement ~70 s, dont l'essentiel en `resetting-master-credentials`). **Ne pas retirer cette attente** : le tout premier run réel a échoué exactement là, sur `authentication failed`, parce que `testSecret` s'exécutait avant que RDS n'ait appliqué le mot de passe.

### Interpréter un échec de `testSecret`

Deux erreurs distinctes, deux causes sans rapport — la confusion entre les deux a coûté un diagnostic erroné lors de la mise en place :

| Erreur | Cause | Quoi faire |
|---|---|---|
| `authentication failed` | Le mot de passe n'est pas (encore) celui attendu | Vérifier que l'attente dans `setSecret` est bien en place. La fonction ne retente **pas** dans ce cas, volontairement : réessayer ne changerait rien, et échouer vite laisse l'ancien mot de passe actif. |
| `timeout expired` | La connexion n'atteint pas la base — **problème réseau, pas d'identifiants** | Vérifier en priorité que la règle d'ingress `database_from_rotation` existe bien sur `sg-database`. Une règle de security group manquante produit un *timeout*, jamais un refus — le symptôme ressemble à de la lenteur, pas à un problème de permissions. C'est précisément ce qui s'est produit ici : la règle avait disparu côté AWS et Terraform l'a recréée au refresh suivant. |

Pour forcer une rotation à la demande sans attendre 90 jours :

```powershell
aws secretsmanager rotate-secret --secret-id arkcloud/arkcloud-dev/postgres
```

**Après chaque rotation réussie**, mettre à jour `last_rotated` pour `POSTGRES_ADMIN_PASSWORD (AWS)` dans `.github/secrets-inventory.json` — sinon le check d'échéance (`secret-expiry-check.yml`) continuera de réclamer une rotation manuelle déjà faite automatiquement.
