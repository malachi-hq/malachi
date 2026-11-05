output "client_endpoint" {
  description = "Public address of the client port (TLS)."
  value       = "${oci_network_load_balancer_network_load_balancer.client.ip_addresses[0].ip_address}:4040"
}

output "node_fqdns" {
  description = "Internal FQDN of every node, the names used by RELEASE_NODE and MALACHI_LOG_NODES."
  value       = local.node_fqdns
}

output "ca_cert_pem" {
  description = "CA certificate for --cacert on the smoke client. Public by design: it is not a key."
  value       = tls_self_signed_cert.ca.cert_pem
}
