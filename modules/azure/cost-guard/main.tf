# ---------------------------------------------------------------------------
# Cost guard — Azure only for now (AWS side needs Cost Explorer enabled first
# and real numbers gathered before the same pattern is worth building there —
# see docs/infra-roadmap.md, Journal des décisions).
#
# At €budget_amount_eur/month actual spend on rg-arkcloud-${env}, this stops
# the PostgreSQL Flexible Server automatically — it does NOT "switch App
# Service to a cheaper tier". Confirmed live before building this: Free (F1)
# and Shared (D1) don't support Regional VNet Integration, and the API app is
# on that integration to reach Postgres privately (`az appservice plan update
# --sku F1` fails with "does not support Regional VNET integration" while
# still attached). Basic B1 is already the cheapest tier that keeps the app
# functional, so there is no graceful "cheaper tier" to fall back to on the
# App Service side. Stopping Postgres is the one lever that cuts real,
# ongoing compute cost without touching network/security config — the
# tradeoff is that the app becomes fully unavailable while stopped, not a
# degraded-but-working mode.
#
# Also worth knowing before relying on this: Azure Cost Management's actual-
# cost data is not real-time (multi-hour lag documented by Microsoft), so the
# stop can fire well after €budget_amount_eur was technically already
# crossed, and a bit of extra spend can accrue in the meantime.
# ---------------------------------------------------------------------------

resource "azurerm_automation_account" "cost_guard" {
  name                = "aa-${var.name_prefix}-cost-guard"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# Audit IAM (Sprint 6) : "Contributor" scopé au serveur précis limitait déjà le *rayon d'action*
# (mirrors the AWS IAM least-privilege pattern used elsewhere), mais pas les *actions permises*
# sur cette ressource — le runbook ci-dessous ne fait jamais qu'un Stop-AzPostgresFlexibleServer,
# alors que "Contributor" autorise aussi resize, suppression, changement réseau, etc. Remplacé
# par un rôle personnalisé limité à lire l'état + l'arrêter — vérifié contre la liste officielle
# des opérations RBAC (learn.microsoft.com/.../permissions/databases) avant d'écrire l'action.
# Volontairement PAS de "start/action" ici : ce runbook n'existe que pour couper les coûts,
# jamais pour redémarrer — le message affiché en fin de script pointe vers `az postgres
# flexible-server start` exécuté par un humain avec ses propres identifiants, pas par cette
# identité automatisée. Ajouter start reviendrait à donner à ce compte un pouvoir qu'il n'exerce
# jamais dans le code.
resource "azurerm_role_definition" "postgres_stop" {
  name        = "arkcloud-${var.name_prefix}-postgres-stop"
  scope       = var.resource_group_id
  description = "Lecture + arrêt/démarrage d'un serveur PostgreSQL Flexible Server — rien d'autre."

  # Sprint 6 clôture (12/09) — "start/action" ajouté : le runbook budget-triggered ci-dessous
  # reste volontairement stop-only (voir son commentaire), mais l'arrêt PROGRAMMÉ nuit/weekend
  # plus bas (azurerm_automation_runbook.start_postgres) a besoin de redémarrer le serveur —
  # sans ça, un dev arrêté une nuit resterait arrêté indéfiniment, personne d'autre que ce
  # compte automatisé n'ayant de raison de le relancer un lundi matin à 7h.
  permissions {
    actions = [
      "Microsoft.DBforPostgreSQL/flexibleServers/read",
      "Microsoft.DBforPostgreSQL/flexibleServers/stop/action",
      "Microsoft.DBforPostgreSQL/flexibleServers/start/action",
    ]
    not_actions = []
  }

  assignable_scopes = [var.resource_group_id]
}

resource "azurerm_role_assignment" "cost_guard_stop_postgres" {
  scope              = var.postgres_server_id
  role_definition_id = azurerm_role_definition.postgres_stop.role_definition_resource_id
  principal_id       = azurerm_automation_account.cost_guard.identity[0].principal_id
}

resource "azurerm_automation_runbook" "stop_postgres" {
  name                    = "Stop-ArkCloudPostgres"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_guard.name
  runbook_type            = "PowerShell"
  log_progress            = true
  log_verbose             = true

  content = <<-EOT
    # Triggered by the €${var.budget_amount_eur}/month Azure Budget action group once actual
    # spend on ${var.resource_group_name} reaches 100% of the budget. Uses the Automation
    # Account's system-assigned managed identity (Connect-AzAccount -Identity) — no stored
    # credential.
    param()

    Connect-AzAccount -Identity | Out-Null

    Write-Output "Budget threshold reached (EUR ${var.budget_amount_eur}/month on ${var.resource_group_name}) - stopping PostgreSQL Flexible Server '${var.postgres_server_name}' to stop further compute charges."

    Stop-AzPostgresFlexibleServer -ResourceGroupName "${var.resource_group_name}" -Name "${var.postgres_server_name}"

    Write-Output "Stop requested. The app has no DB connection until restarted manually: az postgres flexible-server start --name ${var.postgres_server_name} --resource-group ${var.resource_group_name}"
  EOT

  tags = var.tags
}

# Azure requires an expiry on every Automation webhook (no "never expires" option) — set 1 year
# out and pinned via ignore_changes so `terraform apply` doesn't show a diff every run just
# because timestamp() moved; once it actually lapses, remove the ignore_changes for one apply to
# roll a fresh expiry, then put it back.
resource "azurerm_automation_webhook" "stop_postgres" {
  name                    = "webhook-${var.name_prefix}-cost-guard"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_guard.name
  runbook_name            = azurerm_automation_runbook.stop_postgres.name
  expiry_time             = timeadd(timestamp(), "8760h")
  enabled                 = true

  lifecycle {
    ignore_changes = [expiry_time]
  }
}

# ---------------------------------------------------------------------------
# Arrêt/redémarrage PROGRAMMÉ (Sprint 6 clôture, 12/09) — distinct du garde-fou budgétaire
# au-dessus (déclenché à 100% de dépense réelle, avec le lag documenté de plusieurs heures
# d'Azure Cost Management). Ici : Postgres coûte tant qu'il tourne, que le budget soit dépassé
# ou non — cet environnement est un dev/build sans utilisateur réel, donc l'arrêter la nuit et
# le weekend (quand personne ne teste) réduit le coût réel sans attendre qu'un seuil soit franchi.
# var.enable_scheduled_stop=false par défaut : staging/prod (futurs sprints) ne voudront
# probablement pas de ce comportement.
# ---------------------------------------------------------------------------

resource "azurerm_automation_runbook" "start_postgres" {
  count = var.enable_scheduled_stop ? 1 : 0

  name                    = "Start-ArkCloudPostgres"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_guard.name
  runbook_type            = "PowerShell"
  log_progress            = true
  log_verbose             = true

  content = <<-EOT
    param()
    Connect-AzAccount -Identity | Out-Null
    Write-Output "Démarrage programmé de PostgreSQL Flexible Server '${var.postgres_server_name}'."
    Start-AzPostgresFlexibleServer -ResourceGroupName "${var.resource_group_name}" -Name "${var.postgres_server_name}"
  EOT

  tags = var.tags
}

# Le runbook Stop-ArkCloudPostgres existant (au-dessus) sert déjà à l'arrêt — réutilisé ici via
# un déclencheur planifié en plus de son déclencheur budgétaire existant (azurerm_monitor_action_group
# plus bas). Un seul runbook, deux déclencheurs (budget OU planning), pas de duplication.

resource "azurerm_automation_schedule" "stop_nightly" {
  count = var.enable_scheduled_stop ? 1 : 0

  name                    = "schedule-${var.name_prefix}-postgres-stop-nightly"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_guard.name
  frequency                = "Day"
  interval                 = 1
  # Premier déclenchement le lendemain à l'heure indiquée — Azure exige un start_time futur.
  start_time                = var.scheduled_stop_time
  timezone                  = "Europe/Paris"
  description               = "Arrêt quotidien hors horaires de travail (dev/build, zéro utilisateur réel)."
}

resource "azurerm_automation_schedule" "start_weekday_morning" {
  count = var.enable_scheduled_stop ? 1 : 0

  name                    = "schedule-${var.name_prefix}-postgres-start-morning"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_guard.name
  frequency                = "Week"
  interval                 = 1
  # Lundi-vendredi uniquement — pas de redémarrage automatique le weekend, cohérent avec
  # "personne ne teste le weekend". Un redémarrage manuel (`az postgres flexible-server start`)
  # reste possible si besoin ponctuel un samedi.
  week_days                 = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
  start_time                = var.scheduled_start_time
  timezone                  = "Europe/Paris"
  description               = "Redémarrage quotidien (jours ouvrés) avant les horaires de travail."
}

resource "azurerm_automation_job_schedule" "stop_nightly" {
  count = var.enable_scheduled_stop ? 1 : 0

  resource_group_name    = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_guard.name
  schedule_name            = azurerm_automation_schedule.stop_nightly[0].name
  runbook_name              = azurerm_automation_runbook.stop_postgres.name
}

resource "azurerm_automation_job_schedule" "start_weekday_morning" {
  count = var.enable_scheduled_stop ? 1 : 0

  resource_group_name    = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_guard.name
  schedule_name            = azurerm_automation_schedule.start_weekday_morning[0].name
  runbook_name              = azurerm_automation_runbook.start_postgres[0].name
}

resource "azurerm_monitor_action_group" "cost_guard" {
  name                = "ag-${var.name_prefix}-cost-guard"
  resource_group_name = var.resource_group_name
  short_name          = "costguard"

  dynamic "email_receiver" {
    for_each = var.alert_email != null ? [var.alert_email] : []
    content {
      name          = "cost-guard-email"
      email_address = email_receiver.value
    }
  }

  automation_runbook_receiver {
    name                    = "stop-postgres"
    automation_account_id   = azurerm_automation_account.cost_guard.id
    runbook_name            = azurerm_automation_runbook.stop_postgres.name
    webhook_resource_id     = azurerm_automation_webhook.stop_postgres.id
    is_global_runbook       = false
    service_uri             = azurerm_automation_webhook.stop_postgres.uri
    use_common_alert_schema = true
  }

  tags = var.tags
}

# Early-warning only, no automation — a chance to intervene by hand before the 100% threshold
# triggers the automatic stop above. Only created if an email was actually provided.
resource "azurerm_monitor_action_group" "cost_guard_warning" {
  count = var.alert_email != null ? 1 : 0

  name                = "ag-${var.name_prefix}-cost-guard-warning"
  resource_group_name = var.resource_group_name
  short_name          = "costwarn"

  email_receiver {
    name          = "cost-guard-warning-email"
    email_address = var.alert_email
  }

  tags = var.tags
}

# Scoped to the resource group (rg-arkcloud-${env}), not the subscription — rg-terraform-state's
# near-zero cost shouldn't count toward this threshold, and a subscription-wide budget would also
# catch any other unrelated resource created later in the same subscription.
resource "azurerm_consumption_budget_resource_group" "monthly" {
  name              = "budget-${var.name_prefix}"
  resource_group_id = var.resource_group_id

  amount     = var.budget_amount_eur
  time_grain = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"

    contact_groups = [azurerm_monitor_action_group.cost_guard.id]
  }

  dynamic "notification" {
    for_each = var.alert_email != null ? [1] : []
    content {
      enabled        = true
      threshold      = 80
      operator       = "GreaterThanOrEqualTo"
      threshold_type = "Actual"

      contact_groups = [azurerm_monitor_action_group.cost_guard_warning[0].id]
    }
  }
}
