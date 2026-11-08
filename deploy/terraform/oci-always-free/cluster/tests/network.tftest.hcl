# The network invariants of the cluster: only the client port faces the internet, the distribution, epmd and
# dashboard ports stay inside the VCN, and SSH is never open. A rule is checked by the port RANGE it opens, not by
# its first port, and by every rule, not only the ones with one particular source. Plan-only, mocked providers.

variables {
  region              = "replace-me-home-region"
  compartment_id      = "ocid1.compartment.oc1..testcluster"
  availability_domain = "replace-me-ad"
  image_tag           = "0.22.7"
}

mock_provider "oci" {
  mock_data "oci_core_images" {
    defaults = {
      images = [{ id = "ocid1.image.oc1..mockimage" }]
    }
  }
}

mock_provider "random" {}
mock_provider "tls" {}

run "only_the_client_port_4040_is_reachable_from_the_internet" {
  command = plan

  # Every rule whose source is not the VCN must open exactly port 4040, whatever its source CIDR is.
  assert {
    condition = alltrue([
      for r in oci_core_security_list.cluster.ingress_security_rules :
      r.source == "10.0.0.0/16" || (length(r.tcp_options) == 1 && r.tcp_options[0].min == 4040 && r.tcp_options[0].max == 4040)
    ])
    error_message = "A rule from outside the VCN opens something other than the client port 4040."
  }
}

run "epmd_the_distribution_port_and_the_dashboard_stay_inside_the_vcn" {
  command = plan

  # A rule covers a port when it has no port block (all ports) or when the port falls inside its range.
  assert {
    condition = alltrue([
      for p in [4369, 9100, 4041] :
      alltrue([
        for r in oci_core_security_list.cluster.ingress_security_rules :
        !(length(r.tcp_options) == 0 || (r.tcp_options[0].min <= p && p <= r.tcp_options[0].max)) || r.source == "10.0.0.0/16"
      ])
    ])
    error_message = "epmd (4369), the distribution port (9100) or the dashboard (4041) is reachable from outside the VCN."
  }
}

run "no_rule_opens_ssh" {
  command = plan

  assert {
    condition = !anytrue([
      for r in oci_core_security_list.cluster.ingress_security_rules :
      length(r.tcp_options) == 0 || (r.tcp_options[0].min <= 22 && 22 <= r.tcp_options[0].max)
    ])
    error_message = "A rule opens SSH (22), by its own port or inside a range. The cluster is operated through the API, never a shell."
  }
}

run "the_client_listener_and_its_backends_use_the_same_port" {
  command = plan

  assert {
    condition     = oci_network_load_balancer_listener.client.port == 4040
    error_message = "The client listener must be on 4040."
  }

  assert {
    condition     = alltrue([for b in values(oci_network_load_balancer_backend.client) : b.port == 4040])
    error_message = "Every load balancer backend must point at the client port 4040."
  }
}
