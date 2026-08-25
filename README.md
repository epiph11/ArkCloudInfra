# ArkCloudInfra

Infrastructure as Code (Terraform) pour ArkCloud — Azure d'abord (Sprint 4), puis AWS (Sprint 5). Gouvernance et cycle de vie séparés du repo applicatif `ArkCloud` : une erreur de code applicatif ne touche jamais les credentials/permissions cloud, et les changements d'infra suivent leur propre revue, indépendante de celle du code.

Ce document retrace en détail toutes les étapes réalisées pour le Sprint 4 (CI/CD + Azure), **clôturé le 28/07/2026**, dans l'ordre où elles ont été faites, avec les commandes exactes et les décisions prises.

---

## Statut d'ensemble

| Sprint | Contenu | Statut |
|---|---|---|
| 4 | Fondation Azure (RG, VNet, PostgreSQL, Key Vault, Managed Identity, App Service ×2, App Insights) + CI/CD + monitoring + audit logging | ✅ **Clôturé (28/07/2026)** — voir §5 point 7 pour le détail de clôture |
| 5 | Fondation AWS (VPC, ECR, ECS Fargate, ALB, RDS, Secrets Manager) | ⏳ À venir |
| 9 | Kubernetes (AKS/EKS) — hors de ce repo, manifests dans `ArkCloud/deploy/kubernetes/` | ⏳ À venir |

Voir `ArkCloud/docs/infra-roadmap.md` (repo applicatif) pour le plan complet, tous sprints confondus.

**Statut réel dans Azure** :

| Ressource | Nom réel |
|---|---|
| Resource Group | `rg-arkcloud-dev` |
| Virtual Network | `vnet-arkcloud-dev` (+ 4 subnets, 4 NSG) |
| PostgreSQL Flexible Server | `psql-arkcloud-dev` — `psql-arkcloud-dev.postgres.database.azure.com` (accès privé uniquement) |
| Key Vault | `kv-arkcloud-dev` — `https://kv-arkcloud-dev.vault.azure.net/` |
| App Service (API) | `app-arkcloud-api-dev` — `app-arkcloud-api-dev.azurewebsites.net` |
| App Service (Blazor) | `app-arkcloud-web-dev` — `app-arkcloud-web-dev.azurewebsites.net` |
| Log Analytics + App Insights | `log-arkcloud-dev` / `appi-arkcloud-dev` |

Les deux App Services tournent réellement (image GHCR tirée avec authentification, §5 point 6), servent du vrai trafic HTTP, et envoient à la fois de la télémétrie applicative (Application Insights, §5 point 6) et des logs d'audit/diagnostics plateforme (Key Vault, PostgreSQL, App Services — §5 point 7, §10) vers le même workspace Log Analytics.

---

## Structure du repo

```
ArkCloudInfra/
│
├── .github/workflows/
│   └── terraform-ci.yml       # squelette : fmt-check seulement pour l'instant
│
├── modules/
│   ├── azure/
│   │   ├── resource-group/
│   │   ├── network/            # VNet + 4 subnets + NSGs
│   │   ├── postgresql/         # Flexible Server, accès privé
│   │   ├── key-vault/          # RBAC, pas de secrets créés ici
│   │   ├── identity/           # role assignment générique
│   │   ├── app-service/        # instancié 2× (API + Blazor)
│   │   └── monitoring/         # Log Analytics + App Insights
│   │
│   ├── aws/                    # Sprint 5 — vide pour l'instant
│   └── shared/
│
├── environments/
│   ├── dev/                    # pas encore rempli — prochaine étape
│   ├── staging/
│   └── prod/
│
├── .gitignore
└── README.md
```

Chaque dossier sous `environments/` sera un root module Terraform autonome : son propre state (un blob distinct dans le storage account de remote state), son propre `backend.tf`, référençant les modules via chemin relatif. Pas de state partagé entre dev/staging/prod.

---

## 1. Outillage installé (poste local, Windows)

```powershell
winget install HashiCorp.Terraform
winget install Microsoft.AzureCLI
winget install AquaSecurity.Trivy
winget install TerraformLinters.tflint
winget install GitHub.cli
pip install checkov --user
```

**Points de friction rencontrés et fixes** :

- **`terraform`/`tflint` introuvables juste après `winget install`** : le PATH mis à jour par `winget` n'est visible que dans une **nouvelle** fenêtre PowerShell (pas un nouvel onglet) — parfois il faut même se reconnecter à la session Windows si le PATH machine a été modifié pendant qu'Explorer tournait déjà.
- **`checkov` introuvable après `pip install --user`** : `pip --user` installe les scripts dans `%APPDATA%\Roaming\Python\Python3XX\Scripts`, un dossier absent du PATH par défaut. Deux options : ajouter ce dossier au PATH utilisateur (Paramètres Windows → *Variables d'environnement*), ou passer par `pipx install checkov` qui gère le PATH automatiquement.

Vérification :

```powershell
terraform version
az version
trivy --version
tflint --version
checkov --version   # ou : python -m site --user-site, puis ajuster le PATH comme ci-dessus
```

### Connexion Azure

```powershell
az login --use-device-code   # plus fiable que le flow par défaut pour la MFA
az account list --all --output table
az account set --subscription "<SubscriptionId>"
az account show --output table
```

**Piège rencontré** : `az login` a échoué une première fois avec `AADSTS50076` (MFA requise par une politique d'accès conditionnel) sur le tenant "Default Directory", qui n'avait de toute façon aucun abonnement (`No subscriptions found`). Le bon abonnement (`Azure subscription 1`, `dd810534-1452-4967-95ed-cf2de0fd5816`) était accessible depuis le même compte mais nécessitait de compléter la MFA via `--use-device-code`. Une fois listé par `az account list --all`, le prompt interactif de sélection attend le **numéro de ligne** (`1`), pas l'ID ni le nom.

Abonnement renommé pour plus de clarté (purement cosmétique, aucun impact sur Terraform qui référence toujours l'ID) :

```powershell
az account subscription rename --subscription-id dd810534-1452-4967-95ed-cf2de0fd5816 --name "ArkCloud"
```

---

## 2. Remote state Terraform (bootstrap manuel, one-shot)

Avant tout `terraform init`, ces ressources doivent exister — créées manuellement via `az`, pas par Terraform (chicken-and-egg classique : il faut bien un backend pour stocker le state *avant* de pouvoir en créer un avec Terraform lui-même).

**Ressources créées, région `westeurope`** :

| Ressource | Nom | Détails |
|---|---|---|
| Resource Group | `rg-terraform-state` | Séparé de `rg-arkcloud-dev`/`staging`/`prod` |
| Storage Account | `arkcloudstatestore` | `Standard_LRS`, `StorageV2`, TLS 1.2 min, accès public bloqué |
| Blob Container | `terraform` | Contiendra un `.tfstate` par environnement |
| Versioning + soft delete | — | Activés, rétention 30 jours — récupération possible si un state est écrasé/supprimé par erreur |
| Verrou | `lock-terraform-state` | `CanNotDelete` sur le Resource Group entier |

Commandes exactes :

```powershell
az group create --name rg-terraform-state --location westeurope

az storage account create `
  --name arkcloudstatestore `
  --resource-group rg-terraform-state `
  --location westeurope `
  --sku Standard_LRS `
  --kind StorageV2 `
  --min-tls-version TLS1_2 `
  --allow-blob-public-access false

az storage container create `
  --name terraform `
  --account-name arkcloudstatestore `
  --auth-mode login

az storage account blob-service-properties update `
  --account-name arkcloudstatestore `
  --resource-group rg-terraform-state `
  --enable-versioning true `
  --enable-delete-retention true `
  --delete-retention-days 30

az lock create `
  --name lock-terraform-state `
  --resource-group rg-terraform-state `
  --lock-type CanNotDelete
```

**Nom du storage account** : `arkcloudstatestore` a été choisi après une première tentative (`arkcloudtfstate`) jugée peu évocatrice — les storage accounts Azure ne supportent ni tirets ni underscores (minuscules + chiffres uniquement, 3-24 caractères, unique dans le monde entier), d'où des noms toujours un peu plats. `az storage account check-name-availability` n'existait pas sur la version de CLI installée — sans conséquence, `az storage account create` échoue de toute façon avec une erreur claire (`StorageAccountAlreadyTaken`) si le nom est pris.

---

## 3. Modules Terraform Azure

Sept modules dans `modules/azure/`, chacun avec `variables.tf` / `main.tf` / `outputs.tf`.

### `resource-group`

Le plus simple : crée un `azurerm_resource_group`, ne fait rien d'autre. Instancié une fois par environnement (`rg-arkcloud-dev`, `-staging`, `-prod`).

### `network`

Un `azurerm_virtual_network` (`10.10.0.0/16`) découpé en **quatre** sous-réseaux :

| Subnet | CIDR | Délégation | Rôle |
|---|---|---|---|
| `snet-api` | `10.10.1.0/24` | `Microsoft.Web/serverFarms` | Intégration VNet sortante pour le Plan d'`ArkCloud.API` — seul autorisé à atteindre la base |
| `snet-web` | `10.10.4.0/24` | `Microsoft.Web/serverFarms` | Intégration VNet sortante pour le Plan d'`ArkCloud.Blazor` |
| `snet-db` | `10.10.2.0/24` | `Microsoft.DBforPostgreSQL/flexibleServers` | PostgreSQL Flexible Server, accès privé |
| `snet-pe` | `10.10.3.0/24` | — | Réservé pour de futurs private endpoints (Key Vault, storage), vide jusqu'au durcissement Sprint 6 |

**Correction faite en session** — la toute première version n'avait qu'un seul `snet-app` partagé par API et Blazor. Deux problèmes concrets, pas juste esthétiques :

1. **Techniquement invalide** : Azure lie un subnet d'intégration VNet à un **seul** App Service Plan. API et Blazor tournant sur deux Plans distincts, ils ne peuvent pas partager un subnet.
2. **Frontière de confiance absente** : Blazor Server ne doit jamais parler à PostgreSQL directement, seulement via les endpoints HTTP d'`ArkCloud.API`. Un seul subnet pour les deux ne permettait pas d'exprimer cette règle au niveau réseau.

NSGs :
- `nsg-api` : aucune règle custom — l'intégration VNet est sortante uniquement, rien n'écoute d'entrant sur ce subnet. Laissé en place (vide) comme point d'ancrage pour un futur durcissement des sorties (Sprint 6).
- `nsg-web` : `Deny` explicite en sortant sur le port `5432` vers `snet-db` — défense en profondeur, rend la règle "Blazor ne parle jamais à PostgreSQL" vérifiable au niveau réseau, pas juste une convention de code.
- `nsg-database` : `Allow` entrant `5432` uniquement depuis `snet-api`. C'est ici, pas dans le découpage des subnets lui-même, que se trouve la vraie séparation de tiers.

### `postgresql`

PostgreSQL Flexible Server 16, accès **privé** uniquement (pas d'endpoint public) : subnet délégué (`snet-db`) + zone DNS privée liée au VNet. SSL/TLS forcé par défaut sur Flexible Server (pas de ressource dédiée nécessaire). Le mot de passe admin est `sensitive`, sans valeur par défaut (à passer via `TF_VAR_administrator_password` ou un secret CI, jamais en dur dans un `.tfvars` commité), et marqué `ignore_changes` pour qu'une rotation ne soit jamais un effet de bord accidentel d'un `apply` sans rapport.

### `key-vault`

RBAC activé (`enable_rbac_authorization = true`), purge protection **on**. Ne crée **aucun secret** — seulement le coffre. Les valeurs (mot de passe DB, clé JWT) sont posées après coup, hors Terraform (`az keyvault secret set` ou équivalent CI), pour ne jamais apparaître dans le code source ni dans un diff de `plan`.

### `identity`

Générique : accepte `scope` / `principal_id` / `role_definition_name` en variables plutôt que d'être câblé en dur sur "App Service lit Key Vault". Réutilisable plus tard pour d'autres principals (ex. un service principal OIDC GitHub Actions).

### `app-service`

Un `azurerm_service_plan` (Linux) + `azurerm_linux_web_app`, avec :
- Identité **System Assigned** (aucun credential stocké nulle part).
- Intégration VNet sortante via `vnet_integration_subnet_id` — instancié une fois avec `network.api_subnet_id` (pour `ArkCloud.API`) et une seconde fois avec `network.web_subnet_id` (pour `ArkCloud.Blazor`).
- Registre d'image paramétré (`container_registry_url`/`username`/`password` séparés) pour permettre le remplacement GHCR → JFrog Artifactory (Sprint 4/5) sans toucher au module.
- `app_settings` incluant `KeyVault__Uri` et `APPLICATIONINSIGHTS_CONNECTION_STRING`, alimentés par les outputs des modules `key-vault` et `monitoring`.

### `monitoring`

Log Analytics Workspace + Application Insights *workspace-based* (le seul mode supporté aujourd'hui par Azure pour de nouvelles ressources) — requests, exceptions, dependencies et availability remontent tous dans le même espace de requête.

---

## 4. Schéma de l'architecture cible

> Vue "tout assemblé, comme réellement déployé" (les 24 ressources, comment elles s'interconnectent) : voir `docs/architecture-dev.md`.

Deux vues, discutées et corrigées en session (voir §3 pour le détail des corrections) :

**Vue structurelle** (imbrication) : `rg-arkcloud-dev` contient un unique VNet (`10.10.0.0/16`), lui-même découpé en 4 subnets (`snet-api`, `snet-web`, `snet-db`, `snet-pe`), chacun avec son NSG propre.

**Vue des flux de communication** :

```
Internet --HTTPS:443--> ArkCloud.Blazor --HTTP interne--> ArkCloud.API
                                                              |
                                        +---------------------+---------------------+
                                        |                     |                     |
                                  read secrets            5432 (privé)            logs
                                        |                     |                     |
                                    Key Vault            PostgreSQL          Application Insights

Registry (GHCR → JFrog) --image pull--> ArkCloud.Blazor
Registry (GHCR → JFrog) --image pull--> ArkCloud.API
```

Points clés : Blazor n'a de connexion directe ni à PostgreSQL ni à Key Vault (il n'en a pas besoin — il ne valide pas les JWT lui-même et ne stocke aucun secret serveur), seule l'API en a besoin. Les deux App Services tirent leur image du même registre. Application Insights reçoit la télémétrie de l'API (et, de la même façon côté Blazor, non représenté ci-dessus pour rester lisible).

---

## 4.5 `environments/dev/` — assemblage des modules

```
environments/dev/
├── versions.tf              # terraform >= 1.7, providers azurerm ~> 4.0, random ~> 3.6
├── providers.tf             # provider "azurerm" { features {} } + data.azurerm_client_config
├── backend.tf               # state distant : arkcloudstatestore / terraform / dev.terraform.tfstate
├── locals.tf                # tags communs (environment, project, managed-by) fusionnés avec var.tags
├── variables.tf              # location, postgres_admin_login/password, skus, image_org/tag
├── main.tf                   # instancie les 7 modules — app-service deux fois (api + web)
├── outputs.tf                 # api_hostname, web_hostname, postgres_fqdn, key_vault_uri
└── terraform.tfvars.example
```

Points notables de `main.tf` :

- `module "keyvault_access_api"` (module `identity`) ne donne accès au Key Vault qu'à l'identité de **l'API** — pas de module équivalent pour Blazor, cohérent avec le fait qu'il n'a besoin d'aucun secret.
- `app_service_web` reçoit `extra_app_settings = { "Api__BaseUrl" = "https://${module.app_service_api.default_hostname}" }` — Blazor apprend l'URL réelle de l'API sans que l'un ou l'autre ne la code en dur.
- `postgres_admin_password` n'a volontairement **pas** de valeur, ni dans `variables.tf` ni dans `terraform.tfvars.example` — à fournir via `$env:TF_VAR_postgres_admin_password` en local, ou un secret de pipeline en CI.

## 4.6 Corrections faites lors du premier `plan`/`apply`

Trois problèmes que la seule lecture du code ne pouvait pas révéler — seule la validation réelle par le provider Azure (au `plan`) ou par l'API Azure elle-même (à l'`apply`) les a fait apparaître :

- **`key-vault`** : `enable_rbac_authorization` renommé en `rbac_authorization_enabled` — avertissement seulement (l'ancien nom fonctionne encore en provider v4, sera supprimé en v5), corrigé par anticipation.
- **`app-service`** : `health_check_path` exige désormais systématiquement `health_check_eviction_time_in_min` en complément (depuis une version récente du provider) — erreur bloquante au `plan`, nouvelle variable ajoutée (défaut `2`, minimum autorisé par Azure).
- **`postgresql`** : `public_network_access_enabled` (vrai par défaut côté provider) entrait en conflit avec `delegated_subnet_id` (accès privé) — erreur bloquante à l'`apply` cette fois, pas au `plan` (Azure valide cette règle côté API, pas côté schéma Terraform). Corrigé en désactivant explicitement l'accès public.

## 5. Ce qui reste à faire (Sprint 4)

1. ~~**Réorganiser les Dockerfiles**~~ ✅ Fait — `ArkCloud/deploy/docker/Dockerfile.api` et `Dockerfile.blazor`, `docker-compose.yml` et les deux workflows CI mis à jour.
2. ~~**Enrichir `arkcloud-backend-ci.yml`/`arkcloud-frontend-ci.yml`** — scan Trivy avant push~~ ✅ Fait (`aquasecurity/trivy-action@0.36.0`, bloquant sur `CRITICAL`/`HIGH` avec correctif disponible). Reste : pousser réellement un premier tag d'image (déclenche au prochain push sur `main`/`staging`/`develop`) — tant que ça n'a pas eu lieu, les deux App Services n'ont aucune image réelle à tirer.
3. ~~**Enrichir `terraform-ci.yml`**~~ ✅ Fait — `fmt`, tflint, Checkov, `init`/`validate`/`plan` réels (plan publié dans le résumé du run), job `apply` séparé gaté par l'Environment GitHub `production` avec reviewer requis. ~~Setup Azure/GitHub OIDC one-shot~~ ✅ Fait — voir §6.
4. ~~**Brancher le déploiement continu**~~ ✅ Fait — déclenchement cross-repo `ArkCloud` → `ArkCloudInfra` via `repository_dispatch` (§7), PAT `INFRA_DISPATCH_TOKEN` créé et posé comme secret dans `ArkCloud`. Validé de bout en bout le 16/07 : push sur `develop` → CI → GHCR → dispatch reçu par `ArkCloudInfra`. Bloqué ensuite par le nouveau format immuable des subjects OIDC (voir §6 addendum) — corrigé, en attente de confirmation du rerun.
5. ~~**Activer Key Vault pour de vrai**~~ ✅ Fait — `Jwt--Key` et `ConnectionStrings--DefaultConnection` posés dans `kv-arkcloud-dev` (§8), `app-arkcloud-api-dev` redémarré pour les prendre en compte. Validation complète (logs montrant une vraie connexion DB) reportée à après le premier push d'image réelle (point 2 ci-dessus), tant que l'App Service tourne sur le placeholder par défaut.
6. ~~**Vérifier le monitoring**~~ ✅ Fait (26-28/07) — mais ça n'a pas marché du premier coup, trois bugs réels distincts découverts et corrigés en cascade :
   - **`APPLICATIONINSIGHTS_CONNECTION_STRING` posé mais jamais lu** : la variable d'environnement était correctement câblée côté Terraform depuis le début, mais ni `ArkCloud.API` ni `ArkCloud.Blazor` n'avaient le SDK Application Insights référencé en code — `az monitor app-insights query` retournait 0 ligne indéfiniment. Corrigé en ajoutant `Microsoft.ApplicationInsights.AspNetCore` + `builder.Services.AddApplicationInsightsTelemetry()` aux deux apps (repo `ArkCloud`, commit `63dc594`). Un container Docker custom n'a pas l'auto-instrumentation "codeless" d'Azure (réservée aux stacks managées) — le SDK doit être référencé explicitement.
   - **Les deux App Services ne tiraient aucune image réelle** : `docker_registry_username`/`password` étaient vides dans le module `app-service`, et le package GHCR était privé — `ImagePullUnauthorizedFailure` en boucle depuis le 16/07. Corrigé en ajoutant un PAT GitHub dédié (scope `read:packages` seul, classic — un fine-grained token ne fonctionne pas pour l'auth GHCR container) comme `GHCR_PAT` (secret GitHub + `TF_VAR_ghcr_pat`), câblé dans `container_registry_username`/`password` des deux modules `app-service`. **Attention** : ce secret doit être posé dans **les deux** workflows qui font un `terraform apply` (`terraform-ci.yml` ET `deploy-on-image.yml`) — l'avoir ajouté seulement au premier a fait planter le second avec "No value for required variable" au prochain dispatch.
   - **`api_image_tag`/`web_image_tag` avaient pour défaut `"latest"`, un tag qui n'a jamais existé sur GHCR** (seuls `dev` et des SHA de commit sont publiés) — à chaque `terraform apply` complet (pas seulement le `-target` scopé du dispatch cross-repo), Terraform ramenait silencieusement le tag déployé à `latest`, cassant le déploiement réel fait par le dispatch précédent. Corrigé en alignant les défauts sur `"dev"`. Limitation connue non résolue : les deux chemins d'apply (complet vs `-target` scopé) peuvent toujours se marcher dessus si le tag réellement désiré diverge un jour du défaut — à surveiller, pas de fix structurel apporté pour l'instant.

   Vérifié via `az monitor app-insights query ... "requests | order by timestamp desc"` : lignes réelles pour les deux `cloud_RoleName` (`app-arkcloud-api-dev`, `app-arkcloud-web-dev`), avec `resultCode`/`duration`/géolocalisation client.

   **Gap découvert au passage, non corrigé (hors scope App Insights)** : `GET /health` renvoie 404 sur `ArkCloud.API` — aucun health check ASP.NET Core (`AddHealthChecks()`/`MapHealthChecks`) n'est implémenté en code, alors que `health_check_path = "/health"` est configuré côté Terraform. Le probe de santé natif d'Azure App Service tape dessus toutes les ~30s (visible dans Application Insights) et reçoit 404 à chaque fois. Ne bloque rien pour l'instant (l'instance n'est pas évincée), mais à corriger dans `ArkCloud` (repo applicatif) avant la prod.
7. ~~**Checklist de clôture Sprint 4**~~ ✅ Fait (28/07) — sous-partie Azure/DevOps de `ArkCloud/docs/infra-roadmap.md` Step 17 passée en revue point par point. Deux gaps réels identifiés (pas des oublis de doc — vérifiés dans le code) :
   - **Logs d'audit/diagnostics** : aucun `azurerm_monitor_diagnostic_setting` n'existait — Log Analytics ne recevait que la télémétrie applicative (point 6 ci-dessus), rien au niveau plateforme. Corrigé en ajoutant quatre `azurerm_monitor_diagnostic_setting` dans `environments/dev/main.tf` (Key Vault, PostgreSQL, les deux App Services), tous routés vers le workspace existant avec `enabled_log { category_group = "allLogs" }` + `metric { category = "AllMetrics" }` — le raccourci `allLogs` plutôt qu'une liste de catégories nommées, pour ne pas dépendre d'une liste figée que le provider peut faire évoluer. **Volontairement pas fait** : NSG flow logs — nécessitent `azurerm_network_watcher_flow_log` + un Storage Account dédié, une vraie brique d'infra supplémentaire plutôt qu'un réglage sur une ressource existante ; reporté au durcissement Sprint 6 avec les private endpoints.
     - **Bug réel trouvé à la vérification (28/07)** : Key Vault (`AuditEvent`) et PostgreSQL (`PostgreSQLLogs`/`PostgreSQLFlexSessions`/`PostgreSQLFlexTableStats`) sont remontés en quelques minutes dans `AzureDiagnostics`, confirmés par requête KQL directe. Les deux App Services, eux, n'ont produit strictement aucune ligne même après 30 min et du vrai trafic HTTP généré exprès (`curl` sur `/health`, `/swagger/index.html`, `/`). Cause : sans `log_analytics_destination_type` explicite, le diagnostic setting utilise le mode legacy "Azure Diagnostics" (table `AzureDiagnostics` partagée) — documenté par Microsoft comme le pipeline le moins fiable spécifiquement pour `Microsoft.Web/sites`. Corrigé en ajoutant `log_analytics_destination_type = "Dedicated"` aux deux diagnostic settings App Service (tables dédiées `AppServiceHTTPLogs`/`AppServiceConsoleLogs`/`AppServicePlatformLogs`/etc., une par catégorie, plutôt que la table `AzureDiagnostics` générique) — Key Vault et PostgreSQL laissés inchangés puisqu'ils fonctionnaient déjà correctement en mode legacy. Changer cet attribut force un remplacement (delete+create) du diagnostic setting au prochain apply, pas un simple update — attendu, pas une erreur.
     - **Vérification finale, les 4 ressources confirmées par requête réelle** : `AzureDiagnostics` pour Key Vault (7 lignes `AuditEvent` sur `kv-arkcloud-dev`) et PostgreSQL (1068 `PostgreSQLLogs` + 62 `PostgreSQLFlexSessions` + 15 `PostgreSQLFlexTableStats` sur `psql-arkcloud-dev`) ; tables dédiées pour les App Services après le fix `Dedicated` (72 `AppServiceConsoleLogs` + 5 `AppServiceHTTPLogs` sur `app-arkcloud-api-dev`, 6 `AppServiceHTTPLogs` sur `app-arkcloud-web-dev`). L'audit logging du Step 17 est réellement en place, pas seulement câblé côté Terraform.
   - **Rotation des secrets** : aucune politique n'existait pour `POSTGRES_ADMIN_PASSWORD`, `Jwt:Key`, ou `GHCR_PAT`. Pas d'automatisation ajoutée (une vraie rotation automatique demanderait Key Vault + un mécanisme de renouvellement applicatif hors scope Terraform réaliste pour du dev) — à la place, une procédure documentée et des échéances concrètes, voir §10.

   Sprint 4 clôturé sur cette base : pipeline Terraform vert de bout en bout, déploiement continu fonctionnel, monitoring applicatif vérifié, logs d'audit désormais routés vers Log Analytics. Gaps restants et volontairement non traités ici, portés aux sprints suivants : migration JFrog Artifactory (Sprint 4/5 par le roadmap), NSG flow logs et private endpoints (Sprint 6), endpoint `/health` (repo `ArkCloud`, non bloquant), conflit entre les deux chemins d'apply full vs `-target` (§7, aucun fix structurel apporté — à surveiller).

## 6. Setup Azure + GitHub requis pour que `terraform-ci.yml` tourne (one-shot manuel)

`terraform-ci.yml` s'authentifie à Azure par **OIDC** (le jeton que GitHub Actions délivre à chaque run, jamais un secret client stocké) — mais ça suppose une identité Azure AD créée à l'avance et autorisée à faire confiance à ce jeton précis. Rien de tout ça n'existe encore ; à faire une seule fois, en local (`az login` déjà actif) :

```powershell
# 1. Crée l'App Registration qui représentera la CI
az ad app create --display-name "github-arkcloudinfra"
# Note le "appId" retourné — c'est ton AZURE_CLIENT_ID

az ad sp create --id <appId>

# 2. Fait confiance au jeton OIDC de GitHub Actions — un federated credential par déclencheur
#    (remplace <org>/ArkCloudInfra par le vrai chemin du repo GitHub)
az ad app federated-credential create --id <appId> --parameters '{
  "name": "github-main-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<org>/ArkCloudInfra:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

az ad app federated-credential create --id <appId> --parameters '{
  "name": "github-pull-requests",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<org>/ArkCloudInfra:pull_request",
  "audiences": ["api://AzureADTokenExchange"]
}'

# 3. Droits Azure : gérer les ressources + lire/écrire le state (RBAC sur le storage account,
#    puisque backend.tf utilise use_azuread_auth = true plutôt qu'une clé de compte)
az role assignment create --assignee <appId> --role "Contributor" `
  --scope "/subscriptions/<subscription-id>"

az role assignment create --assignee <appId> --role "Storage Blob Data Contributor" `
  --scope "/subscriptions/<subscription-id>/resourceGroups/rg-terraform-state/providers/Microsoft.Storage/storageAccounts/arkcloudstatestore"
```

Puis, côté GitHub (`Settings` du repo `ArkCloudInfra`) :

- **Settings → Secrets and variables → Actions → Secrets** : `AZURE_CLIENT_ID` (l'`appId`), `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (les deux visibles via `az account show`), `POSTGRES_ADMIN_PASSWORD` (la même valeur que celle générée pour l'usage local — §1).
- **Settings → Secrets and variables → Actions → Variables** : `IMAGE_ORG` (ton org/utilisateur GitHub, pas un secret).
- **Settings → Environments → New environment → `production`** : ajoute-toi (ou une autre personne) comme *required reviewer* — c'est ce qui transforme le job `apply` en étape gatée manuellement plutôt qu'automatique à chaque merge sur `main`.

Tant que ce setup n'est pas fait, `terraform-ci.yml` échouera dès `terraform init` (pas d'identité pour s'authentifier) — normal, pas un bug du workflow.

**✅ Fait** — App Registration `github-arkcloudinfra` (`appId` `63df2a4f-1129-424e-b6cf-b6c6613bc022`) + service principal créés, deux federated credentials posés (`ref:refs/heads/main` et `pull_request`), rôles `Contributor` (souscription) et `Storage Blob Data Contributor` (`arkcloudstatestore`) assignés, secrets/variable GitHub posés via `gh secret set`/`gh variable set`.

Point notable rencontré : `Required reviewers` sur l'Environment `production` n'est pas disponible pour un repo **privé** sur GitHub Free/Pro/Team (uniquement Enterprise Cloud pour le privé) — seulement `Wait timer`. Choix fait : passer `ArkCloudInfra` en **repo public** (le code Terraform ne contient aucun secret réel — mots de passe/clés passés par variable d'environnement ou Key Vault, jamais commités) pour débloquer `Required reviewers` gratuitement plutôt que de se contenter d'un simple minuteur.

---

## 7. Déclenchement cross-repo — nouvelle image → déploiement ciblé

Objectif : quand `arkcloud-backend-ci.yml` ou `arkcloud-frontend-ci.yml` (repo `ArkCloud`) publie une image sur GHCR, `ArkCloudInfra` doit redéployer **seulement** l'App Service concerné, avec le tag qui vient d'être poussé — sans repasser par un `plan`/`apply` complet ni toucher à l'autre app.

### Pourquoi deux variables de tag séparées, pas une seule

`environments/dev/variables.tf` expose `api_image_tag` et `web_image_tag`, chacune avec son propre défaut (`"latest"`), plutôt qu'un seul `image_tag` partagé. Repéré et corrigé avant que ça ne devienne un bug, pas après :

Un run de déploiement automatique ne fournit qu'**une** valeur de tag (celle de l'app qui vient de publier). Avec une variable unique, un déploiement de l'API à lui seul aurait implicitement repassé le tag de Blazor à sa valeur par défaut — donc redéployé silencieusement Blazor avec `latest`, sans qu'aucun changement n'ait été demandé côté Blazor. Deux variables indépendantes éliminent le problème à la racine : modifier `api_image_tag` ne touche jamais `web_image_tag`, quelle que soit la valeur résolue pour l'un ou l'autre dans un run donné.

### Le mécanisme

1. **Côté `ArkCloud`** (`arkcloud-backend-ci.yml` / `arkcloud-frontend-ci.yml`, job `publish-image`, dernière étape) : une fois l'image poussée sur GHCR, un événement `repository_dispatch` est envoyé au repo `ArkCloudInfra` via `peter-evans/repository-dispatch@v3`, avec un payload identifiant l'app, le tag et l'environnement cible :

   ```yaml
   client-payload: >-
     {"app": "api", "tag": "${{ env.ENV_TAG }}", "environment": "${{ env.TF_ENVIRONMENT }}"}
   ```

   (`"app": "web"` côté frontend, reste identique.) `TF_ENVIRONMENT` fait le pont entre le nommage `ENV_TAG` de `ArkCloud` (`dev`/`staging`/`<tag de version>`) et le nommage des dossiers `environments/{dev,staging,prod}` ici — les deux ne coïncident pas exactement pour les tags de version (`vX.Y.Z` → dossier `prod`).

2. **Côté `ArkCloudInfra`** (`.github/workflows/deploy-on-image.yml`, nouveau) : écoute `repository_dispatch: types: [image-published]`, se place dans `environments/<environment reçu>/`, puis lance un `terraform apply -auto-approve` **ciblé** :

   ```bash
   terraform apply -auto-approve -input=false \
     -target=module.app_service_api.azurerm_linux_web_app.this \
     -var "api_image_tag=<tag reçu>"
   ```

   (`module.app_service_web...` + `web_image_tag` côté Blazor.) `-target` garantit que Terraform n'évalue même pas les autres ressources — pas seulement qu'il ne les modifie pas.

   Le job reste gaté par l'Environment GitHub `production` (même reviewer manuel que l'`apply` normal de `terraform-ci.yml`, §6) : un déploiement déclenché automatiquement par une image reste soumis à approbation, la source de l'événement ne change rien à ce contrôle.

### Ce qu'il reste à faire pour que ça tourne réellement

- **Créer le PAT `INFRA_DISPATCH_TOKEN`** : un *fine-grained personal access token* GitHub, scope repo unique `ArkCloudInfra`, permission `Contents: Read and write` (c'est tout ce qu'exige `repository-dispatch`). Le `GITHUB_TOKEN` intégré ne peut pas servir ici — il est cantonné au repo qui l'émet et ne peut pas déclencher d'action sur un autre repo.
- **Poser ce PAT comme secret dans `ArkCloud`** (pas `ArkCloudInfra`) : `Settings → Secrets and variables → Actions → Secrets → INFRA_DISPATCH_TOKEN`. C'est `ArkCloud` qui émet l'événement, donc c'est lui qui a besoin du token.
- Le reste (`AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`/`POSTGRES_ADMIN_PASSWORD`/`IMAGE_ORG`) est déjà couvert par le setup one-shot du §6, côté `ArkCloudInfra` — `deploy-on-image.yml` réutilise les mêmes secrets que `terraform-ci.yml`.

---

## 8. Poser les secrets applicatifs dans Key Vault (one-shot manuel)

`kv-arkcloud-dev` existe (créé par `terraform apply`, §4.6) mais ne contient aucun secret — normal, le module `key-vault` (§3) ne crée jamais de secret lui-même. Deux valeurs manquent pour qu'`ArkCloud.API` démarre avec sa vraie configuration au lieu des placeholders vides d'`appsettings.json` : la clé de signature JWT et la chaîne de connexion PostgreSQL.

**Convention de nommage** (voir `Program.cs`, section "Secret management") : le fournisseur de configuration Azure Key Vault transforme `--` en `:` — un secret nommé `Jwt--Key` devient la clé de config `Jwt:Key`. C'est pour ça que les noms ci-dessous contiennent des doubles tirets, pas des points.

**Prérequis — RBAC** : le Key Vault est en mode RBAC (`rbac_authorization_enabled = true`, §3). Seule l'identité de l'API (`Key Vault Secrets User`, lecture seule) a un accès aujourd'hui — ton propre compte `az login` n'a *aucun* droit dessus tant que tu ne te l'accordes pas explicitement :

```powershell
$myObjectId = az ad signed-in-user show --query id -o tsv

az role assignment create --assignee $myObjectId `
  --role "Key Vault Secrets Officer" `
  --scope "/subscriptions/dd810534-1452-4967-95ed-cf2de0fd5816/resourceGroups/rg-arkcloud-dev/providers/Microsoft.KeyVault/vaults/kv-arkcloud-dev"
```

**Poser les deux secrets** :

```powershell
# Clé JWT — 64 octets aléatoires encodés en base64, jamais commitée nulle part
$bytes = New-Object byte[] 64
[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$jwtKey = [Convert]::ToBase64String($bytes)

az keyvault secret set --vault-name kv-arkcloud-dev --name "Jwt--Key" --value $jwtKey

# Chaîne de connexion — même mot de passe que celui déjà utilisé pour l'apply Terraform
# (repris de $env:TF_VAR_postgres_admin_password, pas ressaisi en clair)
az keyvault secret set --vault-name kv-arkcloud-dev --name "ConnectionStrings--DefaultConnection" `
  --value "Host=psql-arkcloud-dev.postgres.database.azure.com;Port=5432;Database=arkcloud;Username=arkcloudadmin;Password=$env:TF_VAR_postgres_admin_password;Ssl Mode=Require"
```

`Ssl Mode=Require` est nécessaire : Flexible Server impose TLS par défaut (`require_secure_transport = ON`, voir commentaire dans `modules/azure/postgresql/main.tf`) même en accès privé VNet.

**Après coup** : `builder.Configuration.AddAzureKeyVault(...)` (`Program.cs` ligne 51) ne lit le vault qu'au démarrage du process — poser un secret ne suffit pas tant que l'App Service n'a pas redémarré :

```powershell
az webapp restart --name app-arkcloud-api-dev --resource-group rg-arkcloud-dev
```

Pas d'équivalent côté `app-arkcloud-web-dev` — Blazor ne lit aucun secret de Key Vault (§3, module `app-service` : `key_vault_uri` lui est passé pour cohérence de module mais reste inutilisé côté Blazor).

---

## 9. Checkov — findings corrigés vs. délibérément écartés

Le premier vrai run de `terraform-ci.yml` a remonté 28 findings sur `environments/dev`. Pas de faux positifs — un vrai désaccord entre le jeu de règles "prod durcie par défaut" de Checkov et des choix faits consciemment pour un environnement **dev**. Décision : corriger ce qui est gratuit et sans compromis, documenter (`skip_check` dans `terraform-ci.yml`) le reste plutôt que soit payer pour rien sur du dev jetable, soit désactiver le scanner.

### Voir les findings avant de pousser, pas seulement après (Sprint 6)

`terraform plan` en local ne dit rien sur la posture sécurité — seul le job CI faisait tourner Checkov, donc chaque nouveau finding se découvrait après coup, une fois poussé. Deux pièces, sous contrôle de version :

- **`scripts/checkov-local.sh`** — fait tourner exactement la même image (`ghcr.io/bridgecrewio/checkov:3.3.13`) que la CI, avec la même liste `skip_check`, lue directement dans `terraform-ci.yml` plutôt que dupliquée (sinon les deux listes divergent tôt ou tard — même principe que le reste de la discipline "une seule source de vérité" de ce sprint).
- **`githooks/pre-push`** — bloque le push si Checkov trouve un finding non skippé, miroir du `soft_fail: false` de la CI. Nécessite Docker en local ; s'il est absent, avertit et laisse passer plutôt que bloquer sur un outil manquant (la CI reste le filet de sécurité dans tous les cas).

Activation, une fois par clone (git n'utilise jamais `.git/hooks/` automatiquement pour un dossier versionné) :

```bash
git config core.hooksPath githooks
```

Pour pousser malgré un échec Checkov en connaissance de cause (rare, à documenter dans le message de commit si utilisé) : `git push --no-verify`.

### Corrigés dans le code (aucun compromis, applicable à tout environnement)

- **`CKV_AZURE_78`** (FTP déploiement) — `ftps_state = "Disabled"` dans `modules/azure/app-service/main.tf`. Le déploiement passe par Terraform/GHCR, jamais par FTP — aucune raison de laisser cette surface active.
- **`CKV_AZURE_18`** (version HTTP) — `http2_enabled = true`.
- **`CKV_AZURE_17`** (client certificates) — `client_certificate_enabled = true` avec `client_certificate_mode = "Optional"` : satisfait le check sans exiger de mTLS, donc sans casser l'accès HTTPS normal des navigateurs/clients API.
- **`CKV_AZURE_65`/`CKV_AZURE_66`** (detailed error messages / failed request tracing) — première tentative en bloc (`detailed_error_messages { enabled = true }`) rejetée par `terraform validate` ("Unsupported block type") : sur le schéma actuel d'`azurerm_linux_web_app`, ce sont des **attributs booléens simples**, pas des sous-blocs. Corrigé en `detailed_error_messages = true` / `failed_request_tracing = true`.
- **`CKV2_AZURE_31`** (subnet sans NSG) — `snet-private-endpoint` était le seul des 4 subnets sans NSG associé (oubli, pas un choix) ; `nsg-private-endpoint` ajouté, vide comme `nsg-api`, pour la même raison (rien n'y écoute encore).

### Écartés — `skip_check` documenté dans `terraform-ci.yml`

- **`CKV_AZURE_225`/`212`/`211`** (zone redundancy, instances minimales, SKU "production") et **`CKV_AZURE_136`** (backup géo-redondant PostgreSQL) — tous exigent de sortir du tier dev (App Service B1 Basic, PostgreSQL Burstable) vers un tier qui coûte réellement plus cher (Premium v2/v3, General Purpose) sans aucun bénéfice sur un environnement jetable où personne ne dépend d'un SLA. `environments/staging`/`prod` existent déjà dans la structure du repo précisément pour appliquer ces standards quand un vrai environnement à durcir existera — pas avant.
- **`CKV_AZURE_189`/`109`, `CKV2_AZURE_32`/`CKV2_AZURE_57`** (Key Vault + PostgreSQL sans private endpoint/firewall) — `snet-private-endpoint` est réservé exprès pour ça (§3), volontairement vide jusqu'au durcissement Sprint 6.
- **`CKV_AZURE_222`** (App Service accessible publiquement) — désactiver l'accès public exige un point d'entrée public devant (Application Gateway ou Front Door) : une vraie nouvelle brique d'infra, portée Sprint 6+, pas un flag à inverser.
- **`CKV_AZURE_13`** (Azure App Service Authentication / Easy Auth) — l'activer ferait doublon avec le système JWT propre à `ArkCloud.API` : deux couches d'authentification qui se marcheraient dessus, pas un vrai manque.
- **`CKV_AZURE_88`** (App Service + Azure Files) — pensé pour des apps ayant besoin de stockage fichier persistant ; cette app est sans état, tout ce qui doit durer vit dans PostgreSQL.

### Sprint 6 — `modules/azure/flow-logs`, 10 findings

Corrigés (`modules/azure/flow-logs/main.tf`/`variables.tf`) : soft delete sur le storage account (`CKV2_AZURE_38`), rétention des flow logs relevée à 90 jours (`CKV_AZURE_12`) — config pur, sans compromis ni coût réel supplémentaire (stockage Standard LRS de JSON).

Écartés (`skip_check` dans `terraform-ci.yml`) :
- **`CKV2_AZURE_41`** (pas de politique d'expiration SAS) — **bug Checkov confirmé, pas un vrai manque** : le bloc `sas_policy` est présent et suit la doc Prisma Cloud à la lettre, le check échoue quand même. Quelqu'un d'autre a rapporté exactement le même faux positif avec une syntaxe identique ([`bridgecrewio/checkov#6140`](https://github.com/bridgecrewio/checkov/issues/6140)), fermé sans correctif visible. À retirer du skip si une future version de Checkov corrige ça.
- **`CKV_AZURE_59`/`CKV2_AZURE_33`** (accès public / pas de private endpoint) — même arbitrage que `CKV2_AZURE_24` : un private endpoint est une vraie brique d'infra disproportionnée pour un bucket de diagnostic en dev.
- **`CKV2_AZURE_40`** (Shared Key non désactivée) — le seul chemin AAD-only de Network Watcher passe par une identité managée assignée par l'utilisateur, qu'`azurerm_network_watcher_flow_log` ne supporte pas encore dans le provider AzureRM (demande ouverte, `hashicorp/terraform-provider-azurerm#30219`) ; désactiver Shared Key casserait silencieusement l'écriture des flow logs.
- **`CKV2_AZURE_1`** (pas de Customer Managed Key) — des métadonnées réseau (IP/port/allow-deny), pas les données sensibles que ce check vise ; une CMK impliquerait clé Key Vault + RBAC + identité pour un gain réel très faible.
- **`CKV_AZURE_206`** (réplication LRS) — délibéré : JSON de forensic écrit une fois, pas une donnée de continuité d'activité.
- **`CKV_AZURE_33`** (logging du service Queue) — ce storage account ne sert jamais le service Queue, uniquement du blob.
- **`CKV_AZURE_43`** (règles de nommage) — faux positif : Checkov ne résout pas statiquement le `replace()` qui construit le nom à travers la frontière du module ; le nom réellement appliqué (`starkclouddevflow`, confirmé dans la sortie de `terraform apply`) respecte déjà la règle.

### Sprint 6 — Lambda de rotation (`modules/aws/secret-rotation`), 5 findings

Corrigé : `CKV_AWS_50` (traçage X-Ray — réellement utile ici : les deux bugs trouvés lors des premiers runs portaient sur *quand* les choses se produisaient les unes par rapport aux autres).

Écartés :
- **`CKV_AWS_115`** (pas de limite de concurrence au niveau de la fonction) — **tenté et refusé par AWS à l'apply**, ce n'est pas une préférence : `InvalidParameterValueException: Specified ReservedConcurrentExecutions for function decreases account's UnreservedConcurrentExecution below its minimum value of [10]`. Le compte est au quota de concurrence Lambda par défaut, donc toute réservation fait passer le pool non réservé sous le plancher imposé par AWS lui-même. À reprendre après une augmentation de quota — le check est pertinent, il est juste inapplicable en l'état.
- **`CKV_AWS_116`** (pas de DLQ Lambda) — Secrets Manager invoque bien la fonction de façon **asynchrone** (vérifié contre la doc AWS, pas supposé), donc une DLQ serait techniquement applicable. Mais elle ne ferait qu'accumuler des payloads que personne ne lit. Le vrai besoin est de **savoir** qu'une rotation a échoué — construit à la place sous forme d'alarme CloudWatch sur la métrique `Errors` de la fonction, branchée sur le topic SNS d'alertes existant. Sans ça, un échec de rotation est totalement silencieux : Secrets Manager conserve l'ancien mot de passe valide, l'application continue de fonctionner, et la rotation cesse discrètement d'avoir lieu.
- **`CKV_AWS_173`** (variables d'environnement non chiffrées par une clé KMS gérée par le client) — elles sont déjà chiffrées au repos par une clé gérée par AWS, et **aucune de ces variables n'est un secret** (hôte/nom/utilisateur de la base, noms de cluster et de service ECS — le mot de passe n'existe que dans Secrets Manager et en mémoire de la fonction). Même arbitrage que `CKV_AWS_136`/`158`/`149`.
- **`CKV_AWS_272`** (pas de validation de signature de code) — demande un profil AWS Signer : vraie infrastructure de chaîne d'approvisionnement, et pertinente seulement une fois le package construit par un pipeline de confiance plutôt que par la commande de build locale documentée. À reconsidérer si le packaging Lambda passe en CI.

### Sprint 6 — `CKV_AWS_304` : un faux positif qui pointait quand même un vrai manque

**Le finding** : « Ensure Secrets Manager secrets should be rotated within 90 days » échouait sur la ressource construite précisément pour rotater à 90 jours.

**Diagnostic, établi en lisant le code source du check** (`SecretManagerSecret90days.py`) plutôt qu'en supposant : sa condition est `days <= 90`, donc notre valeur passerait. Mais elle est fournie via `var.rotation_interval_days`, que Checkov ne résout pas à travers une frontière de module — `force_int()` renvoie `None`, et le check retombe sur son `CheckResult.FAILED` par défaut. Même classe de faux positif que `CKV_AZURE_43`.

**Ce qui a été fait au-delà du skip** : le check avait beau échouer pour une mauvaise raison, il pointait un manque réel — 90 jours n'était chez nous qu'une **valeur par défaut**, que n'importe quel appelant pouvait porter à 365 sans que rien ne s'y oppose. La « politique de rotation à 90 jours » n'était donc qu'une convention orale. Un bloc `validation` a été ajouté sur la variable **des deux côtés** (`modules/aws/secret-rotation` et `modules/azure/secret-rotation`) : tout intervalle supérieur à 90 jours fait désormais échouer le plan. La contrainte est réellement appliquée, pas seulement documentée — et par Terraform lui-même, pas par un scanner qu'on pourrait désactiver.

### Sprint 6 — HTTPS sur l'ALB AWS (certificat auto-signé)

Corrigés (`modules/aws/alb/main.tf`) : `CKV_AWS_2` (listener HTTPS), `CKV2_AWS_20` (redirect HTTP→HTTPS), `CKV_AWS_103` (politique TLS 1.2 minimum). Pas de domaine réel pour ce projet → pas de certificat ACM validé par DNS possible → certificat auto-signé généré par Terraform (`tls_private_key`/`tls_self_signed_cert`) importé dans ACM. Chiffre bien le trafic navigateur↔ALB, mais sans chaîne de confiance : le navigateur affiche un avertissement. Acceptable en dev (trafic health-check/tests, pas d'utilisateurs réels) ; à remplacer par un vrai certificat DNS-validé dès qu'un domaine existe — les ressources ne changent pas de forme, juste la source du certificat.

Effet de bord traité : `ArkCloud.Blazor` appelle l'API via l'ALB en HTTPS maintenant ; sans rien faire, la validation TLS par défaut du `HttpClient` aurait rejeté chaque appel serveur-à-serveur (personne ne garantit la chaîne d'un certificat auto-signé). Fix côté application (`ArkCloud/frontend/ArkCloud.Blazor/Program.cs`) : un contournement de validation scopé strictement à l'host de l'API configuré, actif uniquement si `Api:TrustSelfSignedCert=true` (mis à `true` uniquement côté AWS dans `environments/dev/main.tf` — Azure ne le définit jamais, son certificat `*.azurewebsites.net` est un vrai certificat Microsoft).

Écarté : **`CKV_AWS_378`** (target group en HTTP) — c'est du TLS offloading délibéré : HTTPS se termine à l'ALB, le trafic vers les tasks Fargate reste en HTTP sur le réseau VPC privé — le pattern standard et sûr pour cette architecture, pas un vrai manque. Faux positif documenté par Checkov lui-même sur exactement ce cas (`bridgecrewio/checkov#6754`). Re-chiffrer ALB→target demanderait un certificat TLS terminé dans chaque conteneur — disproportionné pour du trafic qui ne sort jamais du VPC.

### Sprint 6 — Détection de menaces : GuardDuty (AWS) + Defender for Cloud (Azure)

Même politique de sécurité sur les deux clouds — surveillance continue au niveau plateforme, au-delà de ce que les diagnostic settings/CloudTrail (déjà en place) capturent, qui enregistrent des événements mais n'analysent rien — mécanismes différents parce que les plateformes ne proposent pas la même chose.

| | AWS (`modules/aws/guardduty`) | Azure (`modules/azure/defender`) |
|---|---|---|
| Portée | Détecteur GuardDuty (compte/région) | Plans Defender **scopés à toute la subscription**, pas au resource group — seule ressource de tout ce projet à sortir de la portée `rg-arkcloud-${var.environment}` |
| Ce qui est analysé | CloudTrail (événements de gestion), flow logs VPC, requêtes DNS — inclus dans le détecteur de base, aucun coût ni config supplémentaire | Key Vault (activé) ; App Service et PostgreSQL (désactivés par défaut, voir coût ci-dessous) |
| Alerting | Règle EventBridge → topic SNS d'alertes existant, filtrée sévérité >= Medium, `input_transformer` pour un message lisible | Contact de sécurité natif (email) + export continu vers le même workspace Log Analytics que le reste de l'observabilité |
| Ce qui n'est PAS activé | S3 Protection, EKS Protection, Malware Protection, RDS Protection, Lambda Protection — add-ons payants séparément, pertinents une fois que la brique qu'ils protègent existe réellement (aucun S3 applicatif, pas d'EKS avant Sprint 9) | Defender for App Service, Defender for Databases — voir décision coût |

**Décision coût (Azure)**, vérifiée contre la page de pricing officielle plutôt que supposée : Defender for App Service coûte environ 14,60 $/instance/mois — avec les deux App Services de ce projet (API + Web), ça représente ~29 $/mois, à peu près 4x le plafond de 7 €/mois déjà fixé pour tout le resource group par `modules/azure/cost-guard`. Defender for Databases (PostgreSQL) est traité avec la même prudence, du même ordre de grandeur d'après la documentation Microsoft même si le chiffre exact n'a pas de page de pricing publique dédiée par ressource. Les deux restent désactivés par défaut (`azure_enable_defender_app_service`/`azure_enable_defender_databases`), activables sans changement de code pour staging/prod. Seul Defender for Key Vault est actif par défaut : facturé à la transaction (~0,02 $/10k transactions/mois), négligeable au volume actuel, et c'est le pendant Azure le plus direct du signal que GuardDuty donne côté IAM/credentials AWS (accès anormal aux secrets), que le diagnostic setting `AuditEvent` déjà en place ne fait qu'enregistrer sans jamais l'analyser.

**Tester `azure_enable_defender_app_service`/`azure_enable_defender_databases` sans payer le tarif plein** : la page de pricing Azure (vérifiée directement, pas supposée) précise que Defender for Cloud est **gratuit les 30 premiers jours** dès qu'un plan payant est activé — pas besoin de demander un essai, ça démarre automatiquement à l'`apply`. Même hors de cette fenêtre, la facturation est à l'heure de ressource protégée, pas au mois plein : activer les deux variables dans `terraform.tfvars` (jamais committé), vérifier dans le portail Azure (**Microsoft Defender for Cloud > Environment settings** ou l'onglet **Recommendations**) que App Service/PostgreSQL passent en "protégé", puis repasser les deux variables à `false` et réappliquer — supprime juste les deux ressources `azurerm_security_center_subscription_pricing` et revient au tier `Free`, sans risque ni perte de données. Un cycle activer/vérifier/désactiver dans la même journée reste dans la fenêtre gratuite.

**Bug réel rencontré au premier apply (AWS)** : `aws_guardduty_detector.this` a échoué avec `SubscriptionRequiredException: The AWS Access Key Id needs a subscription for the service` — pas un problème de code ni de permissions IAM (le reste de l'infra tourne sur ce même compte). GuardDuty n'avait simplement jamais été activé une première fois sur ce compte/région ; contrairement à la plupart des ressources AWS, un premier "opt-in" manuel via la console (GuardDuty > Get started) était nécessaire avant que `CreateDetector` fonctionne par API. Un clic suffit, aucun import de state requis ensuite — l'apply Terraform a créé le détecteur normalement juste après.

**Bug réel rencontré au premier apply (Azure)** : `azurerm_security_center_subscription_pricing.key_vault` a forcé un replace juste après sa création — Azure applique lui-même `subplan = "PerKeyVault"` côté serveur dès qu'un tier `Standard` est activé sans le préciser, et Terraform voyait ensuite un écart entre son `null` initial et cette valeur imposée à chaque plan (même dérive perpétuelle que le security group/diagnostic setting plus haut). Fixé en fixant `subplan = "PerKeyVault"` explicitement dans le module.

**Triage Checkov (2 findings, run réel post-apply)** :
- **`CKV_AZURE_20`** (numéro de téléphone du contact de sécurité Defender) — le module accepte déjà `var.alert_phone` (optionnel, câblé jusqu'à `azure_defender_alert_phone` en racine), non renseigné par défaut car c'est une donnée personnelle qui ne doit jamais être codée en dur ni committée même comme valeur par défaut. Écarté avec un vrai chemin d'activation laissé ouvert plutôt que fermé.
- **`CKV2_AWS_3`** (GuardDuty activé au niveau organisation) — vérifié contre la source du check : il réclame un `aws_guardduty_organization_configuration` avec `auto_enable=true`, un mécanisme AWS Organizations pour l'activation automatique multi-comptes. Ce projet est un compte AWS unique, pas une Organization ; cette ressource échouerait même à l'apply (elle exige que le compte soit déjà l'admin délégué GuardDuty d'une Organization). Différence d'architecture, pas un manque.

**Un seul propriétaire pour la politique du topic SNS d'alertes** : la règle EventBridge de GuardDuty a besoin d'une permission explicite pour publier sur `module.aws_monitoring`'s topic (contrairement aux CloudWatch Alarms, qui n'en ont historiquement pas besoin en same-account). Cette permission est déclarée une seule fois, au niveau racine (`environments/dev/main.tf`, `aws_sns_topic_policy.alerts`) — pas dans le module GuardDuty lui-même — avec un commentaire explicite : si un futur module a besoin de publier sur ce même topic, il doit ajouter un statement à ce même document plutôt que créer une seconde ressource `aws_sns_topic_policy` sur le même topic. Deux ressources Terraform propriétaires d'un même attribut de politique se contrediraient à chaque plan — exactement la classe de bug du flip-flop de security group déjà rencontré et corrigé plus haut dans ce même sprint.

---

## 10. Rotation des secrets — procédure manuelle, rappels automatisés (Sprint 6)

Rotation elle-même toujours manuelle — l'automatiser proprement demanderait un vrai pipeline de renouvellement côté Key Vault/Secrets Manager (versions de secrets + redéploiement déclenché par le changement de version), disproportionné pour un environnement dev à ce stade, et pour `Jwt:Key` spécifiquement carrément risqué à automatiser sans support multi-clés (voir plus bas). Ce qui **est** automatisé depuis le Sprint 6 : plus besoin de se souvenir des échéances — `.github/workflows/secret-expiry-check.yml` tourne tous les jours (+ sur chaque modif de l'inventaire) et fait échouer le run si un secret à échéance dure approche de l'expiration, ou si un secret sans échéance dure n'a pas été tourné depuis trop longtemps. Source de vérité : `.github/secrets-inventory.json` — à mettre à jour à chaque rotation réelle, sinon le check continue de réclamer une rotation déjà faite.

| Secret | Où il vit | Échéance / déclencheur | Procédure de rotation |
|---|---|---|---|
| `GHCR_PAT` | Secret GitHub (`ArkCloudInfra`, les deux workflows) + `TF_VAR_ghcr_pat` | **Expire le 24/08/2026** (token classique GitHub, scope `read:packages`) — échéance dure, pas une recommandation | 1) Générer un nouveau token classique `read:packages` sur github.com/settings/tokens. 2) `gh secret set GHCR_PAT --repo epiph11/ArkCloudInfra` (valeur via variable, pas de paste interactif direct — voir le bug de corruption par newline rencontré en §5 point 6). 3) Relancer un `terraform apply` (n'importe lequel des deux workflows) pour que le nouvel App Setting soit poussé. 4) `az webapp restart` sur les deux App Services pour forcer un nouveau pull authentifié. |
| `POSTGRES_ADMIN_PASSWORD` | Secret GitHub (`ArkCloudInfra`) + `TF_VAR_postgres_admin_password` + Key Vault (`ConnectionStrings--DefaultConnection`) | Pas d'échéance dure — à tourner a minima à chaque changement de membre d'équipe ayant eu accès, ou tous les 6 mois en routine | Changer le mot de passe côté Azure (`az postgres flexible-server update` ou portail) d'abord — **pas** via un `terraform apply` direct : `administrator_password` est en `ignore_changes` (§postgresql module) exprès pour qu'un apply non lié ne touche jamais ce mot de passe par accident. Une fois changé côté Azure, mettre à jour le secret GitHub et le secret Key Vault en cohérence, puis redémarrer l'API. |
| `Jwt:Key` | Key Vault (`Jwt--Key`), lu par `ArkCloud.API` | Pas d'échéance dure — rotation invalide tous les tokens actifs (pas de rotation à chaud possible avec une seule clé de signature), donc à faire hors heures de forte utilisation | Générer une nouvelle valeur aléatoire (64+ octets), `az keyvault secret set --name Jwt--Key --vault-name kv-arkcloud-dev`, redémarrer l'API. Effet de bord assumé : tous les utilisateurs connectés sont déloggés (access + refresh tokens signés avec l'ancienne clé deviennent invalides). |

### `docker_registry_password` : diff perpétuel expliqué, volontairement non "fixé" (Sprint 6)

Chaque `plan`/`apply` sur `module.app_service_api`/`module.app_service_web` affiche `~ docker_registry_password = (sensitive value)` en "update in-place", même quand rien n'a changé. Root-cause vérifiée (pas supposée) : l'API Azure ne renvoie jamais la valeur réelle d'un champ marqué sensible sur un `GET` — le provider AzureRM compare donc systématiquement la valeur configurée dans le `.tf` à une valeur vide/absente côté state, pas à l'ancienne valeur réelle. C'est une classe de bug documentée côté provider (issues GitHub `hashicorp/terraform-provider-azurerm` #22379, #22548, #23525, #23632 — déjà en partie corrigées pour `docker_registry_url`/`docker_registry_username`, jamais pour un champ sensible comme `docker_registry_password`, puisque le problème est l'API Azure elle-même, pas le provider).

Deux options évaluées, toutes les deux écartées :
- **`lifecycle { ignore_changes = [...] }` sur ce seul champ** — un fil de discussion HashiCorp confirme que `ignore_changes` sur une clé imbriquée dans `site_config`/`application_stack` ignore en pratique **tout le bloc**, pas juste la clé ciblée. Effet de bord inacceptable ici : ça bloquerait aussi la propagation d'un futur changement légitime de stack/app_settings.
- **Ignorer le champ entièrement** — casserait la procédure de rotation `GHCR_PAT` documentée juste au-dessus (étape 3 : "relancer un `terraform apply` pour que le nouvel App Setting soit poussé"), qui dépend justement de ce que `docker_registry_password` soit réappliqué à chaque run.

Décision : diff accepté tel quel, documenté plutôt que masqué. Il est cosmétique et sans risque — Terraform renvoie à chaque fois la vraie valeur courante (`var.ghcr_pat`), donc l'"update in-place" ne fait que re-confirmer un mot de passe déjà correct, jamais de downtime ni de credential invalide poussé par erreur.

### Rotation automatique des mots de passe Postgres (Sprint 6)

Les deux mots de passe Postgres tournent maintenant **tout seuls tous les 90 jours**, sur les deux clouds, sans intervention. Même politique, deux mécanismes différents parce que les plateformes ne proposent pas la même chose :

| | Azure (`modules/azure/secret-rotation`) | AWS (`modules/aws/secret-rotation`) |
|---|---|---|
| Moteur | Automation Runbook PowerShell + `azurerm_automation_schedule` | Rotation native Secrets Manager + Lambda custom |
| Étapes | change le mot de passe serveur → réécrit `ConnectionStrings--DefaultConnection` dans Key Vault → redémarre l'App Service API | machine à états `createSecret`/`setSecret`/`testSecret`/`finishSecret` → force un nouveau déploiement du service ECS API |
| Vérification avant bascule | non (l'ordre des étapes limite le risque) | **oui** — `testSecret` se connecte réellement à la base avec le nouveau mot de passe avant de le promouvoir ; en cas d'échec, rien n'est promu et l'ancien reste valide |
| Identité | identité managée système, 3 role assignments scopés (serveur Postgres / Key Vault / App Service) | rôle IAM avec permissions scopées au secret, à l'instance RDS et au service ECS |

**Pourquoi une Lambda custom côté AWS plutôt que le template AWS tout fait** : la Lambda `SecretsManagerRDSPostgreSQLRotationSingleUser` d'AWS exige un secret au format JSON structuré. Ici le secret contient une chaîne de connexion .NET brute, parce qu'`ArkCloud.API` la lit telle quelle via `GetConnectionString("DefaultConnection")` et que la task definition ECS la mappe directement sur `ConnectionStrings__DefaultConnection`. Reformater le secret aurait voulu dire modifier l'application **et** diverger d'Azure, qui lit une chaîne de connexion depuis Key Vault de la même façon.

**Étape de build requise (AWS uniquement)** : le package Lambda embarque `psycopg2`, absent du runtime Python de Lambda — voir `modules/aws/secret-rotation/lambda/README.md`. À construire une fois avant le premier apply, et à reconstruire à chaque modification de `rotate.py`.

**Reproductibilité du build Lambda entre local (Windows/Git Bash) et CI (Ubuntu)** : `filebase64sha256()` sur le zip signifie que deux constructions du même code doivent produire le même hash, sous peine de voir Terraform considérer la Lambda comme modifiée à chaque alternance local/CI — même classe de problème que le flip-flop de security group ci-dessus. Diagnostic en plusieurs manches, chacune tranchée par une preuve directe plutôt que supposée corrigée (détail complet dans `modules/aws/secret-rotation/lambda/README.md`) :
1. Fins de ligne CRLF sur `rotate.py` — fix appliqué, sans effet réel : `rotate.py` n'a jamais divergé.
2. Un `terraform plan` vide observé en CI, pris à tort pour une preuve de convergence — il comparait le build de la CI à un state que la CI elle-même avait posé, pas au build local.
3. `psycopg2_binary-2.9.10.dist-info/RECORD`, trouvé via le manifeste par fichier (`build/manifest.txt`, un hash SHA-256 par fichier archivé) : seul fichier différent sur 34, une métadonnée que pip génère lui-même à l'installation et formate différemment selon sa version. Fixé en supprimant tout `*.dist-info` du package.
4. Après le fix #3, un nouveau manifeste comparé des deux côtés a montré les 27 fichiers restants strictement identiques (`rotate.py` compris) — et le zip final divergeait quand même. Cause réelle : `zipfile` compresse via `zlib`, dont le flux DEFLATE n'est pas garanti identique bit à bit entre deux versions/plateformes pour un même contenu source (documenté sur reproducible-builds.org). Fixé en passant l'archivage en `ZIP_STORED` (sans compression) plutôt qu'en essayant de figer une version de zlib.

Leçon générale, gardée telle quelle pour la suite : la preuve de reproductibilité qui compte est la comparaison directe des deux builds (le manifeste par fichier), pas un plan Terraform qui peut être vide pour une mauvaise raison — et l'absence de divergence de contenu n'exclut pas une divergence d'encodage/compression en aval.

**Toujours pas automatisé, volontairement** : `Jwt:Key` (chaque rotation invalide tous les tokens actifs — `ArkCloud.API` n'a pas de support multi-clés `kid` pour basculer en douceur) et `GHCR_PAT` (token GitHub personnel, aucune API cloud ne peut le faire tourner ; il faudrait une GitHub App). Ces deux-là restent sur la procédure manuelle ci-dessus + le rappel d'échéance.

## 11. Audit IAM moindre-privilège (Sprint 6)

Revue systématique de toutes les identités créées par ce repo (rôles IAM AWS, role assignments Azure) : pour chacune, le principal qui l'assume, les permissions exactes accordées, le scope exact, et si ces permissions correspondent à ce que le code appelle réellement (vérifié ligne à ligne contre `rotate.py`, les runbooks PowerShell, etc. — pas supposé).

**Déjà correct, confirmé plutôt que juste espéré** : les rôles IAM ECS (`modules/aws/ecs`), le rôle de la Lambda de rotation AWS (`modules/aws/secret-rotation` — la policy correspond exactement aux appels `boto3` réellement faits dans `rotate.py`), le rôle CloudTrail→CloudWatch Logs, l'assignation Key Vault de l'API (`modules/azure/identity`, lecture seule), et l'assignation "Key Vault Secrets Officer" du runbook de rotation Azure (déjà le rôle intégré le plus étroit possible — Azure RBAC ne descend pas au niveau d'un secret individuel).

**Corrigé dans ce sprint** — trois assignations Azure utilisaient `Contributor` scopé à une seule ressource : ça limitait bien le *rayon d'action* (cette ressource précise, jamais la resource group), mais pas les *actions permises dessus* (resize, suppression, changement réseau — bien plus que ce que chaque runbook fait réellement). Remplacées par des rôles Azure personnalisés (`azurerm_role_definition`), chacun limité aux actions RBAC exactes utilisées, vérifiées contre la liste officielle des opérations (`learn.microsoft.com/.../permissions/databases` et `.../web-and-mobile`) avant d'être écrites :

| Identité | Avant | Après | Ce que le code fait réellement |
|---|---|---|---|
| `modules/azure/cost-guard` (runbook stop) | `Contributor` sur le serveur Postgres | Rôle personnalisé : `.../flexibleServers/{read,stop/action}` | `Stop-AzPostgresFlexibleServer`, rien d'autre — pas même le redémarrage (fait à la main par un humain) |
| `modules/azure/secret-rotation` (runbook rotation, étape 1) | `Contributor` sur le serveur Postgres | Rôle personnalisé : `.../flexibleServers/{read,write}` | PATCH sur `administratorLoginPassword` — `write` reste nécessaire car Azure RBAC ne distingue pas les champs à l'intérieur d'un PATCH, mais `delete` et tout le reste disparaissent |
| `modules/azure/secret-rotation` (runbook rotation, étape 3) | `Contributor` sur l'App Service | Rôle personnalisé : `.../sites/{read,restart/action}` | `POST /restart`, rien d'autre — pas d'accès à la config, l'image conteneur ou les app settings |

**Trouvé et corrigé manuellement (hors Terraform, actions `az`/`aws` CLI par le user)** :

- **Rôle CI Azure AD (`github-arkcloudinfra`, README §6) : `Contributor` sur toute la souscription**, pas sur `rg-arkcloud-dev` — la sur-permission la plus significative du repo côté Azure. Corrigé :

  ```powershell
  $appId = "63df2a4f-1129-424e-b6cf-b6c6613bc022"
  $subId = "dd810534-1452-4967-95ed-cf2de0fd5816"

  az role assignment delete --assignee $appId --role "Contributor" --scope "/subscriptions/$subId"

  az role assignment create --assignee $appId --role "Contributor" `
    --scope "/subscriptions/$subId/resourceGroups/rg-arkcloud-dev"
  ```

  `Storage Blob Data Contributor` sur `arkcloudstatestore` reste inchangé — déjà correctement scopé. Compromis connu : quand `environments/staging`/`prod` existeront, chacun aura besoin de sa propre assignation `Contributor` scopée à son propre resource group — le confort d'un scope souscription (couvrir automatiquement tout futur RG) est précisément ce qu'on a retiré ici, en échange d'un vrai périmètre.

- **Rôle IAM AWS `arkcloudinfra-ci` : `AdministratorAccess`** — pire que "non documenté" : l'identité qui fait tourner `terraform apply` sur `environments/dev` avait un accès admin complet au compte AWS, sans aucun rapport avec ce qu'elle gère réellement. Corrigé en deux policies IAM personnalisées, construites à partir d'un inventaire réel des 47 types de ressources `aws_*` que ce Terraform gère (pas deviné) — une seule policy dépassait la limite AWS de 6144 caractères (customer-managed policy), d'où le split :
  - `ci-terraform-policy-part1-compute.json` — EC2/réseau, ELB, ACM, ECR, ECS, IAM (création des rôles ECS/Lambda + `PassRole` scopé à `ecs-tasks.amazonaws.com`/`lambda.amazonaws.com` uniquement)
  - `ci-terraform-policy-part2-data.json` — Lambda (rotation), Secrets Manager, SNS, CloudWatch/EventBridge, CloudTrail, S3 (bucket CloudTrail), GuardDuty, RDS

  Scope par ARN sur le préfixe `arkcloud-dev-*` et le compte `386275436389` partout où AWS le permet (ECR, IAM, Lambda, Secrets Manager, SNS, RDS, S3) ; wildcard uniquement là où AWS ne supporte pas de permissions au niveau ressource pour ces actions (réseau EC2, ELB, ACM, ECS, GuardDuty, CloudTrail, CloudWatch/EventBridge).

  ```powershell
  aws iam create-policy --policy-name arkcloudinfra-ci-compute --policy-document file://ci-terraform-policy-part1-compute.json
  aws iam create-policy --policy-name arkcloudinfra-ci-data --policy-document file://ci-terraform-policy-part2-data.json
  aws iam attach-role-policy --role-name arkcloudinfra-ci --policy-arn arn:aws:iam::386275436389:policy/arkcloudinfra-ci-compute
  aws iam attach-role-policy --role-name arkcloudinfra-ci --policy-arn arn:aws:iam::386275436389:policy/arkcloudinfra-ci-data
  aws iam detach-role-policy --role-name arkcloudinfra-ci --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
  ```

  Vérifié par un `terraform plan` complet, propre, **après** avoir détaché `AdministratorAccess` (pas juste testé en parallèle) : `0 to add, 2 to change, 0 to destroy` — les deux seuls changements sont le diff `docker_registry_password` déjà documenté ci-dessus, aucune erreur `AccessDenied`. La policy admin a été retirée pour de bon, rien n'en dépendait.

**Ce qui reste manuel malgré le rappel automatique** : le check ne fait qu'alerter (job rouge dans l'onglet Actions, + email GitHub par défaut aux personnes qui watchent le repo) — il ne tourne aucun secret lui-même. Après chaque rotation réelle, mettre à jour `.github/secrets-inventory.json` (`expires_on` pour `GHCR_PAT`, `last_rotated` pour les deux mots de passe Postgres et `Jwt:Key`) — sinon le check continuera de réclamer une rotation déjà effectuée à la prochaine échéance. Pas encore fait, volontairement : une vraie automatisation de la rotation elle-même pour `POSTGRES_ADMIN_PASSWORD` (Azure via Automation Runbook, AWS via rotation native Secrets Manager) — candidat naturel pour la suite du Sprint 6.

---

## 12. Fitness functions (Sprint 6)

Voir `docs/infra-roadmap.md` (dépôt ArkCloud) Step 18.7 pour le contexte complet : une fitness function est un test automatisé exécuté en CI qui casse le build quand une caractéristique d'architecture (structure, coût, sécurité...) dérive — exactement comme un test unitaire casse le build quand le comportement dérive. Deux implémentées ce sprint, une structurelle (dépôt ArkCloud) et une de coût (ce dépôt) :

- **Structurelle — ArchUnitNET** (`ArkCloud/backend/tests/ArkCloud.Tests.Architecture`) : sens de dépendance Clean Architecture (Domain ← Application ← Infrastructure ← API, jamais l'inverse ni de travers), indépendance du Domain/Application vis-à-vis d'EF Core et d'ASP.NET Core, placement des Controllers/Repositories dans la bonne couche. Exécuté comme step dédié dans `arkcloud-backend-ci.yml`, séparé de `Test` pour qu'une violation d'architecture soit immédiatement lisible comme telle plutôt que noyée dans la sortie des tests unitaires/intégration.
- **Coût — infracost** (`terraform-ci.yml`, nouveau job `infracost`) : compare le coût mensuel estimé du plan de la PR à celui de la branche de base, poste un commentaire sur la PR, et **échoue le job si le coût mensuel estimé augmente de plus de 20 $** (`MAX_MONTHLY_COST_INCREASE_USD`) — seuil choisi contre le budget Azure existant (7 €/mois, cost-guard), sans prétendre le reproduire exactement puisque le coût AWS (NAT Gateway, RDS, ECS Fargate...) dépasse déjà ce chiffre à lui seul. Le gate lui-même est un simple `jq`/Python sur la sortie JSON de la CLI open source d'infracost — pas Infracost Cloud/Cost Policies, qui sont payants.

**Pourquoi un job séparé plutôt qu'ajouté à `validate`** : `infracost` ne bloque ni `validate` ni `apply` s'il échoue ou si le secret n'est pas encore posé — chaque step est gardé par `if: env.INFRACOST_API_KEY != ''`, donc tant que le secret n'existe pas le job entier est un no-op silencieux. Le pipeline de déploiement réel (durci sur plusieurs semaines ce sprint : reproductibilité du build Lambda, GuardDuty/Defender, audit IAM) ne dépend d'aucune façon d'un outil de coût tiers.

**Setup requis, pas encore fait** : créer un compte gratuit sur infracost.io/dashboard, `infracost auth login` en local pour récupérer la clé API, puis `gh secret set INFRACOST_API_KEY --repo epiph11/ArkCloudInfra`. Sans ce secret, le job tourne mais ne fait rien (voir garde ci-dessus) — aucun risque à merger ce changement avant que le secret soit posé.

**Non vérifié par un run réel** : contrairement à tout le reste de ce sprint (Lambda, GuardDuty, Defender, audit IAM — chacun confirmé par un vrai `terraform apply`/`plan` avant d'être documenté comme "fait"), ni le job ArchUnitNET ni le job infracost n'ont encore tourné une seule fois en CI au moment d'écrire ceci — `dotnet` et l'accès réseau pour télécharger la CLI infracost ne sont pas disponibles dans le bac à sable où ce code a été écrit. Les deux s'appuient sur la syntaxe documentée officiellement (`archunitnet.readthedocs.io`, `github.com/infracost/actions`) plutôt que sur une exécution réelle. À tester avant de considérer ce point clos : un `dotnet test` local sur `ArkCloud.Tests.Architecture`, et une vraie PR sur `ArkCloudInfra` une fois `INFRACOST_API_KEY` posé.
