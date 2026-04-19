resource "random_password" "flask_secret_key" {
  length  = 64
  special = false
}

resource "random_string" "key_vault_suffix" {
  length  = 5
  lower   = true
  numeric = true
  special = false
  upper   = false
}
