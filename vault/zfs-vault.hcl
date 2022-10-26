
# Allows creation and reading of secrets from Vault.
path "datasets/*" {
  capabilities = [ "read", "create", "list" ]
}

# Allows updates to descriptive metadata about each created secret
path "datasets/metadata/*" {
  capabilities = [ "read", "update", "create" ]
}

