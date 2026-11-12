# Dynamic group: every instance in the orchestrator's own compartment, and no other instance in the tenancy.
resource "oci_identity_dynamic_group" "orchestrator" {
  compartment_id = var.tenancy_ocid
  name           = "malachi-orchestrator"
  description    = "Malachi daily orchestrator instances (instance principal)."
  matching_rule  = "ALL {instance.compartment.id = '${var.orchestrator_compartment_id}'}"
}

# Least privilege for the daily run, all limited to the cluster compartment:
# - manage orm-stacks and orm-jobs in the ORCHESTRATOR compartment: the stack lives there, and only the cluster's
#   resources are created in the cluster compartment (the stack's config passes that compartment as a variable).
# - manage orm-jobs WITHOUT the PLAN/APPLY condition from Oracle's example: the destroy job must be allowed.
#   The example condition would block the teardown, which is the one thing this run must never fail to do.
# - read / use: the job logs and the stack list. Compute and networking only for the actions the run takes.
resource "oci_identity_policy" "orchestrator" {
  compartment_id = var.tenancy_ocid
  name           = "malachi-orchestrator"
  description    = "Allows the daily orchestrator to apply and destroy the ephemeral cluster, and nothing else."

  # Terraform 1.5 cannot cross-check two variables in a validation block, so the rule lives here. If the cluster
  # and the orchestrator shared a compartment, the sweep would reach the orchestrator itself.
  lifecycle {
    precondition {
      condition     = var.cluster_compartment_id != var.orchestrator_compartment_id
      error_message = "The cluster and the orchestrator must not share a compartment."
    }
  }

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to manage orm-stacks in compartment id ${var.orchestrator_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to manage orm-jobs in compartment id ${var.orchestrator_compartment_id}",
    # What the cluster root creates, so the job can apply and destroy it: its VCN, subnet, gateway, route table
    # and security list, its instances and their boot volumes, and its network load balancer.
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to manage virtual-network-family in compartment id ${var.cluster_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to manage instance-family in compartment id ${var.cluster_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to manage volume-family in compartment id ${var.cluster_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to manage network-load-balancers in compartment id ${var.cluster_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to read instance-images in tenancy",
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to read metrics in compartment id ${var.cluster_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to inspect all-resources in compartment id ${var.cluster_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.orchestrator.name} to use ons-topics in compartment id ${var.orchestrator_compartment_id}",
  ]
}
