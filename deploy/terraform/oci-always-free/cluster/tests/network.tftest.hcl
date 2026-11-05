# The network invariants of the cluster: only the client port faces the internet, the distribution, epmd and
# dashboard ports stay inside the VCN, and SSH is never open. Plan-only, with mocked providers.

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

  assert {
    condition = alltrue([
      for r in oci_core_security_list.cluster.ingress_security_rules :
      r.source != "0.0.0.0/0" || (length(r.tcp_options) == 1 && r.tcp_options[0].min == 4040 && r.tcp_options[0].max == 4040)
    ])
    error_message = "An ingress rule opens something other than the client port 4040 to 0.0.0.0/0."
  }
}

run "epmd_the_distribution_port_and_the_dashboard_stay_inside_the_vcn" {
  command = plan

  assert {
    condition = alltrue([
      for r in oci_core_security_list.cluster.ingress_security_rules :
      length(r.tcp_options) == 0 || !contains([4369, 9100, 4041], r.tcp_options[0].min) || r.source == "10.0.0.0/16"
    ])
    error_message = "epmd (4369), the distribution port (9100) or the dashboard (4041) is reachable from outside the VCN."
  }
}

run "no_rule_opens_ssh" {
  command = plan

  assert {
    condition = alltrue([
      for r in oci_core_security_list.cluster.ingress_security_rules :
      length(r.tcp_options) == 0 || r.tcp_options[0].min != 22
    ])
    error_message = "A rule opens SSH (22). The cluster is operated through the API, never through a shell."
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
