# Runbook : activation du passwordless Entra ID pour `arkcloud_app` (Postgres Azure)

Voir ADR-0011 (`ArkCloud/docs/adr/0011-passwordless-auth-arkcloud-app-proposition.md`) pour le
contexte complet et le pendant déjà fait côté AWS (IAM DB auth). Ce document couvre uniquement les
étapes opérationnelles côté Azure.

**Statut au 12/09/2026** : Terraform appliqué (authentification Entra ID activée sur le serveur +
administrateur AAD désigné), bootstrap SQL et bascule applicative **pas encore exécutés** — ce
runbook, une fois suivi de bout en bout, complète l'activation réelle.

## Pré-requis

- `terraform apply` de `modules/azure/postgresql` déjà exécuté avec `entra_admin_principal_name`
  renseigné (voir `environments/dev/variables.tf`) — sans ça, `azurerm_postgresql_flexible_server_active_directory_administrator`
  n'existe pas encore et l'étape 2 ci-dessous échouera à l'authentification.
- Azure CLI installé localement, connecté avec le même compte que celui désigné administrateur
  Entra ID du serveur (`az login`).
- `arkcloud_app` déjà créé (`scripts/sql/bootstrap-arkcloud-app-role.sql` déjà exécuté au moins une
  fois — c'est déjà le cas, fait lors du cutover STRIDE flux 3, tâche #69).

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

## Non fait à ce stade

- Étapes 1-6 pas encore exécutées en conditions réelles (contrairement à AWS IAM DB auth,
  vérifié bout en bout le 10-11/09/2026) — à faire et à documenter ici avec les mêmes détails
  honnêtes que le runbook Kudu (bugs réels rencontrés, pas juste "ça a marché").
- `staging`/`prod` n'ont pas encore de serveur Postgres Azure — ce runbook ne couvre que `dev`.
