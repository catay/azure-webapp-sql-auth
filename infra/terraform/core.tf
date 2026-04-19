resource "azurerm_resource_group" "main" {
  name     = var.rg
  location = var.location
  tags     = local.tags
}

resource "azurerm_service_plan" "main" {
  name                = var.app_plan
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = var.app_plan_sku
  tags                = local.tags
}
