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

3. **Dans la session SSH**, exécuter le script de bootstrap/rotation (idempotent — crée le rôle
   s'il n'existe pas encore, sinon change juste le mot de passe) :
   ```sh
   psql "host=<host-postgres-azure> port=5432 dbname=arkcloud user=arkcloudadmin sslmode=require" \
        -v app_password='<le-nouveau-mot-de-passe-genere-a-l-etape-1>' \
        -f /app/scripts/sql/bootstrap-arkcloud-app-role.sql
   ```
   Le mot de passe admin (`arkcloudadmin`) est demandé interactivement par `psql` — le récupérer
   depuis Key Vault (`POSTGRES_ADMIN_PASSWORD (Azure)`), jamais en clair dans une commande ou un
   fichier.

   Note : `scripts/sql/bootstrap-arkcloud-app-role.sql` vit dans `ArkCloudInfra`, pas dans l'image
   `ArkCloud.API` — au premier essai réel, vérifier si le script doit être copié manuellement dans
   le conteneur via la console Kudu (onglet Debug console) ou s'il vaut mieux l'ajouter au
   Dockerfile. Documenter le résultat ici une fois vérifié en conditions réelles.

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

**Non encore exécuté en conditions réelles** au moment de la rédaction de ce runbook (Sprint 6,
11/09/2026). L'image avec `sshd` doit d'abord être déployée, puis ce runbook suivi une première
fois pour valider chaque étape — en particulier l'étape 3 (chemin exact du script SQL dans le
conteneur) est une hypothèse à confirmer, pas un fait vérifié. Mettre à jour ce document et
l'ADR-0010 une fois la première rotation réelle effectuée avec succès.
