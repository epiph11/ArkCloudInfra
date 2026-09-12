# Runbook : activation du passwordless Entra ID pour `arkcloud_app` (Postgres Azure)

Voir ADR-0011 (`ArkCloud/docs/adr/0011-passwordless-auth-arkcloud-app-proposition.md`) pour le
contexte complet et le pendant déjà fait côté AWS (IAM DB auth). Ce document couvre uniquement les
étapes opérationnelles côté Azure.

**Statut au 12/09/2026** : Terraform appliqué (authentification Entra ID activée sur le serveur,
administrateur AAD désigné), étapes 1-3 exécutées en conditions réelles avec succès (principal
`app-arkcloud-api-dev` créé, `arkcloud_app` accordé) — voir bug réel rencontré et sa correction dans
la section "Bugs réels rencontrés" plus bas. Étapes 4-6 (test isolé, bascule applicative réelle,
vérification `/health`) **pas encore exécutées**.

## Pré-requis

- `terraform apply` de `modules/azure/postgresql` déjà exécuté avec `entra_admin_principal_name`
  renseigné (voir `environments/dev/variables.tf`) — sans ça, `azurerm_postgresql_flexible_server_active_directory_administrator`
  n'existe pas encore et l'étape 2 ci-dessous échouera à l'authentification.
- Azure CLI installé localement, connecté avec le même compte que celui désigné administrateur
  Entra ID du serveur (`az login`).
- `arkcloud_app` déjà créé (`scripts/sql/bootstrap-arkcloud-app-role.sql` déjà exécuté au moins une
  fois — c'est déjà le cas, fait lors du cutover STRIDE flux 3, tâche #69).
- `psql` accessible **depuis une machine à l'intérieur du VNet** (`vnet-arkcloud-dev`) — le serveur
  n'a pas d'accès public, seul un endpoint privé existe. Azure Cloud Shell (réseau Microsoft) ne
  fonctionne PAS pour ça : `could not translate host name ... Name or service not known`. Solution
  qui marche : console SSH Kudu de `app-arkcloud-api-dev` (intégré à `snet-api`), avec `psql`
  installé à la volée (`apt-get install -y postgresql-client`, conteneur éphémère) et un token AAD
  récupéré séparément depuis Cloud Shell (`az account get-access-token --resource-type oss-rdbms
  --query accessToken -o tsv`), collé manuellement en `PGPASSWORD` dans la session Kudu — pas de
  `az` CLI installé dans ce conteneur.

## Étapes

1. **Récupérer un token Entra ID pour Postgres**, localement :
   ```powershell
   $env:PGPASSWORD = az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv
   ```

2. **Se connecter en tant qu'administrateur Entra ID** (pas `arkcloudadmin`) et exécuter le
   script d'enregistrement du principal :
   ```powershell
   psql "host=<host-postgres-azure> port=5432 dbname=arkcloud user=<ton-UPN-ou-nom-SP> sslmode=require" `
        -v app_service_identity_name='app-arkcloud-api-dev' `
        -f scripts/sql/bootstrap-arkcloud-app-entra-id.sql
   ```
   `<ton-UPN-ou-nom-SP>` = la même valeur que `entra_admin_principal_name` côté Terraform.

3. **Vérifier dans le portail Azure** (Entra ID > Identités managées d'entreprise) que le nom
   d'affichage de l'identité managée système d'`app-arkcloud-api-dev` est bien exactement
   `app-arkcloud-api-dev` — sinon adapter `app_service_identity_name` à l'étape 2 avant de
   continuer (`pgaadauth_create_principal` échoue proprement si le nom ne résout à aucun objet
   AAD, pas de risque de créer un rôle orphelin par erreur de frappe).

4. **Test isolé, avant toute bascule applicative** : depuis une machine avec `az login` fait sous
   une identité qui N'A PAS accès à `oss-rdbms` normalement (pour confirmer que seule l'identité
   managée de l'App Service peut obtenir ce token en prod), ou plus simplement en ajoutant
   temporairement `Database:AuthMode=AzureAd` aux app settings d'une slot de test — vérifier une
   connexion réelle avant de toucher `app-arkcloud-api-dev` lui-même.

5. **Bascule réelle** — une fois le test validé, dans `environments/dev/main.tf`, ajouter au bloc
   `extra_app_settings` de `module.app_service_api` (mirroring exact du bloc `environment` déjà
   fait côté AWS ECS dans ce même fichier) :
   ```hcl
   "Database__AuthMode"  = "AzureAd"
   "Database__Host"      = module.postgresql.fqdn
   "Database__Port"      = "5432"
   "Database__Name"      = module.postgresql.database_name
   "Database__Username"  = "app-arkcloud-api-dev"
   ```
   Puis `terraform apply` (ce changement redémarre l'App Service) et vérifier `/health` + les logs
   applicatifs, comme pour la rotation Kudu.

6. **Rollback** si besoin : retirer `Database__AuthMode` des app settings (ou le remettre à toute
   autre valeur) fait revenir instantanément à `ConnectionStrings--DefaultConnection` existant —
   `password_auth_enabled = true` reste actif sur le serveur exprès pour ça (voir le commentaire
   dans `modules/azure/postgresql/main.tf`).

## Bugs réels rencontrés (12/09/2026)

1. **Cloud Shell ne peut pas joindre Postgres** — `psql: could not translate host name
   "psql-arkcloud-dev.postgres.database.azure.com" to address: Name or service not known`. Le
   serveur n'a qu'un endpoint privé lié à `vnet-arkcloud-dev` ; Cloud Shell tourne sur le réseau
   Microsoft, pas dans ce VNet. Contourné via la console SSH Kudu de `app-arkcloud-api-dev`, qui
   elle est bien sur `snet-api` (voir pré-requis ci-dessus).

2. **`pgaadauth_create_principal(...) does not exist`** sur la base `arkcloud`, alors que la
   connexion elle-même réussissait (auth + réseau OK) :
   ```
   ERROR:  function pgaadauth_create_principal(unknown, boolean, boolean) does not exist
   ```
   `\df *pgaadauth*` confirme 0 résultat sur `arkcloud`, mais la liste complète des fonctions
   `pgaadauth_*` sur la base `postgres` (`\c postgres` puis `\df *pgaadauth*`). Contrairement à ce
   que la documentation Microsoft laisse entendre, ces fonctions ne sont PAS exposées sur chaque
   base — uniquement sur `postgres`. `scripts/sql/bootstrap-arkcloud-app-entra-id.sql` corrigé en
   conséquence : `\c postgres` avant `pgaadauth_create_principal`, `\c arkcloud` avant le `GRANT`
   (les rôles sont globaux au cluster, `pg_roles`/la création du principal fonctionnent depuis
   n'importe quelle base ; seul `arkcloud_app`, créé dans `arkcloud`, exige d'y être reconnecté).

Résultat concret obtenu (`postgres=>`) :
```
SELECT pgaadauth_create_principal('app-arkcloud-api-dev', false, false);
       pgaadauth_create_principal
-----------------------------------------
 Created role for "app-arkcloud-api-dev"
(1 row)
```
puis (`arkcloud=>`) : `GRANT arkcloud_app TO "app-arkcloud-api-dev";` → `GRANT ROLE`.

## Non fait à ce stade

- Étapes 4-6 (test isolé avant bascule, bascule réelle de `Database__AuthMode=AzureAd` sur
  `app-arkcloud-api-dev`, vérification `/health` + logs) pas encore exécutées.
- `staging`/`prod` n'ont pas encore de serveur Postgres Azure — ce runbook ne couvre que `dev`.
