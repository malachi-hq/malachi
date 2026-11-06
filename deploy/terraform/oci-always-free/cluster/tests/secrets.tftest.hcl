# The secrets the cluster generates: long random values with no special characters, and certificates that live
# for the length of one run only, the client-facing one included. Each node has its own distribution key.

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

run "the_cookie_is_48_characters_with_no_special_characters" {
  command = plan

  assert {
    condition     = random_password.cookie.length == 48 && random_password.cookie.special == false
    error_message = "The Erlang cookie must be 48 alphanumeric characters."
  }
}

run "the_seed_passwords_are_24_characters_with_no_special_characters" {
  command = plan

  assert {
    condition = alltrue([
      for p in [random_password.admin, random_password.producer, random_password.consumer, random_password.app] :
      p.length == 24 && p.special == false
    ])
    error_message = "Every seed password must be 24 alphanumeric characters."
  }
}

run "every_certificate_lives_for_one_run_only_72_hours_including_the_client_one" {
  command = plan

  assert {
    condition     = tls_self_signed_cert.ca.validity_period_hours == 72
    error_message = "The CA must expire within the run's lifetime."
  }

  assert {
    condition     = alltrue([for c in values(tls_locally_signed_cert.node) : c.validity_period_hours == 72])
    error_message = "Every node certificate must expire within the run's lifetime."
  }

  assert {
    condition     = tls_locally_signed_cert.client.validity_period_hours == 72
    error_message = "The client-facing certificate on port 4040 must expire within the run's lifetime."
  }
}

run "each_node_certificate_request_uses_its_own_distribution_key" {
  command = plan

  assert {
    condition     = length(tls_private_key.node) == 3
    error_message = "Each of the three nodes needs its own distribution key."
  }

  # The request's key is unknown until apply, so the wiring is checked in the source: each request names its own
  # node's key by the for_each key. Terraform requires an object reference, so the image tag is named as well.
  assert {
    condition     = var.image_tag != "" && can(regex("private_key_pem\\s*=\\s*tls_private_key\\.node\\[each\\.key\\]\\.private_key_pem", file("secrets.tf")))
    error_message = "A node's certificate request must be built from that node's own key."
  }
}
