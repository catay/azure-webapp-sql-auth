resource "random_password" "flask_secret_key" {
  length  = 64
  special = false
}

resource "random_id" "stack" {
  byte_length = 3
}
