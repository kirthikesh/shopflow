# ---- Phase 7: secrets in Key Vault, Azure Policy in the cluster -------------
#
# Each app environment (dev, prod) gets a managed identity that its pods use
# through Workload Identity: the "shopflow" service account in shopflow-<env>
# is federated with it, and it can read secrets in this vault and nothing
# else. The Secrets Store CSI driver syncs the secrets into the namespace, so
# the pipeline no longer creates them (gitops: secrets.provider = keyvault).

locals {
  app_envs_with_cluster = var.aks_enabled ? toset(var.app_environments) : toset([])
}

resource "azurerm_user_assigned_identity" "app" {
  for_each = local.app_envs_with_cluster

  name                = "id-${local.name_prefix}-app-${each.key}"
  location            = local.location
  resource_group_name = azurerm_resource_group.env.name
  tags                = merge(local.tags, { app_env = each.key })
}

resource "azurerm_federated_identity_credential" "app" {
  for_each = local.app_envs_with_cluster

  name                      = "shopflow-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.app[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks[0].oidc_issuer_url
  subject                   = "system:serviceaccount:shopflow-${each.key}:shopflow"
}

resource "azurerm_role_assignment" "app_secrets" {
  for_each = local.app_envs_with_cluster

  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app[each.key].principal_id
}

resource "random_password" "postgres" {
  for_each = local.app_envs_with_cluster

  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "postgres_password" {
  for_each = local.app_envs_with_cluster

  name         = "${each.key}-postgres-password"
  value        = random_password.postgres[each.key].result
  key_vault_id = module.key_vault.id
  content_type = "password"
  tags         = merge(local.tags, { app_env = each.key })
}

resource "azurerm_key_vault_secret" "servicebus" {
  for_each = local.app_envs_with_cluster

  name         = "${each.key}-servicebus-connection-string"
  value        = module.service_bus[each.key].app_connection_string
  key_vault_id = module.key_vault.id
  content_type = "connection-string"
  tags         = merge(local.tags, { app_env = each.key })
}

# Azure Policy audits the cluster against the Kubernetes "baseline" pod
# security standard. Kyverno enforces our own rules at admission; this is the
# independent, Azure-side view that shows up in Defender and the compliance
# dashboard.
data "azurerm_policy_set_definition" "k8s_baseline" {
  display_name = "Kubernetes cluster pod security baseline standards for Linux-based workloads"
}

resource "azurerm_resource_policy_assignment" "k8s_baseline" {
  count = var.aks_enabled ? 1 : 0

  name                 = "shopflow-k8s-baseline"
  display_name         = "ShopFlow: Kubernetes pod security baseline (audit)"
  resource_id          = module.aks[0].id
  policy_definition_id = data.azurerm_policy_set_definition.k8s_baseline.id
  parameters = jsonencode({
    effect = { value = "audit" }
  })
}
