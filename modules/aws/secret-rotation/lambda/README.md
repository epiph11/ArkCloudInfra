# Build du package de rotation

`rotate.py` importe `psycopg2`, qui n'est **pas** fourni par le runtime Python de Lambda (contrairement à `boto3`). Le package de déploiement doit donc être construit une fois avant le premier `terraform apply` de ce module, et reconstruit à chaque modification de `rotate.py`.

Pourquoi ce n'est pas fait par Terraform via `local-exec` : ça rendrait `terraform plan` dépendant de la présence de `pip`/Docker sur la machine qui l'exécute — y compris le runner CI — ce qui casse plus souvent et plus discrètement qu'une commande de build documentée.

## Construire

Une seule commande, un seul script — `build.sh`, également utilisé par la CI (`terraform-ci.yml`, jobs `validate` **et** `apply`). Ne pas réécrire ces étapes à la main ailleurs : deux chemins de build qui divergent produisent deux hashes différents, donc un flip-flop Terraform.

```bash
bash modules/aws/secret-rotation/lambda/build.sh
```

Sous Windows, via Git Bash (`& "C:\Program Files\Git\bin\bash.exe" ...`). Le script affiche le SHA-256 du zip produit : **il doit être identique en local et en CI**. S'il diffère, le build a cessé d'être reproductible et Terraform verra la Lambda changer un apply sur deux.

**Hash de référence** — avec `psycopg2-binary==2.9.10`, `rotate.py` dans son état actuel, `*.dist-info` supprimé et l'archivage en `ZIP_STORED` (voir historique ci-dessous), à régénérer et comparer au prochain build des deux côtés — pas encore stabilisé au moment d'écrire ceci. Cette valeur doit changer **uniquement** quand `rotate.py` ou la version épinglée changent. Si elle bouge sans qu'aucun des deux n'ait été touché, la reproductibilité est cassée — chercher la cause plutôt que mettre à jour cette ligne. Toujours comparer au manifeste publié par la CI avant de considérer une valeur comme confirmée des deux côtés — un `terraform plan` vide seul ne suffit pas (voir pourquoi ci-dessous).

**Historique du diagnostic (pour ne pas répéter les mêmes fausses pistes)** — trois hypothèses successives, chacune tranchée par une preuve directe plutôt que supposée corrigée :
1. Fins de ligne CRLF sur `rotate.py` (fix `.gitattributes` + `tr -d '\r'`) — sans effet réel, `rotate.py` était déjà identique des deux côtés.
2. Un `terraform plan` vide observé en CI, pris pour une preuve de reproductibilité — à tort : il comparait le build de la CI à un state que la CI elle-même avait posé lors d'un apply précédent, pas au build local, donc ne prouvait rien sur la divergence local/CI.
3. `psycopg2_binary-2.9.10.dist-info/RECORD` — trouvé via le manifeste par fichier, seul fichier différent sur 34, formaté différemment selon la version de pip qui le génère. Fixé en supprimant tout `*.dist-info` (rien dedans n'est lu par le runtime Lambda).

Après le fix #3, un nouveau manifeste comparé des deux côtés a montré les **27 fichiers restants strictement identiques** — `rotate.py` compris — et pourtant le zip final différait toujours. Ça élimine tout le contenu comme cause possible et pointe vers l'archivage lui-même : `zipfile` compresse via `zlib`, et `zlib` ne garantit PAS un flux DEFLATE identique bit à bit entre deux versions/plateformes pour un même contenu source (documenté sur reproducible-builds.org) — le contenu décompressé est identique, les octets compressés dans le zip ne le sont pas. Fixé en passant l'archivage en `ZIP_STORED` (pas de compression) plutôt qu'en essayant de figer une version de zlib. Coût négligeable ici : le package fait quelques Mo, largement sous la limite Lambda de 50 Mo pour un upload direct.

### Pourquoi un script plutôt que des commandes documentées

Le module référence le zip via `filebase64sha256()`. Ces sources de non-déterminisme feraient varier ce hash sans qu'aucune ligne de code n'ait bougé, et le script les neutralise explicitement :

| Source | Neutralisation |
|---|---|
| Version de `psycopg2-binary` résolue par pip | Épinglée exactement dans le script |
| Dates de modification des fichiers | Normalisées à une date fixe avant l'archivage |
| Ordre des fichiers et attributs de plateforme dans le zip | Liste triée + archiveur Python (`zipfile`), pas le binaire `zip` |
| Métadonnées `*.dist-info` générées par pip (RECORD notamment) | Dossier supprimé entièrement après l'installation |
| Flux DEFLATE non garanti identique entre versions de `zlib` | `ZIP_STORED` (pas de compression) plutôt que `ZIP_DEFLATED` — cause confirmée de la divergence restante, voir ci-dessus |

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

## Deuxième instance — mode `app` (rôle `arkcloud_app`, Sprint 6)

`environments/dev/main.tf` instancie ce module une seconde fois (`module.aws_secret_rotation_app_role`, `target_role = "app"`) pour le rôle applicatif à moindre privilège `arkcloud_app` (remédiation STRIDE « Elevation of privilege », flux 3). Un seul `rotate.py`, une seule branche de code activée par la variable d'environnement `TARGET_ROLE` — donc un seul build (`build.sh` ci-dessus) sert les deux fonctions Lambda, pas de package séparé à construire.

Cette instance **crée le rôle** au lieu de simplement changer son mot de passe, la toute première fois qu'elle tourne — pas de script SQL séparé à exécuter à la main. Suivre le premier run :

```powershell
aws logs tail /aws/lambda/secret-rotation-arkcloud-dev-app --follow
```

`setSecret` doit afficher soit `created role arkcloud_app (bootstrap, first rotation)` (premier apply), soit `altered password for existing role arkcloud_app` (rotations suivantes). Si `testSecret` échoue ici, c'est que `arkcloud_app` n'a pas pu s'authentifier avec le nouveau mot de passe — le rôle reste tel qu'il était avant cette tentative, rien n'est promu.

Cette instance ne redémarre aucun service ECS (`ECS_CLUSTER`/`ECS_SERVICE` non configurés tant que `ConnectionStrings__DefaultConnection` ne pointe pas encore vers `arkcloud_app` — voir `docs/infra-roadmap.md`, étape 4 du découpage) : `finishSecret` promeut simplement la version, sans redéploiement.
