variable "environment" {
  description = "dev or prod. The resource group rg-athena-<environment> must already exist (techntoast-platform creates it)."
  type        = string
}

variable "resource_name_suffix" {
  description = "Appended to globally unique names (registry, Key Vault, Postgres)."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Shared workspace for this environment, from techntoast-platform (GitHub variable LOG_WORKSPACE_ID)."
  type        = string
}

variable "operators_group_id" {
  description = "Entra group that administers the database alongside the migrate identity (GitHub variable OPERATORS_GROUP_ID)."
  type        = string
}

variable "operators_group_name" {
  type    = string
  default = "TNT Prod Operators"
}

variable "container_image" {
  description = "First-deploy placeholder only. The deploy workflow sets the real image; Terraform ignores later changes."
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "container_cpu" {
  type    = number
  default = 0.25
}

variable "container_memory" {
  type    = string
  default = "0.5Gi"
}

variable "container_min_replicas" {
  description = "0 scales to zero when idle (a few seconds of cold start)."
  type        = number
  default     = 0
}

variable "container_max_replicas" {
  type    = number
  default = 2
}

variable "ingest_schedule" {
  description = "Cron (UTC) for the athlete data ingest job."
  type        = string
  default     = "0 5 * * *"
}

variable "postgres_sku_name" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  type    = number
  default = 32768
}

variable "key_vault_purge_protection" {
  description = "On for prod. Off in dev so a rebuilt vault doesn't lock its name for 90 days."
  type        = bool
  default     = true
}

variable "hf_token_enabled" {
  description = "Turn on after adding the hf-token secret to Key Vault. Without it the API uses its rules fallback."
  type        = bool
  default     = false
}
