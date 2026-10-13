environment          = "dev"
resource_name_suffix = "tnt"

container_min_replicas = 0
container_max_replicas = 1

# East US 2 has no Postgres capacity for this subscription. Central US is its paired region;
# North Central US is the fallback.
workload_location = "centralus"
database_enabled  = true

key_vault_purge_protection = false
hf_token_enabled           = false
