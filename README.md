# ArkCloudInfra

Infrastructure as Code (Terraform) pour ArkCloud — Azure d'abord (Sprint 4), puis AWS (Sprint 5). Gouvernance et cycle de vie séparés du repo applicatif `ArkCloud` : une erreur de code applicatif ne touche jamais les credentials/permissions cloud, et les changements d'infra suivent leur propre revue, indépendante de celle du code.

Ce document retrace en détail toutes les étapes réalisées jusqu'ici pour le Sprint 4 (CI/CD + Azure), dans l'ordre où elles ont été faites, avec les commandes exactes et les décisions prises.

---

## Statut d'ensemble

| Sprint | Contenu | Statut |
|---|---|---|
| 4 | Fondation Azure (RG, VNet, PostgreSQL, Key Vault, Managed Identity, App Service ×2, App Insights) | ✅ Infra appliquée pour de vrai — reste CI/CD + contenu applicatif |
| 5 | Fondation AWS (VPC, ECR, ECS Fargate, ALB, RDS, Secrets Manager) | ⏳ À venir |
| 9 | Kubernetes (AKS/EKS) — hors de ce repo, manifests dans `ArkCloud/deploy/kubernetes/` | ⏳ À venir |

Voir `ArkCloud/docs/infra-roadmap.md` (repo applicatif) pour le plan complet, tous sprints confondus.

**Statut réel dans Azure (mis à jour après le premier `apply` complet)** :

| Ressource | Nom réel |
|---|---|
| Resource Group | `rg-arkcloud-dev` |
| Virtual Network | `vnet-arkcloud-dev` (+ 4 subnets, 3 NSG) |
| PostgreSQL Flexible Server | `psql-arkcloud-dev` — `psql-arkcloud-dev.postgres.database.azure.com` (accès privé uniquement) |
| Key Vault | `kv-arkcloud-dev` — `https://kv-arkcloud-dev.vault.azure.net/` |
| App Service (API) | `app-arkcloud-api-dev` — `app-arkcloud-api-dev.azurewebsites.net` |
| App Service (Blazor) | `app-arkcloud-web-dev` — `app-arkcloud-web-dev.azurewebsites.net` |
| Log Analytics + App Insights | `log-arkcloud-dev` / `appi-arkcloud-dev` |

Les deux App Services tournent mais n'ont pas encore d'image réelle à tirer (le registre GHCR ne contient encore rien tant qu'aucune CI n'a été déclenchée pour de vrai — §5, point 2) — c'est normal de voir une page par défaut/erreur en visitant les hostnames pour l'instant. Key Vault contient désormais `Jwt--Key` et `ConnectionStrings--DefaultConnection` (§8) — reste à valider avec du vrai trafic une fois l'image API en place.

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
6. **Vérifier le monitoring** — Application Insights remonte bien requêtes/exceptions/dépendances des deux apps une fois qu'elles serviront du vrai trafic.
7. **Checklist de clôture Sprint 4** — sous-partie Azure/DevOps de `ArkCloud/docs/infra-roadmap.md` Step 17.

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
