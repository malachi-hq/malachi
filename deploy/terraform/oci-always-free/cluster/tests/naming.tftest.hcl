# One list drives the node names, the Erlang node names and the log node list, so they cannot drift apart. No
# instance definition may carry a default password or the old example cookie, and no password may be a literal.

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

run "every_node_gets_the_fqdn_in_the_same_list_the_cluster_is_told_about" {
  command = plan

  assert {
    condition     = output.node_fqdns["malachi1"] == "malachi1.nodes.malachi.oraclevcn.com"
    error_message = "The FQDN must be <hostname>.<subnet label>.<vcn label>.oraclevcn.com."
  }

  assert {
    condition = output.log_nodes == join(",", [
      "malachi@malachi1.nodes.malachi.oraclevcn.com",
      "malachi@malachi2.nodes.malachi.oraclevcn.com",
      "malachi@malachi3.nodes.malachi.oraclevcn.com",
    ])
    error_message = "MALACHI_LOG_NODES must list every node by its malachi@<FQDN> name, in sorted order."
  }
}

# The cloud-init content depends on generated secrets, which are unknown at plan time, so these checks read the
# source text. Terraform requires an assertion to refer to an object of the configuration, so each condition also
# names the pinned image tag, which every node runs; the tag is never empty, so that part is always true.
run "no_default_password_or_example_cookie_is_written_anywhere_in_the_instance_definition" {
  command = plan

  assert {
    condition = var.image_tag != "" && (
      !can(regex("malachi-local-only", file("templates/node.cloud-init.yaml.tftpl"))) &&
      !can(regex("malachi_durable_cookie", file("templates/node.cloud-init.yaml.tftpl"))) &&
      !can(regex("malachi-local-only", file("compute.tf"))) &&
      !can(regex("malachi_durable_cookie", file("compute.tf")))
    )
    error_message = "A default password or the old example cookie is written into the node definition or its template."
  }
}

# A literal password of any name or value: every *_pass or *_password and the cookie must come from
# a generated resource, never from a quoted string in the node definition.
run "no_password_or_cookie_is_a_literal_in_the_node_definition" {
  command = plan

  assert {
    condition = var.image_tag != "" && (
      !can(regex("[A-Za-z_]*(pass|password)\\s*=\\s*\"", file("compute.tf"))) &&
      !can(regex("cookie\\s*=\\s*\"", file("compute.tf")))
    )
    error_message = "A password or the cookie is a literal string in compute.tf instead of a generated value."
  }
}

run "every_node_is_rendered_with_the_one_log_node_list" {
  command = plan

  assert {
    condition     = var.image_tag != "" && can(regex("log_nodes\\s*=\\s*local\\.log_nodes", file("compute.tf")))
    error_message = "compute.tf must pass the single log node list to every node's template."
  }

  assert {
    condition     = var.image_tag != "" && can(regex("MALACHI_LOG_NODES=\\$\\{log_nodes\\}", file("templates/node.cloud-init.yaml.tftpl")))
    error_message = "The template must write MALACHI_LOG_NODES from the list it is given, not from a literal."
  }
}
