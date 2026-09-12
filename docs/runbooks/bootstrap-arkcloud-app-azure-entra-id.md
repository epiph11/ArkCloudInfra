# Runbook : activation du passwordless Entra ID pour `arkcloud_app` (Postgres Azure)

Voir ADR-0011 (`ArkCloud/docs/adr/0011-passwordless-auth-arkcloud-app-proposition.md`) pour le
contexte complet et le pendant déjà fait côté AWS (IAM DB auth). Ce document couvre uniquement les
étapes opérationnelles côté Azure.

**Statut au 12/09/2026** : bascule complète, vérifiée de bout en bout en conditions réelles.
`Database__AuthMode=AzureAd` actif sur `app-arkcloud-api-dev`, confirmé par un `POST /auth/login`
réel renvoyant `401 Invalid email or password` (pas une 500) — preuve que l'app lit `users` via un
token Entra ID de l'identité managée système, pas via `ConnectionStrings--DefaultConnection`.
L'étape 4 (test isolé avant bascule) a été sautée délibérément : environnement dev sans utilisateur
réel, downtime acceptable, le rollback (retirer `Database__AuthMode`) reste instantané si besoin.
Voir "Bugs réels rencontrés" ci-dessous — 3 trouvés en route, aucun lié à Entra ID en tant que tel.

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

3. **`dotnet ef migrations script` refuse de builder** : `ArkCloud.API.csproj` référençait
   `Azure.Identity` en `1.14.0` en dur, alors que `ArkCloud.Infrastructure.csproj` (passwordless
   Azure, voir plus haut) exige `>= 1.14.2` — NU1605 "package downgrade" en Warning-As-Error,
   restore bloqué. Fixé en alignant les deux projets sur `1.14.2`.

4. **Base Azure `arkcloud` totalement vide — migrations EF jamais appliquées.** `SELECT * FROM
   "__EFMigrationsHistory"` échouait avec "relation does not exist", `\dt` ne listait aucune table.
   Contrairement à AWS RDS (vérifié bout en bout les 10-11/09), personne n'avait jamais lancé
   `dotnet ef database update` contre cette instance Postgres Azure — un vrai trou antérieur à ce
   travail, découvert seulement parce que c'est la première fois qu'un flux applicatif réel (login)
   a tapé dans cette base. Résolu en générant le script SQL en local
   (`dotnet ef migrations script --output migrations.sql`) puis en l'exécutant via `psql -f` dans
   la console Kudu (même contrainte réseau privé que le bootstrap AAD — voir pré-requis).
   Piège rencontré en route : le fichier généré par `dotnet ef migrations script` sur Windows
   commence par un BOM UTF-8 (`ef bb bf`), qui a survécu à l'aller-retour PowerShell → base64 →
   Kudu et cassait la toute première instruction SQL (`syntax error at or near CREATE`). Fix :
   `tail -c +4 fichier.sql > fichier_clean.sql` avant de l'exécuter.

5. **`42501: permission denied for table users`** une fois les tables créées : les tables venaient
   d'être créées par l'admin AAD (`epiphanezare@outlook.com`), pas par `arkcloudadmin` — et
   `ALTER DEFAULT PRIVILEGES FOR ROLE arkcloudadmin ...` (voir `bootstrap-arkcloud-app-role.sql`)
   ne s'applique qu'aux objets créés PAR ce rôle précis, pas globalement. Fixé en ré-exécutant les
   `GRANT ... ON ALL TABLES IN SCHEMA public TO arkcloud_app` explicites, comme pour les tables
   historiques.

## Non fait à ce stade

- `staging`/`prod` n'ont pas encore de serveur Postgres Azure — ce runbook ne couvre que `dev`.
- Considérer un `ALTER DEFAULT PRIVILEGES FOR ROLE "epiphanezare@outlook.com" IN SCHEMA public
  GRANT ...` (même schéma que pour `arkcloudadmin`) pour que les prochaines migrations lancées par
  un admin AAD n'aient pas besoin d'un re-GRANT manuel après coup — pas fait ici, laissé en backlog
  car peu fréquent (les migrations tournent normalement via CI/CD avec `arkcloudadmin`, pas un
  admin AAD humain).
