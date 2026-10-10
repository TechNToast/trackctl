terraform {
  required_version = ">= 1.9"

  # resource_group_name, storage_account_name, and key come from -backend-config at init
  # (GitHub variables TF_STATE_RESOURCE_GROUP / TF_STATE_STORAGE_ACCOUNT; key = <env>.tfstate).
  backend "azurerm" {
    container_name   = "athena"
    use_azuread_auth = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  # The platform repo registers providers; this deploy identity only has rights in its resource group.
  resource_provider_registrations = "none"
  storage_use_azuread             = true
}
