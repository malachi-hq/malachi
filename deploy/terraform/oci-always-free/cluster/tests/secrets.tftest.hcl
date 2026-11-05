# The secrets the cluster generates: long random values with no special characters, and certificates that live
# for the length of one run only. A later edit that shortens them or makes them permanent fails here.

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

run "certificates_live_for_one_run_only_72_hours" {
  command = plan

  assert {
    condition     = tls_self_signed_cert.ca.validity_period_hours == 72
    error_message = "The CA must expire within the run's lifetime."
  }

  assert {
    condition     = alltrue([for c in values(tls_locally_signed_cert.node) : c.validity_period_hours == 72])
    error_message = "Every node certificate must expire within the run's lifetime."
  }
}

run "each_node_has_its_own_distribution_key" {
  command = plan

  assert {
    condition     = length(tls_private_key.node) == 3
    error_message = "Each of the three nodes needs its own distribution key."
  }
}
