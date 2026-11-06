# Always Free arithmetic for the cluster root, checked on the plan with mocked providers. A change that would
# leave the free tier fails here, before a real apply can. Needs Terraform 1.7 or newer (mock_provider), so
# this runs in CI on the newest Terraform, never on the 1.5.7 that Resource Manager uses.

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

run "the_cluster_fits_the_always_free_compute_block_and_count_limits" {
  command = plan

  assert {
    condition     = length(oci_core_instance.node) == 3
    error_message = "The cluster must have exactly three nodes: two A1 and one micro."
  }

  assert {
    condition     = length([for n in values(oci_core_instance.node) : n if n.shape == "VM.Standard.E2.1.Micro"]) == 1
    error_message = "The cluster takes one E2 micro; the orchestrator takes the second of the two free micros."
  }

  assert {
    condition     = sum([for n in values(oci_core_instance.node) : n.shape == "VM.Standard.A1.Flex" ? n.shape_config[0].ocpus : 0]) <= 2
    error_message = "A1 OCPUs across the cluster exceed the 2 OCPU Always Free pool."
  }

  assert {
    condition     = sum([for n in values(oci_core_instance.node) : n.shape == "VM.Standard.A1.Flex" ? n.shape_config[0].memory_in_gbs : 0]) <= 12
    error_message = "A1 memory across the cluster exceeds the 12 GB Always Free pool."
  }

  assert {
    condition     = sum([for n in values(oci_core_instance.node) : n.source_details[0].boot_volume_size_in_gbs]) <= 150
    error_message = "Cluster boot volumes must leave 50 GB of the 200 GB block allowance for the orchestrator."
  }
}

run "a1_memory_above_the_per_node_share_of_the_pool_is_refused" {
  command = plan

  variables {
    a1_memory_gbs = 7
  }

  expect_failures = [var.a1_memory_gbs]
}
