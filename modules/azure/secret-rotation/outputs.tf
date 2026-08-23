output "automation_account_name" {
  value = azurerm_automation_account.rotation.name
}

output "runbook_name" {
  description = "Useful for triggering a rotation on demand rather than waiting for the schedule: az automation runbook start --automation-account-name <account> --resource-group <rg> --name <this>"
  value       = azurerm_automation_runbook.rotate_postgres_password.name
}

output "schedule_name" {
  value = azurerm_automation_schedule.rotation.name
}
