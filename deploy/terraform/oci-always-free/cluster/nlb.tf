# The only public entry point. A network load balancer in passthrough mode: TLS terminates on the broker, not
# here, so the client certificate's SAN is the load balancer's own public address.
resource "oci_network_load_balancer_network_load_balancer" "client" {
  compartment_id = var.compartment_id
  display_name   = "malachi-client"
  subnet_id      = oci_core_subnet.nodes.id
  is_private     = false
}

resource "oci_network_load_balancer_backend_set" "client" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.client.id
  name                     = "malachi-client-tcp"
  policy                   = "FIVE_TUPLE"

  # The health check is the readiness gate: /ready on the dashboard port answers 200 only once the broker has
  # read every metadata vnode (Malachi.Dashboard). A node that is not ready gets no client traffic, and the
  # orchestrator reads the same answer from the load balancer's backend health, so it never needs to enter
  # the VCN. Probes come from the subnet, which the 4041 rule already allows.
  health_checker {
    protocol    = "HTTP"
    port        = 4041
    url_path    = "/ready"
    return_code = 200
  }
}

# Backends: the two A1 nodes only. The micro is the third voter, not a client entry point (see README).
resource "oci_network_load_balancer_backend" "client" {
  for_each = { for name, n in local.nodes : name => n if n.in_lb }

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.client.id
  backend_set_name         = oci_network_load_balancer_backend_set.client.name
  ip_address               = oci_core_instance.node[each.key].private_ip
  port                     = 4040
}

resource "oci_network_load_balancer_listener" "client" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.client.id
  name                     = "malachi-client"
  default_backend_set_name = oci_network_load_balancer_backend_set.client.name
  port                     = 4040
  protocol                 = "TCP"
}
