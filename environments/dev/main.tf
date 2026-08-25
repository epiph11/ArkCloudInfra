module "resource_group" {
  source = "../../modules/azure/resource-group"

  name     = "rg-arkcloud-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

module "network" {
  source = "../../modules/azure/network"

  resource_group_name = module.resource_group.name
  location            = var.location
  vnet_name           = "vnet-arkcloud-${var.environment}"
  address_space       = ["10.10.0.0/16"]

  # See ArkCloudInfra/README.md §3 for why api/web are two separate subnets rather than one.
  api_subnet_prefix              = "10.10.1.0/24"
  web_subnet_prefix              = "10.10.4.0/24"
  database_subnet_prefix         = "10.10.2.0/24"
  private_endpoint_subnet_prefix = "10.10.3.0/24"

  tags = local.common_tags
}

module "postgresql" {
  source = "../../modules/azure/postgresql"

  resource_group_name = module.resource_group.name
  location            = var.location
  server_name         = "psql-arkcloud-${var.environment}"
  sku_name            = var.postgres_sku

  administrator_login    = var.postgres_admin_login
  administrator_password = var.postgres_admin_password

  delegated_subnet_id = module.network.database_subnet_id
  virtual_network_id  = module.network.vnet_id

  # geo_redundant_backup_enabled left at its false default — dev doesn't need it, staging/prod will override.
  tags = local.common_tags
}

module "key_vault" {
  source = "../../modules/azure/key-vault"

  resource_group_name = module.resource_group.name
  location            = var.location
  name                = "kv-arkcloud-${var.environment}"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  tags = local.common_tags
}

module "monitoring" {
  source = "../../modules/azure/monitoring"

  resource_group_name = module.resource_group.name
  location            = var.location
  log_analytics_name  = "log-arkcloud-${var.environment}"
  app_insights_name   = "appi-arkcloud-${var.environment}"

  tags = local.common_tags
}

# --- ArkCloud.API ---
module "app_service_api" {
  source = "../../modules/azure/app-service"

  resource_group_name = module.resource_group.name
  location            = var.location
  plan_name           = "asp-arkcloud-api-${var.environment}"
  app_name            = "app-arkcloud-api-${var.environment}"
  sku_name            = var.app_service_sku

  vnet_integration_subnet_id = module.network.api_subnet_id

  container_image_name = "${var.image_org}/arkcloud-api"
  container_image_tag  = var.api_image_tag

  container_registry_url      = "https://ghcr.io"
  container_registry_username = var.ghcr_username
  container_registry_password = var.ghcr_pat

  key_vault_uri                  = module.key_vault.vault_uri
  app_insights_connection_string = module.monitoring.connection_string

  tags = local.common_tags
}

# The API's identity needs to read secrets from Key Vault — Blazor doesn't (it never touches
# the DB password or the JWT signing key directly), so no equivalent role assignment exists
# for app_service_web below.
module "keyvault_access_api" {
  source = "../../modules/azure/identity"

  scope        = module.key_vault.id
  principal_id = module.app_service_api.principal_id
  # role_definition_name defaults to "Key Vault Secrets User"
}

# --- ArkCloud.Blazor ---
module "app_service_web" {
  source = "../../modules/azure/app-service"

  resource_group_name = module.resource_group.name
  location            = var.location
  plan_name           = "asp-arkcloud-web-${var.environment}"
  app_name            = "app-arkcloud-web-${var.environment}"
  sku_name            = var.app_service_sku

  vnet_integration_subnet_id = module.network.web_subnet_id

  container_image_name = "${var.image_org}/arkcloud-frontend"
  container_image_tag  = var.web_image_tag

  container_registry_url      = "https://ghcr.io"
  container_registry_username = var.ghcr_username
  container_registry_password = var.ghcr_pat

  # Blazor doesn't read secrets from Key Vault today, but the module requires the variable —
  # harmless: the app setting just goes unused. Kept for consistency rather than making the
  # module conditionally accept it for one caller.
  key_vault_uri                  = module.key_vault.vault_uri
  app_insights_connection_string = module.monitoring.connection_string

  # Wires Blazor to the API's real hostname without either side hardcoding it.
  extra_app_settings = {
    "Api__BaseUrl" = "https://${module.app_service_api.default_hostname}"
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Audit / diagnostic logging — Step 17 checklist item ("Audit logging activé").
# ---------------------------------------------------------------------------
# Until now, Log Analytics only received *application* telemetry (App Insights SDK, see
# README §5 point 6) — nothing at the platform level. These four diagnostic settings route
# Key Vault access events, PostgreSQL server logs, and both App Services' platform/HTTP logs
# into the same workspace, so an actual audit trail exists for "who read which secret" /
# "what hit the database" / "what did each App Service serve", not just app-level requests.
#
# `category_group = "allLogs"` (rather than enumerating individual categories like
# "AuditEvent" or "AppServiceHTTPLogs") is deliberate: it's the modern azurerm v4 shorthand
# for "every log category this resource type currently exposes," so this doesn't silently
# stop capturing a category if Azure renames/adds one later.
#
# NOT included here: NSG flow logs. Those need Network Watcher + a Storage Account
# (azurerm_network_watcher_flow_log), which is meaningfully more infrastructure than a
# diagnostic setting on an existing resource — left for Sprint 6 hardening rather than
# folded into this pass.

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-kv-arkcloud-${var.environment}"
  target_resource_id         = module.key_vault.id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "postgresql" {
  name                       = "diag-psql-arkcloud-${var.environment}"
  target_resource_id         = module.postgresql.server_id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "app_service_api" {
  name                       = "diag-app-arkcloud-api-${var.environment}"
  target_resource_id         = module.app_service_api.id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  # Bug réel trouvé au premier test end-to-end (28/07) : sans ce réglage, Terraform crée le
  # diagnostic setting en mode legacy "Azure Diagnostics" (une seule table AzureDiagnostics
  # partagée par tout, filtrée par ResourceProvider/Category). Ça a marché en quelques minutes
  # pour Key Vault (AuditEvent) et PostgreSQL (PostgreSQLLogs), mais AUCUNE ligne n'est jamais
  # apparue pour les App Services (AppServiceHTTPLogs/AppServiceConsoleLogs/AppServicePlatformLogs)
  # même après 30 min d'attente et du vrai trafic HTTP généré exprès. Le mode "Azure Diagnostics"
  # est documenté par Microsoft comme le pipeline le moins fiable spécifiquement pour
  # Microsoft.Web/sites — "Dedicated" (tables dédiées, une par catégorie) est le mode recommandé
  # pour ce type de ressource. Changer cet attribut force un remplacement du diagnostic setting
  # (delete+create), pas un update en place — normal, pas une erreur au prochain plan/apply.
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }

  # Dérive perpétuelle, tracée jusqu'à sa cause plutôt que subie : l'API Azure ne renvoie pas
  # log_analytics_destination_type pour Microsoft.Web/sites, donc Terraform le voit toujours
  # absent et veut le reposer — à chaque plan, indéfiniment, sans jamais converger (défaut connu
  # du provider, hashicorp/terraform-provider-azurerm#17172).
  #
  # Le réglage EST bien appliqué côté Azure : vérifié au Sprint 4 par requête KQL réelle, les
  # tables dédiées (AppServiceHTTPLogs, AppServiceConsoleLogs) reçoivent des lignes — ce qui
  # n'était pas le cas en mode legacy. C'est donc l'API qui ne le rapporte pas, pas le réglage
  # qui manque. Le contournement souvent conseillé (retirer l'attribut) serait ici une
  # régression : il ramènerait le mode legacy dont on sait qu'il ne remonte rien.
  #
  # ignore_changes plutôt que subir : un plan qui n'est jamais vide perd sa valeur de signal —
  # on ne distingue plus une dérive attendue d'un vrai changement non désiré. C'est précisément
  # ce que le Step 18.7 (fitness functions) exige de préserver.
  lifecycle {
    ignore_changes = [log_analytics_destination_type]
  }
}

# ---------------------------------------------------------------------------
# AWS (Sprint 5) — same environments/dev root module and state file as Azure above, per
# docs/infra-roadmap.md's multi-cloud decision: one `terraform apply` provisions both clouds
# rather than splitting into a second root module to keep in sync by hand.
# ---------------------------------------------------------------------------

module "aws_vpc" {
  source = "../../modules/aws/vpc"

  name_prefix = "arkcloud-${var.environment}"
  azs         = var.aws_azs

  tags = local.common_tags
}

module "aws_security" {
  source = "../../modules/aws/security"

  name_prefix = "arkcloud-${var.environment}"
  vpc_id      = module.aws_vpc.vpc_id

  tags = local.common_tags
}

# Step 12 — Amazon RDS PostgreSQL. Only depends on the network module (private database
# subnets + sg-database) — no dependency on ECS/ALB, which is why it lands before Step 11
# (ECS Fargate) in build order even though the roadmap numbers it after.
module "aws_rds" {
  source = "../../modules/aws/rds"

  name_prefix    = "arkcloud-${var.environment}"
  instance_class = var.aws_postgres_instance_class

  master_username = var.aws_postgres_admin_login
  master_password = var.aws_postgres_admin_password

  db_subnet_group_name = module.aws_vpc.db_subnet_group_name
  security_group_id    = module.aws_security.database_security_group_id

  tags = local.common_tags
}

# Step 13 (AWS side) — secret containers only, same "no values via Terraform" rule as
# modules/azure/key-vault. IAM read access gets attached to the ECS task role once it exists
# (Step 11) — these just need to exist first so that policy has an ARN to reference.
module "aws_secrets" {
  source = "../../modules/aws/secrets"

  name_prefix = "arkcloud-${var.environment}"

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Step 11 — ECR, ECS Fargate, ALB. Registry decision (task #33): ECR now, JFrog later as
# separate work. IMPORTANT — ArkCloud's own CI (arkcloud-backend-ci.yml/arkcloud-frontend-ci.yml,
# in the ArkCloud repo, not this one) still only pushes to GHCR today. Until that's updated to
# also push to the two ECR repos below, `terraform apply` here succeeds but the ECS tasks will
# fail to start with CannotPullContainerError — the AWS equivalent of Sprint 4's "image never
# existed" bug. Tracked to fix before Step 11 is actually verified end-to-end (task #38).
#
# ALSO IMPORTANT — the "secrets" env var names below (ConnectionStrings__DefaultConnection,
# Jwt__Key) are assumptions based on .NET's "__" config-nesting convention and the existing
# Jwt--Key Key Vault secret name, NOT confirmed against ArkCloud.API's actual appsettings.json/
# Program.cs in this session. Verify the real config key names before relying on this — wrong
# names mean the app silently falls back to whatever default connection string/JWT key its
# appsettings.json ships with, not a visible error.
# ---------------------------------------------------------------------------

module "aws_ecr" {
  source = "../../modules/aws/ecr"

  name_prefix = "arkcloud-${var.environment}"

  tags = local.common_tags
}

module "aws_ecs" {
  source = "../../modules/aws/ecs"

  name_prefix = "arkcloud-${var.environment}"

  postgres_secret_arn = module.aws_secrets.postgres_secret_arn
  jwt_secret_arn      = module.aws_secrets.jwt_secret_arn

  tags = local.common_tags
}

module "aws_alb" {
  source = "../../modules/aws/alb"

  name_prefix       = "arkcloud-${var.environment}"
  vpc_id            = module.aws_vpc.vpc_id
  public_subnet_ids = module.aws_vpc.public_subnet_ids
  security_group_id = module.aws_security.alb_security_group_id

  tags = local.common_tags
}

module "aws_ecs_service_api" {
  source = "../../modules/aws/ecs-service"

  name_prefix  = "arkcloud-${var.environment}"
  service_name = "api"

  cluster_id          = module.aws_ecs.cluster_id
  execution_role_arn  = module.aws_ecs.execution_role_arn
  task_role_arn       = module.aws_ecs.task_role_arn
  subnet_ids          = module.aws_vpc.ecs_subnet_ids
  security_group_id   = module.aws_security.ecs_api_security_group_id
  target_group_arn    = module.aws_alb.api_target_group_arn
  container_image     = module.aws_ecr.api_repository_url
  container_image_tag = var.api_image_tag

  environment = {
    ASPNETCORE_ENVIRONMENT = "Production"
  }

  # See the module-level comment above — verify these two config key names against the real
  # app before treating this as working.
  secrets = {
    ConnectionStrings__DefaultConnection = module.aws_secrets.postgres_secret_arn
    Jwt__Key                             = module.aws_secrets.jwt_secret_arn
  }

  tags = local.common_tags
}

module "aws_ecs_service_web" {
  source = "../../modules/aws/ecs-service"

  name_prefix  = "arkcloud-${var.environment}"
  service_name = "web"

  cluster_id          = module.aws_ecs.cluster_id
  execution_role_arn  = module.aws_ecs.execution_role_arn
  task_role_arn       = module.aws_ecs.task_role_arn
  subnet_ids          = module.aws_vpc.ecs_subnet_ids
  security_group_id   = module.aws_security.ecs_web_security_group_id
  target_group_arn    = module.aws_alb.web_target_group_arn
  container_image     = module.aws_ecr.web_repository_url
  container_image_tag = var.web_image_tag

  # Blazor never touches the DB/JWT secrets directly (mirrors Azure's app_service_web having
  # no Key Vault role assignment) — no `secrets` block needed here.
  #
  # Api__BaseUrl is https:// as of Sprint 6 (modules/aws/alb's self-signed ACM cert) — port 80
  # now only redirects, it doesn't forward. Api__TrustSelfSignedCert=true tells
  # ArkCloud.Blazor's Program.cs to skip TLS chain validation for calls to this exact host only
  # (see that file's comment) — required because nothing vouches for a self-signed cert's chain,
  # and the default HttpClient would otherwise reject every API call. Remove this setting the
  # moment a real domain + trusted ACM cert exists for the ALB.
  environment = {
    ASPNETCORE_ENVIRONMENT   = "Production"
    Api__BaseUrl             = "https://${module.aws_alb.alb_dns_name}/api"
    Api__TrustSelfSignedCert = "true"
  }

  tags = local.common_tags
}

# --- AWS monitoring & audit (Step 15, task #37) ---

module "aws_cloudtrail" {
  source = "../../modules/aws/cloudtrail"

  name_prefix = "arkcloud-${var.environment}"
  tags        = local.common_tags
}

locals {
  # CloudWatch's ALB/TargetGroup dimensions want the ARN's resource segment, not the full ARN —
  # and inconsistently: LoadBalancer drops the "loadbalancer/" prefix, TargetGroup keeps
  # "targetgroup/". See modules/aws/monitoring/variables.tf for why.
  aws_alb_arn_suffix    = trimprefix(split(":", module.aws_alb.alb_arn)[5], "loadbalancer/")
  aws_api_tg_arn_suffix = split(":", module.aws_alb.api_target_group_arn)[5]
  aws_web_tg_arn_suffix = split(":", module.aws_alb.web_target_group_arn)[5]
}

module "aws_monitoring" {
  source = "../../modules/aws/monitoring"

  name_prefix = "arkcloud-${var.environment}"

  ecs_cluster_name = module.aws_ecs.cluster_name
  api_service_name = module.aws_ecs_service_api.service_name
  web_service_name = module.aws_ecs_service_web.service_name

  api_log_group_name = module.aws_ecs_service_api.log_group_name
  web_log_group_name = module.aws_ecs_service_web.log_group_name

  alb_arn_suffix              = local.aws_alb_arn_suffix
  api_target_group_arn_suffix = local.aws_api_tg_arn_suffix
  web_target_group_arn_suffix = local.aws_web_tg_arn_suffix

  rds_instance_id = module.aws_rds.db_instance_id

  alarm_email = var.aws_alarm_email

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Cost guard (Azure only, see docs/infra-roadmap.md Journal des décisions) — at
# var.azure_budget_amount_eur/month actual spend on rg-arkcloud-${env}, stops PostgreSQL
# automatically rather than "switching App Service to a cheaper tier": confirmé live que
# Free/Shared tiers don't support the Regional VNet Integration the API app depends on to reach
# Postgres privately, so Basic B1 is already the cheapest viable App Service tier — there's no
# graceful cheaper fallback to switch to on that side.
# ---------------------------------------------------------------------------

module "azure_cost_guard" {
  source = "../../modules/azure/cost-guard"

  resource_group_name = module.resource_group.name
  resource_group_id   = module.resource_group.id
  location            = var.location
  name_prefix         = "arkcloud-${var.environment}"

  postgres_server_id   = module.postgresql.server_id
  postgres_server_name = "psql-arkcloud-${var.environment}"

  budget_amount_eur = var.azure_budget_amount_eur
  budget_start_date = var.azure_budget_start_date
  alert_email       = var.azure_alarm_email

  tags = local.common_tags
}

# AWS counterpart to module.azure_secret_rotation below — same 90-day policy, different
# mechanism (Secrets Manager rotation + custom Lambda vs. Automation Runbook + schedule).
# Requires the Lambda package to be built first: see modules/aws/secret-rotation/lambda/README.md.
module "aws_secret_rotation" {
  source = "../../modules/aws/secret-rotation"

  name_prefix = "arkcloud-${var.environment}"

  secret_arn = module.aws_secrets.postgres_secret_arn

  db_instance_identifier = module.aws_rds.db_instance_identifier
  db_instance_arn        = module.aws_rds.arn
  db_host                = module.aws_rds.address
  db_port                = module.aws_rds.port
  db_name                = module.aws_rds.database_name
  db_username            = module.aws_rds.master_username

  ecs_cluster_name = module.aws_ecs.cluster_name
  ecs_service_name = module.aws_ecs_service_api.service_name
  ecs_service_arn  = module.aws_ecs_service_api.service_arn

  vpc_subnet_ids = module.aws_vpc.ecs_subnet_ids

  # SG created in module.aws_security alongside sg-database, not inside the rotation module —
  # see that module's comment: inline and standalone security group rules can't coexist.
  security_group_id = module.aws_security.secret_rotation_security_group_id

  rotation_interval_days = var.aws_rotation_interval_days

  # Reuses the existing alerts topic rather than creating a second notification path — a failed
  # rotation lands in the same inbox as the CloudWatch alarms already configured.
  alarm_sns_topic_arn = module.aws_monitoring.sns_topic_arn

  tags = local.common_tags
}

module "azure_secret_rotation" {
  source = "../../modules/azure/secret-rotation"

  resource_group_name = module.resource_group.name
  resource_group_id   = module.resource_group.id
  location            = var.location
  name_prefix         = "arkcloud-${var.environment}"

  postgres_server_id      = module.postgresql.server_id
  postgres_server_name    = module.postgresql.server_name
  postgres_server_fqdn    = module.postgresql.fqdn
  postgres_admin_username = module.postgresql.administrator_login
  postgres_database_name  = module.postgresql.database_name

  key_vault_id   = module.key_vault.id
  key_vault_name = module.key_vault.name

  app_service_id   = module.app_service_api.id
  app_service_name = module.app_service_api.name

  rotation_interval_days = var.azure_rotation_interval_days
  rotation_start_time    = var.azure_rotation_start_time

  tags = local.common_tags
}

module "flow_logs" {
  source = "../../modules/azure/flow-logs"

  resource_group_name = module.resource_group.name
  location            = var.location
  name_prefix         = "arkcloud-${var.environment}"

  vnet_id = module.network.vnet_id

  # Off by default — see modules/azure/flow-logs' enable_traffic_analytics description for the
  # cost tradeoff. Flip azure_enable_traffic_analytics to true once there's an actual reason to
  # query this data rather than just retain it for incident forensics.
  enable_traffic_analytics            = var.azure_enable_traffic_analytics
  log_analytics_workspace_guid        = module.monitoring.log_analytics_workspace_guid
  log_analytics_workspace_resource_id = module.monitoring.log_analytics_workspace_id

  tags = local.common_tags
}

resource "azurerm_monitor_diagnostic_setting" "app_service_web" {
  name                       = "diag-app-arkcloud-web-${var.environment}"
  target_resource_id         = module.app_service_web.id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  # Même correctif que app_service_api ci-dessus — voir ce commentaire pour le pourquoi.
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }

  # Même dérive perpétuelle que app_service_api — voir le commentaire détaillé là-haut.
  lifecycle {
    ignore_changes = [log_analytics_destination_type]
  }
}

# ---------------------------------------------------------------------------
# Détection de menaces — GuardDuty (AWS) + Defender for Cloud (Azure). Même politique de
# sécurité sur les deux clouds, mécanismes distincts (voir README.md §10 pour la comparaison
# complète et le raisonnement coût derrière ce qui est activé vs laissé optionnel).
# ---------------------------------------------------------------------------

module "aws_guardduty" {
  source = "../../modules/aws/guardduty"

  name_prefix = "arkcloud-${var.environment}"

  # Réutilise le topic d'alertes existant plutôt qu'un second canal — un finding GuardDuty
  # atterrit dans la même boîte mail que les alarmes CloudWatch et les échecs de rotation.
  alarm_sns_topic_arn = module.aws_monitoring.sns_topic_arn

  tags = local.common_tags
}

# Politique du topic SNS d'alertes — UN SEUL propriétaire pour cette resource policy, ici, au
# niveau racine. EventBridge (GuardDuty) est aujourd'hui le seul consommateur externe à ce topic
# qui a besoin d'une permission explicite (les CloudWatch Alarms de modules/aws/monitoring et
# modules/aws/secret-rotation n'en ont pas besoin, comportement historique AWS pour les services
# same-account). Si un futur module a besoin de publier ici aussi, AJOUTER un statement à ce même
# document plutôt que déclarer un second aws_sns_topic_policy sur le même topic ailleurs — deux
# ressources Terraform propriétaires d'un même attribut de politique se contrediraient à chaque
# plan, exactement le bug de security group flip-flop déjà rencontré et corrigé ce sprint
# (voir modules/aws/security/main.tf).
data "aws_iam_policy_document" "alerts_sns_topic" {
  statement {
    sid    = "AllowEventBridgeGuardDutyFindings"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [module.aws_monitoring.sns_topic_arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [module.aws_guardduty.event_rule_arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = module.aws_monitoring.sns_topic_arn
  policy = data.aws_iam_policy_document.alerts_sns_topic.json
}

module "azure_defender" {
  source = "../../modules/azure/defender"

  resource_group_name = module.resource_group.name
  location            = var.location
  name_prefix         = "arkcloud-${var.environment}"

  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  alert_email = var.azure_defender_alert_email
  alert_phone = var.azure_defender_alert_phone

  enable_defender_app_service = var.azure_enable_defender_app_service
  enable_defender_databases   = var.azure_enable_defender_databases

  tags = local.common_tags
}
