# Runbook : rotation manuelle de `arkcloud_app` (Postgres Azure) via Kudu

Voir ADR-0010 (`ArkCloud/docs/adr/0010-bootstrap-arkcloud-app-azure-kudu.md`) pour le contexte et
les raisons de ce choix. Ce document couvre uniquement les étapes opérationnelles.

**Fréquence** : tous les 90 jours (voir `.github/secrets-inventory.json`, entrée
`ArkCloudAppRole--Password (Azure)`).

**Pré-requis** : le conteneur `app-arkcloud-api-dev` doit tourner une image buildée après l'ajout
de `sshd` (`ArkCloud/deploy/docker/Dockerfile.api`, Sprint 6). Sans ça, Kudu SSH n'est pas
disponible — voir l'addendum du 07/09/2026 dans l'ADR-0010, qui corrige la prémisse initiale
(l'accès réseau existait déjà, mais pas `sshd` lui-même).

## Étapes

1. **Générer le nouveau mot de passe** (localement, jamais à la main) :
   ```powershell
   # PowerShell -- 32 caracteres aleatoires, alphanumerique + symboles surs pour une chaine de connexion Postgres
   -join ((48..57)+(65..90)+(97..122)+(33,35,37,40,41,42,43,45) | Get-Random -Count 32 | ForEach-Object {[char]$_})
   ```

2. **Ouvrir la console Kudu** de `app-arkcloud-api-dev` :
   `https://app-arkcloud-api-dev.scm.azurewebsites.net/webssh/host`
   (authentification via le portail Azure / Azure AD, pas de credentials séparés à gérer).

3. **Dans la session SSH**, recréer le fichier de script directement dans le conteneur (il ne vit
   pas dans l'image `ArkCloud.API` — voir note ci-dessous — donc pas de chemin tout fait à
   invoquer) puis l'exécuter. Coller le contenu à jour de
   `ArkCloudInfra/scripts/sql/bootstrap-arkcloud-app-role.sql` via un heredoc :
   ```sh
   cat > /tmp/bootstrap-arkcloud-app-role.sql <<'EOF'
   -- (coller ici le contenu exact du fichier scripts/sql/bootstrap-arkcloud-app-role.sql)
   EOF

   psql "host=<host-postgres-azure> port=5432 dbname=arkcloud user=arkcloudadmin sslmode=require" \
        -v app_password='<le-nouveau-mot-de-passe-genere-a-l-etape-1>' \
        -f /tmp/bootstrap-arkcloud-app-role.sql
   ```
   Le mot de passe admin (`arkcloudadmin`) est demandé interactivement par `psql` — le récupérer
   depuis Key Vault (`POSTGRES_ADMIN_PASSWORD (Azure)`), jamais en clair dans une commande ou un
   fichier.

   Note (tranché le 11/09/2026, vérifié en conditions réelles) : `/app` ne contient que le
   binaire publié de `ArkCloud.API` (confirmé par `ls /app` dans une vraie session Kudu), pas de
   dossier `scripts`. Délibérément **pas** embarqué dans l'image via le Dockerfile — ça créerait
   une seconde copie du script à tenir synchronisée avec l'original dans `ArkCloudInfra`, le même
   risque de duplication déjà évité côté AWS (voir le commentaire dans
   `modules/aws/secret-rotation/lambda/rotate.py`, `_set_secret_app_role`). Le copier-coller
   manuel à chaque rotation (tous les 90 jours) est un coût acceptable pour éviter ce risque.

4. **Mettre à jour le secret applicatif** — le mot de passe généré à l'étape 1 doit être écrit là
   où `ArkCloud.API` le lit réellement (Key Vault, référence `arkcloud-app-role-password` ou
   équivalent — confirmer le nom exact dans `environments/dev/main.tf`), puis forcer un restart de
   `app-arkcloud-api-dev` pour qu'il relise la configuration.

5. **Vérifier** : l'API répond toujours (`/health`), et les logs applicatifs ne montrent aucune
   erreur d'authentification Postgres dans les minutes qui suivent le restart.

6. **Mettre à jour** `.github/secrets-inventory.json` (`last_rotated`) — c'est ce fichier, pas la
   mémoire de qui a fait la rotation, qui fait foi pour le rappel automatique
   (`secret-expiry-check.yml`).

## Statut

**Étapes 2-3 vérifiées en conditions réelles le 11/09/2026** : session Kudu ouverte sur
`app-arkcloud-api-dev` (`SSH CONNECTION ESTABLISHED`, prompt `root@<container-id>:~#`), `psql
--version` répond (16.5, Ubuntu 24.04). Deux bugs réels trouvés et corrigés au passage, pas juste
une hypothèse validée du premier coup :
- Le premier commit ajoutant `sshd` n'a déclenché **aucun run CI** (filtre `paths` du workflow
  backend limité à `backend/**`, ne couvrait pas `deploy/docker/**`) — corrigé.
- Trivy a bloqué le build suivant : les clés hôte SSH générées par le postinst `openssh-server`
  au moment du `apt-get install` étaient gravées dans le layer de l'image (secret HIGH severity,
  partagé entre toute instance dérivée) — corrigé en les régénérant au démarrage du conteneur
  (`ssh-keygen -A` dans `start-api.sh`) plutôt qu'au build.
- Après un déploiement "Success", l'App Service Azure tournait toujours l'ancienne image : rien
  ne force jamais un re-pull sur un tag flottant inchangé côté Azure (contrairement à ECS, qui a
  `force-new-deployment`) — corrigé en ajoutant un `az webapp restart` explicite à
  `deploy-on-image.yml`. Un simple `restart` s'est révélé insuffisant en pratique (conteneur
  réutilisé "chaud" sur le même worker) ; un `stop`/`start` complet a été nécessaire pour forcer
  le re-pull réel.

**Rotation complète réussie le 11/09/2026** : script SQL exécuté via Kudu (`ALTER ROLE` + 4
`GRANT` + 2 `ALTER DEFAULT PRIVILEGES`, sans erreur), `ConnectionStrings--DefaultConnection` mis à
jour dans Key Vault, `app-arkcloud-api-dev` redémarré, `/health` vérifié (200 OK).
`.github/secrets-inventory.json` mis à jour (`last_rotated: 2026-09-11`). L'ADR-0010 est
pleinement close — Kudu est maintenant le mécanisme de facto, le Function App
(`modules/azure/functions-experiment`) peut être démonté au prochain ménage.

**Deux bugs de script SQL trouvés en route** (corrigés dans
`scripts/sql/bootstrap-arkcloud-app-role.sql`) :
- `psql` ne substitue pas `:'variable'` à l'intérieur d'un bloc `DO $$ ... $$` (le corps est
  lexicalement opaque à psql) — remplacé par `\gset` + `\if`/`\else`/`\endif`, qui ne sont pas
  dollar-quotés.
- Une commande `-c` tapée/collée à la main dans le terminal web Kudu s'est révélée peu fiable
  (risque de coquille manuelle, ex. `=` au lieu de `:`, ou paste multi-lignes cassé par le
  terminal) — préférer systématiquement `-f /tmp/<script>.sql` avec le contenu collé une seule
  fois via heredoc, plutôt que de retaper des commandes SQL à la main entre deux tentatives.

**Leçon opérationnelle** (pas un bug de code, un vrai risque process) : plusieurs valeurs de mot
de passe générées pendant cette première rotation ont fini exposées en clair dans la conversation
avec l'assistant, par copier-coller répété — traitées comme grillées et regénérées à chaque fois,
jusqu'à la validation finale par `/health`. Prochaine rotation : ne jamais faire transiter la
valeur d'un secret par un canal de discussion, même accidentellement — se limiter à des
confirmations "ok"/"erreur" entre chaque étape.
