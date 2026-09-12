-- Sprint 6 clôture (12/09) — passwordless Azure (ADR-0011, scope Azure). Enregistre l'identité
-- managée système d'app-arkcloud-api-${env} comme principal Entra ID côté Postgres, puis lui
-- fait hériter les droits déjà accordés à arkcloud_app (scripts/sql/bootstrap-arkcloud-app-role.sql)
-- au lieu de dupliquer les GRANT — un seul jeu de permissions DML à maintenir, que l'app se
-- connecte par mot de passe (arkcloud_app) ou par token Entra ID (ce script).
--
-- Pré-requis : azurerm_postgresql_flexible_server_active_directory_administrator appliqué
-- (modules/azure/postgresql/main.tf) ET arkcloud_app déjà créé (bootstrap-arkcloud-app-role.sql
-- déjà exécuté au moins une fois) -- ce script GRANT arkcloud_app à un rôle qui doit déjà exister.
--
-- Connexion requise : en tant qu'administrateur Entra ID du serveur (pas arkcloudadmin --
-- pgaadauth_create_principal exige un appelant admin AAD, un mot de passe seul ne suffit pas),
-- via un token comme mot de passe :
--   $env:PGPASSWORD = (az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)
--   psql "host=<host> port=5432 dbname=arkcloud user=<ton-UPN-ou-nom-SP> sslmode=require" \
--        -v app_service_identity_name='app-arkcloud-api-dev' \
--        -f bootstrap-arkcloud-app-entra-id.sql
--
-- Idempotent : pgaadauth_create_principal échoue proprement (pas de duplication silencieuse) si
-- le rôle existe déjà -- vérifié avant d'appeler, même logique \if que le script mot de passe.

SELECT EXISTS (
    SELECT FROM pg_roles WHERE rolname = :'app_service_identity_name'
) AS principal_exists \gset

\if :principal_exists
\echo 'Principal Entra ID deja enregistre -- rien a faire.'
\else
-- false, false : pas administrateur, pas mot de passe additionnel -- authentification uniquement
-- par token Entra ID pour ce rôle. Le nom passé ici DOIT correspondre exactement au nom
-- d'affichage de l'identité managée système d'app-arkcloud-api-${env} dans Entra ID (qui, par
-- convention Azure pour une identité managée système d'App Service, est le nom de la ressource
-- elle-même -- confirmer dans le portail Azure AD > Identités managées d'entreprise si un doute).
SELECT pgaadauth_create_principal(:'app_service_identity_name', false, false);
\endif

-- Héritage plutôt que duplication des GRANT -- voir bootstrap-arkcloud-app-role.sql pour le
-- détail des droits réels accordés à arkcloud_app (SELECT/INSERT/UPDATE/DELETE, pas de DDL).
--
-- format(...) + \gset + :stmt (sans guillemets, contrairement à :'app_service_identity_name'
-- plus haut) plutôt qu'un simple GRANT arkcloud_app TO <nom> en dur : le nom du rôle est une
-- variable psql, pas littéral, et GRANT ne prend pas de paramètre lié côté serveur comme un
-- SELECT -- :stmt substitue le texte généré par format() tel quel dans le flux SQL envoyé à
-- psql, %I fait l'échappement d'identifiant côté serveur (protège même si le nom contenait des
-- caractères spéciaux).
SELECT format('GRANT arkcloud_app TO %I', :'app_service_identity_name') AS stmt \gset
:stmt;
