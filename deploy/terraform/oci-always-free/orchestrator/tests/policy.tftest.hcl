# The orchestrator's rules that matter most: the destroy must be allowed, the orchestrator and the cluster must
# never share a compartment, and every pin is checked before a run starts. Needs Terraform 1.7 or newer.

variables {
  region                      = "replace-me-home-region"
  tenancy_ocid                = "ocid1.tenancy.oc1..testtenancy"
  orchestrator_compartment_id = "ocid1.compartment.oc1..testorchestrator"
  cluster_compartment_id      = "ocid1.compartment.oc1..testcluster"
  availability_domain         = "replace-me-ad"
  notify_email                = "maintainer@example.com"
  config_commit_sha           = "0123456789abcdef0123456789abcdef01234567"
  config_tarball_sha256       = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
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

run "the_daily_run_can_apply_and_destroy_manage_orm_jobs_has_no_plan_or_apply_condition" {
  command = plan

  assert {
    condition     = contains(oci_identity_policy.orchestrator.statements, "Allow dynamic-group malachi-orchestrator to manage orm-jobs in compartment id ocid1.compartment.oc1..testorchestrator")
    error_message = "The orchestrator must be able to manage jobs in its own compartment, including the destroy."
  }

  assert {
    condition     = alltrue([for s in oci_identity_policy.orchestrator.statements : !can(regex("PLAN|APPLY", s))])
    error_message = "A policy statement carries a PLAN or APPLY condition, which would block the destroy job."
  }
}

run "the_dynamic_group_matches_only_the_orchestrator_s_compartment" {
  command = plan

  assert {
    condition     = oci_identity_dynamic_group.orchestrator.matching_rule == "ALL {instance.compartment.id = 'ocid1.compartment.oc1..testorchestrator'}"
    error_message = "The dynamic group must match instances in the orchestrator compartment and nothing else."
  }
}

run "the_orchestrator_and_the_cluster_may_not_share_a_compartment" {
  command = plan

  variables {
    cluster_compartment_id = "ocid1.compartment.oc1..testorchestrator"
  }

  expect_failures = [oci_identity_policy.orchestrator]
}

run "a_stack_ocid_that_is_not_a_resource_manager_stack_is_refused" {
  command = plan

  variables {
    stack_id = "ocid1.instance.oc1..notastack"
  }

  expect_failures = [var.stack_id]
}

run "a_short_commit_sha_is_refused" {
  command = plan

  variables {
    config_commit_sha = "main"
  }

  expect_failures = [var.config_commit_sha]
}

run "a_tarball_hash_that_is_not_sha_256_is_refused" {
  command = plan

  variables {
    config_tarball_sha256 = "not-a-hash"
  }

  expect_failures = [var.config_tarball_sha256]
}

run "latest_is_never_a_deployable_image_tag" {
  command = plan

  variables {
    image_tag = "latest"
  }

  expect_failures = [var.image_tag]
}

run "the_daily_timer_fires_in_the_configured_utc_hour" {
  command = plan

  variables {
    run_hour_utc = 25
  }

  expect_failures = [var.run_hour_utc]
}
