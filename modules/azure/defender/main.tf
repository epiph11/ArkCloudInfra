# Microsoft Defender for Cloud — équivalent Azure de GuardDuty côté AWS (modules/aws/guardduty).
#
# Différence structurelle à ne pas oublier : azurerm_security_center_subscription_pricing est
# scopé à TOUTE la subscription, pas au resource group rg-arkcloud-${var.environment} comme le
# reste de ce projet. Il n'existe pas de "Defender par resource group" côté Azure — la pricing
# tier est un réglage par type de ressource, à l'échelle de la subscription entière. Si cette
# subscription héberge un jour autre chose qu'ArkCloud, activer un plan payant ici facture aussi
# cette autre charge de travail. Sans conséquence tant que la subscription reste dédiée à ce
# projet (cas actuel), mais c'est un vrai changement de portée par rapport à tout le reste de
# l'infra — documenté ici pour qu'il ne soit jamais découvert par surprise sur une facture.

data "azurerm_client_config" "current" {}

# Key Vault : le seul plan activé par défaut. Facturé à la transaction (~0,02 $/10k
# transactions/mois d'après la doc de pricing Azure) — négligeable au volume de trafic actuel
# de kv-arkcloud-dev — et c'est le pendant Azure le plus direct du signal que donne GuardDuty
# côté IAM/credentials AWS : détection d'accès anormal aux secrets (énumération, IP inhabituelle,
# usage depuis une géographie suspecte), pas juste "qui a lu quoi" comme le fait déjà le
# diagnostic setting AuditEvent existant (environments/dev/main.tf).
resource "azurerm_security_center_subscription_pricing" "key_vault" {
  tier          = "Standard"
  resource_type = "KeyVaults"

  # Fixé explicitement après un forced-replace observé au premier apply réel : sans cet
  # attribut, Azure applique lui-même "PerKeyVault" côté serveur (confirmé par la sortie de
  # `terraform apply`), et Terraform voit ensuite un écart entre son null initial et cette
  # valeur imposée — un replace à chaque plan, même classe de dérive perpétuelle que le
  # security group et le diagnostic setting plus haut dans ce sprint. "PerKeyVault" est le plan
  # tarifaire au coffre (pas à la transaction comme l'ancien "PerTransaction") — celui
  # qu'Azure attribue par défaut aux nouvelles activations.
  subplan = "PerKeyVault"
}

# Désactivés par défaut — voir variables.tf pour le raisonnement coût détaillé (chacun dépasserait
# à lui seul le plafond cost-guard de 7 €/mois).
resource "azurerm_security_center_subscription_pricing" "app_service" {
  count = var.enable_defender_app_service ? 1 : 0

  tier          = "Standard"
  resource_type = "AppServices"
}

resource "azurerm_security_center_subscription_pricing" "databases" {
  count = var.enable_defender_databases ? 1 : 0

  tier          = "Standard"
  resource_type = "OpenSourceRelationalDatabases"
}

# Notification directe par email — le pendant Azure de l'abonnement email sur le topic SNS
# d'alertes (modules/aws/monitoring). Contrairement à GuardDuty/EventBridge, Defender a son
# propre mécanisme de contact natif : pas besoin de reconstruire un routage équivalent pour ce
# canal-là.
resource "azurerm_security_center_contact" "this" {
  count = var.alert_email != null ? 1 : 0

  name  = "arkcloud-defender-contact-${var.name_prefix}"
  email = var.alert_email
  phone = var.alert_phone

  alert_notifications = true
  alerts_to_admins    = true
}

# Export continu — pendant Azure de la règle EventBridge->SNS de GuardDuty : sans ça, une alerte
# Defender ne vit que dans le portail Azure (+ l'email ci-dessus). L'exporter vers le même
# workspace Log Analytics que l'App Insights et les diagnostic settings existants
# (modules/azure/monitoring) la rend interrogeable via le même KQL que tout le reste de
# l'observabilité de ce projet, au lieu de rester dans un silo Defender séparé.
resource "azurerm_security_center_automation" "export_to_log_analytics" {
  name                = "arkcloud-defender-export-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name

  enabled = true

  # "Workspace", pas "LogAnalytics" — confirmé par l'erreur de validation du provider à la
  # première tentative : les valeurs acceptées sont EventHub/LogicApp/Workspace (PascalCase) ou
  # eventhub/logicapp/loganalytics (minuscules), pas de casse mixte "LogAnalytics". Les exemples
  # trouvés en ligne utilisaient tous "loganalytics"/"LogAnalytics" selon la version du provider
  # au moment où ils ont été écrits — la version actuelle (4.81.0, voir .terraform/) a renommé
  # l'option PascalCase en "Workspace".
  action {
    type        = "Workspace"
    resource_id = var.log_analytics_workspace_id
  }

  # Trois rule_set plutôt qu'un severity >= X unique : la ressource ne supporte qu'un opérateur
  # "Equals" par règle, pas de comparaison numérique >= comme le permet EventBridge côté AWS —
  # donc High/Medium/Low sont énumérés explicitement plutôt que filtrés par un seuil.
  # Volontairement pas de filtre par sévérité minimale ici (contrairement à GuardDuty côté AWS,
  # limité aux findings >= Medium) : le volume Defender pour ce projet est faible (un seul Key
  # Vault protégé), donc pas le même risque de saturer le workspace que sur AWS avec un détecteur
  # qui analyse tout le trafic réseau/CloudTrail.
  source {
    event_source = "Alerts"

    rule_set {
      rule {
        property_path  = "Severity"
        operator       = "Equals"
        expected_value = "High"
        property_type  = "String"
      }
    }

    rule_set {
      rule {
        property_path  = "Severity"
        operator       = "Equals"
        expected_value = "Medium"
        property_type  = "String"
      }
    }

    rule_set {
      rule {
        property_path  = "Severity"
        operator       = "Equals"
        expected_value = "Low"
        property_type  = "String"
      }
    }
  }

  scopes = ["/subscriptions/${data.azurerm_client_config.current.subscription_id}"]

  tags = var.tags
}
