# The orchestrator's rules that matter most: the destroy must be allowed, the cluster's resource families must be
# granted in the cluster compartment, the orchestrator and the cluster may not share a compartment, the timer uses
# the configured hour, and every pin is checked before a run starts. Needs Terraform 1.7 or newer.

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

run "the_cluster_resource_families_are_granted_in_the_cluster_compartment" {
  command = plan

  # Each family the cluster root creates or destroys: its network, its instances and boot volumes, its load balancer.
  assert {
    condition = alltrue([
      contains(oci_identity_policy.orchestrator.statements, "Allow dynamic-group malachi-orchestrator to manage virtual-network-family in compartment id ocid1.compartment.oc1..testcluster"),
      contains(oci_identity_policy.orchestrator.statements, "Allow dynamic-group malachi-orchestrator to manage instance-family in compartment id ocid1.compartment.oc1..testcluster"),
      contains(oci_identity_policy.orchestrator.statements, "Allow dynamic-group malachi-orchestrator to manage volume-family in compartment id ocid1.compartment.oc1..testcluster"),
      contains(oci_identity_policy.orchestrator.statements, "Allow dynamic-group malachi-orchestrator to manage network-load-balancers in compartment id ocid1.compartment.oc1..testcluster"),
    ])
    error_message = "The destroy cannot terminate a cluster resource family this policy does not grant in the cluster compartment."
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

run "latest_is_never_a_deployable_image_tag" {
  command = plan

  variables {
    image_tag = "latest"
  }

  expect_failures = [var.image_tag]
}

run "the_daily_timer_is_rendered_from_the_configured_hour_not_a_fixed_one" {
  command = plan

  # The template must name the variable, and must not carry a fixed hour.
  assert {
    condition     = var.image_tag != "" && can(regex("OnCalendar=\\*-\\*-\\* \\$\\{run_hour\\}:00:00 UTC", file("templates/orchestrator.cloud-init.yaml.tftpl"))) && !can(regex("OnCalendar=\\*-\\*-\\* [0-9][0-9]:00:00", file("templates/orchestrator.cloud-init.yaml.tftpl")))
    error_message = "The timer must fire at run_hour_utc, not at a fixed hour."
  }
}

run "the_run_hour_must_be_a_valid_hour" {
  command = plan

  variables {
    run_hour_utc = 25
  }

  expect_failures = [var.run_hour_utc]
}
