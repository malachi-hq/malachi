# OCI refuses an instance whose metadata is above 32,000 bytes, and only at launch: plan and validate pass. This
# renders the orchestrator's user_data from the real run script and template, so a script that grows past the
# limit fails here instead of at the maintainer's apply. Needs Terraform 1.7 or newer.
#
# The check is against 30,000 bytes, not 32,000: the mock OCIDs are shorter than real ones (a real topic OCID is
# about 90 characters), and the headroom keeps that difference from hiding a user_data that is just over.

variables {
  region                      = "replace-me-home-region"
  tenancy_ocid                = "ocid1.tenancy.oc1..testtenancy"
  orchestrator_compartment_id = "ocid1.compartment.oc1..testorchestrator"
  cluster_compartment_id      = "ocid1.compartment.oc1..testcluster"
  availability_domain         = "replace-me-ad"
  notify_email                = "maintainer@example.com"
  image_tag                   = "0.22.7"
  stack_id                    = "ocid1.ormstack.oc1..teststack"
}

mock_provider "oci" {
  mock_data "oci_core_images" {
    defaults = {
      images = [{ id = "ocid1.image.oc1..mockimage" }]
    }
  }
}

run "the_orchestrator_user_data_fits_the_oci_metadata_limit_with_headroom" {
  # apply, against the mock provider: the user_data names the topic's id, which a plan does not know.
  command = apply

  assert {
    condition     = length(oci_core_instance.orchestrator.metadata["user_data"]) < 30000
    error_message = "The orchestrator's user_data is ${length(oci_core_instance.orchestrator.metadata["user_data"])} bytes; OCI refuses metadata above 32,000 at launch."
  }
}
