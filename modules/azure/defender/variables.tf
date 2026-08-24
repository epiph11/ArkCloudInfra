variable "resource_group_name" {
  description = "Uniquement pour azurerm_security_center_automation, qui a besoin d'un groupe de ressources hôte comme n'importe quelle autre ressource Azure — ce n'est PAS le scope de ce qu'il exporte (voir main.tf : scopes vise toute la subscription, pas ce resource group)."
  type        = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "log_analytics_workspace_id" {
  description = "modules/azure/monitoring.log_analytics_workspace_id — même workspace que l'App Insights et les diagnostic settings existants, pour que les alertes Defender soient interrogeables via le même KQL plutôt que dans un silo séparé."
  type        = string
}

variable "alert_email" {
  description = "Optionnel — reçoit les notifications d'alerte Defender (azurerm_security_center_contact). Laissé non défini par défaut pour ne pas apparaître dans le contrôle de version ; à définir via TF_VAR_azure_defender_alert_email ou terraform.tfvars."
  type        = string
  default     = null
}

variable "enable_defender_app_service" {
  description = "Défaut false — délibéré, pas un oubli. Defender for App Service coûte environ 14,60 $/instance/mois (vérifié sur la page de pricing Azure) ; avec les deux App Services de ce projet (API + Web), ça représente ~29 $/mois, soit environ 4x le plafond de 7 €/mois déjà fixé pour tout le resource group par modules/azure/cost-guard. Disproportionné pour un environnement dev. À activer pour staging/prod, où un vrai SLA de sécurité applicative se justifie. Pour tester sans payer le tarif plein : Azure offre 30 jours gratuits dès l'activation d'un plan payant (vérifié sur la page de pricing officielle) — activer, vérifier dans le portail (Defender for Cloud > Environment settings), repasser à false avant l'échéance ou dans la même journée pour rester dans la fenêtre gratuite."
  type        = bool
  default     = false
}

variable "enable_defender_databases" {
  description = "Défaut false — même arbitrage budgétaire que enable_defender_app_service. Microsoft Defender for Databases (plan OpenSourceRelationalDatabases, couvre PostgreSQL Flexible Server) est du même ordre de grandeur tarifaire que Defender for Servers (~15 $/ressource/mois d'après la documentation Microsoft), non confirmé au $ près faute de page de pricing publique détaillée par ressource — traité comme suffisamment coûteux pour rester optionnel en dev plutôt que supposé gratuit. Même astuce des 30 jours gratuits que enable_defender_app_service pour tester sans coût."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
