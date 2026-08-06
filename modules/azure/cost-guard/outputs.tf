output "automation_account_name" {
  value = azurerm_automation_account.cost_guard.name
}

output "runbook_name" {
  value = azurerm_automation_runbook.stop_postgres.name
}

output "action_group_id" {
  value = azurerm_monitor_action_group.cost_guard.id
}

output "budget_name" {
  value = azurerm_consumption_budget_resource_group.monthly.name
}
