# Terraform Infrastructure

Athena's Azure resources. The resource group, log workspace, deploy identity, budgets, and access
groups come from [`TechNToast/techntoast-platform`](https://github.com/TechNToast/techntoast-platform);
this stack deploys into `rg-athena-<env>`.

## Resources

| Resource | Notes |
|----------|-------|
| Managed identities `id-athena-<env>-api`, `-migrate` | All service sign-in; no passwords or shared keys |
| Container Registry | Admin user off; pulls by managed identity |
| Container Apps environment + API | Scales to zero in dev; logs to the shared workspace |
| Job `caj-athena-<env>-migrate` | `alembic upgrade head`, then grants the API its database role |
| Job `caj-athena-<env>-ingest` | Athlete data upsert on a schedule (start by hand to seed) |
| PostgreSQL Flexible Server 16 | Entra sign-in only; admins are the migrate identity and the operators group |
| Key Vault | RBAC; holds `hf-token` |
| Application Insights | Workspace-based, Entra auth only |
| Service Bus (Basic) + `notifications` queue | Local auth off |

## Deploy

Infrastructure: **Actions → Terraform Apply → dev**. Pull requests that touch this folder get a
plan comment.

Code: pushing `backend/**` to `main` runs **Backend Deploy (Dev)**, which builds an image tagged with
the commit, runs the migrate job with it, then switches the API and ingest job to it.

Terraform ignores image changes after creation; the deploy workflow owns which image runs.

## Run locally

```bash
export AZURE_CONFIG_DIR=~/.azure-techntoast   # Tech & Toast tenant
az login --tenant <tenant-id>
export ARM_SUBSCRIPTION_ID=<subscription-id>
export TF_VAR_log_analytics_workspace_id=<LOG_WORKSPACE_ID variable>
export TF_VAR_operators_group_id=<OPERATORS_GROUP_ID variable>

terraform init \
  -backend-config="resource_group_name=<TF_STATE_RESOURCE_GROUP>" \
  -backend-config="storage_account_name=<TF_STATE_STORAGE_ACCOUNT>" \
  -backend-config="key=dev.tfstate"
terraform plan -var-file=envs/dev/dev.tfvars
```

## Hugging Face token

The API works without it (rules fallback). To turn on model insights:

```bash
az keyvault secret set --vault-name kv-athena-dev-tnt --name hf-token --value "<token>"
```

Then set `hf_token_enabled = true` in `envs/dev/dev.tfvars` and run Terraform Apply.

## Database access for you

You're an administrator through the operators group. Connect with a token instead of a password:

```bash
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)
psql "host=psql-athena-dev-tnt.postgres.database.azure.com dbname=athena user='TNT Prod Operators' sslmode=require"
```

The server only accepts Azure-internal connections; add a temporary firewall rule for your IP and
remove it afterwards.

## Regions

The resource group, registry, Key Vault, Service Bus, and logs live in the resource group's region.
`workload_location` places Postgres and the Container Apps somewhere else when that region can't host
Postgres; they move together so queries never cross regions. Changing it recreates the container
environment (the API URL changes) and the database (data is lost unless you dump and restore first).

## Running without the database

`database_enabled = false` skips Postgres and both jobs; the API starts in stub mode. To connect it,
set `database_enabled = true`, run Terraform Apply, then run Backend Deploy (migrations) and start the
ingest job once to seed.

## Limitations

- Public endpoints (Entra-gated) for Postgres, Key Vault, registry, and Service Bus. Private networking
  needs a VNet and costs more; revisit before production.
- The API URL includes the region. Put a custom domain in front before any app depends on it.
- No prod environment yet. Add `envs/prod/prod.tfvars` and the `prod` option in the apply workflow;
  the platform already requires approval for the `prod` GitHub environment.
