# Build du package de rotation

`rotate.py` importe `psycopg2`, qui n'est **pas** fourni par le runtime Python de Lambda (contrairement à `boto3`). Le package de déploiement doit donc être construit une fois avant le premier `terraform apply` de ce module, et reconstruit à chaque modification de `rotate.py`.

Pourquoi ce n'est pas fait par Terraform via `local-exec` : ça rendrait `terraform plan` dépendant de la présence de `pip`/Docker sur la machine qui l'exécute — y compris le runner CI — ce qui casse plus souvent et plus discrètement qu'une commande de build documentée.

## Construire

Une seule commande, un seul script — `build.sh`, également utilisé par la CI (`terraform-ci.yml`, jobs `validate` **et** `apply`). Ne pas réécrire ces étapes à la main ailleurs : deux chemins de build qui divergent produisent deux hashes différents, donc un flip-flop Terraform.

```bash
bash modules/aws/secret-rotation/lambda/build.sh
```

Sous Windows, via Git Bash (`& "C:\Program Files\Git\bin\bash.exe" ...`). Le script affiche le SHA-256 du zip produit : **il doit être identique en local et en CI**. S'il diffère, le build a cessé d'être reproductible et Terraform verra la Lambda changer un apply sur deux.

**Hash de référence** — avec `psycopg2-binary==2.9.10`, `rotate.py` dans son état actuel, et le fix `*.dist-info` ci-dessous, construit sous Windows/Git Bash (Python 3.14.6) :

```
94eae308be13fa51c4876b7be67e49f7de976b3370d41771237c9d03282ad06b
```

Différente de l'ancienne valeur `9628696840d3...` — normal, le contenu du zip a changé (dist-info en moins), pas un problème. Cette valeur doit changer **uniquement** quand `rotate.py` ou la version épinglée changent. Si elle bouge sans qu'aucun des deux n'ait été touché, la reproductibilité est cassée — chercher la cause plutôt que mettre à jour cette ligne. **Pas encore validée contre un build CI** avec ce fix (voir l'historique du diagnostic ci-dessous pour pourquoi un plan vide seul n'est pas une preuve suffisante) — comparer explicitement au manifeste publié par la CI avant de considérer cette valeur comme confirmée des deux côtés.

**Historique du diagnostic (pour ne pas répéter les mêmes fausses pistes)** — la divergence local ↔ CI a été attribuée à tort, dans un premier temps, à des fins de ligne CRLF sur `rotate.py` (fix `.gitattributes` + `tr -d '\r'`, sans effet réel : `rotate.py` était déjà identique des deux côtés). Un `terraform plan` vide observé en CI avait ensuite été pris pour une preuve de reproductibilité — à tort aussi : il comparait le build de la CI à un state que la CI elle-même avait posé lors d'un apply précédent, pas au build local. La vraie cause, trouvée en comparant le manifeste par fichier local à celui publié par la CI (`build/manifest.txt`, un hash par fichier archivé) : un seul fichier différait sur 34, `psycopg2_binary-2.9.10.dist-info/RECORD` — pas du contenu téléchargé de PyPI, mais un fichier que **pip génère lui-même** à l'installation, formaté différemment selon la version de pip (Python 3.14.6 en local, une version différente en CI). Fixé en supprimant tout `*.dist-info` du package plutôt qu'en essayant de neutraliser ce fichier précis — rien dedans (RECORD, INSTALLER, METADATA, WHEEL, LICENSE, REQUESTED, top_level.txt) n'est lu par le runtime Lambda.

### Pourquoi un script plutôt que des commandes documentées

Le module référence le zip via `filebase64sha256()`. Ces sources de non-déterminisme feraient varier ce hash sans qu'aucune ligne de code n'ait bougé, et le script les neutralise explicitement :

| Source | Neutralisation |
|---|---|
| Version de `psycopg2-binary` résolue par pip | Épinglée exactement dans le script |
| Dates de modification des fichiers | Normalisées à une date fixe avant l'archivage |
| Ordre des fichiers et attributs de plateforme dans le zip | Liste triée + archiveur Python (`zipfile`), pas le binaire `zip` |
| Métadonnées `*.dist-info` générées par pip (RECORD notamment) | Dossier supprimé entièrement après l'installation — cause confirmée de la divergence local/CI, voir ci-dessus |

Le bytecode `.pyc` est également supprimé : inutile à l'exécution, et son contenu varie.

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
