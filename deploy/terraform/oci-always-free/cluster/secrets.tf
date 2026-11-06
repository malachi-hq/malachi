# Everything secret is generated at apply and lives in the Resource Manager state, which is inside OCI and
# is destroyed with the cluster. Nothing here is a literal, and no default password or cookie exists anywhere.
resource "random_password" "cookie" {
  length  = 48
  special = false
}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "random_password" "producer" {
  length  = 24
  special = false
}

resource "random_password" "consumer" {
  length  = 24
  special = false
}

resource "random_password" "app" {
  length  = 24
  special = false
}

# One CA for the day. Its key exists only in state; each node gets the key for its own certificate only.
resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 72
  allowed_uses          = ["cert_signing", "crl_signing"]

  subject {
    common_name  = "Malachi ephemeral distribution CA"
    organization = "Malachi"
  }
}

# Per-node distribution certificate: its SAN is the node's own FQDN, the name the other nodes dial.
resource "tls_private_key" "node" {
  for_each = local.nodes

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "node" {
  for_each = local.nodes

  private_key_pem = tls_private_key.node[each.key].private_key_pem
  dns_names       = [local.node_fqdns[each.key]]

  subject {
    common_name  = local.node_fqdns[each.key]
    organization = "Malachi"
  }
}

resource "tls_locally_signed_cert" "node" {
  for_each = local.nodes

  cert_request_pem      = tls_cert_request.node[each.key].cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 72
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth", "client_auth"]
}

# Client-facing certificate, presented on port 4040. Its SAN is the load balancer's public address, which
# exists before any instance does, so there is no cycle between the certificate and the nodes.
resource "tls_private_key" "client" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "client" {
  private_key_pem = tls_private_key.client.private_key_pem
  ip_addresses    = [oci_network_load_balancer_network_load_balancer.client.ip_addresses[0].ip_address]

  subject {
    common_name  = "malachi-client"
    organization = "Malachi"
  }
}

resource "tls_locally_signed_cert" "client" {
  cert_request_pem      = tls_cert_request.client.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 72
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}
