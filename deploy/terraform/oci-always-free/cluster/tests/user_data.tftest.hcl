# OCI refuses an instance whose metadata is above 32,000 bytes, and only at launch: plan and validate pass. Each
# node's user_data carries its own key and certificates, so this test renders it with the real tls and random
# providers (they run locally and need no credentials) and only OCI mocked. Needs Terraform 1.7 or newer.
#
# The check is against 30,000 bytes, not 32,000: the mock OCIDs and addresses are shorter than real ones, and the
# headroom keeps that difference from hiding a user_data that is just over.

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

  # The client certificate names the load balancer's address, so the apply needs one.
  mock_resource "oci_network_load_balancer_network_load_balancer" {
    defaults = {
      ip_addresses = [{ ip_address = "203.0.113.10", is_public = true }]
    }
  }
}

run "every_node_user_data_fits_the_oci_metadata_limit_with_headroom" {
  # apply: the keys and certificates are only known once the tls provider has generated them.
  command = apply

  assert {
    condition     = alltrue([for n in oci_core_instance.node : length(n.metadata["user_data"]) < 30000])
    # The user_data holds the generated passwords, so it is sensitive; its length reveals nothing, and without
    # nonsensitive() Terraform would hide the whole message.
    error_message = "A node's user_data is too large: ${jsonencode({ for k, n in oci_core_instance.node : k => nonsensitive(length(n.metadata["user_data"])) })} bytes; OCI refuses metadata above 32,000 at launch."
  }
}
