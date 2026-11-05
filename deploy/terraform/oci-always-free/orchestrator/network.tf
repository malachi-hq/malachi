# The orchestrator has its own VCN in its own compartment. It survives the cluster, so it is never torn down.
# Two VCNs fit the Always Free allowance (Oracle, Always Free Resources), one for each side.
resource "oci_core_vcn" "orchestrator" {
  compartment_id = var.orchestrator_compartment_id
  cidr_blocks    = ["10.1.0.0/16"]
  display_name   = "malachi-orchestrator"
  dns_label      = "orchestr"
}

resource "oci_core_internet_gateway" "orchestrator" {
  compartment_id = var.orchestrator_compartment_id
  vcn_id         = oci_core_vcn.orchestrator.id
  display_name   = "malachi-orchestrator-igw"
  enabled        = true
}

resource "oci_core_route_table" "orchestrator" {
  compartment_id = var.orchestrator_compartment_id
  vcn_id         = oci_core_vcn.orchestrator.id
  display_name   = "malachi-orchestrator-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.orchestrator.id
  }
}

# No ingress at all: the orchestrator only dials out (OCI APIs, the image registry, the NLB's public address).
resource "oci_core_security_list" "orchestrator" {
  compartment_id = var.orchestrator_compartment_id
  vcn_id         = oci_core_vcn.orchestrator.id
  display_name   = "malachi-orchestrator-sl"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }
}

resource "oci_core_subnet" "orchestrator" {
  compartment_id    = var.orchestrator_compartment_id
  vcn_id            = oci_core_vcn.orchestrator.id
  cidr_block        = "10.1.1.0/24"
  display_name      = "malachi-orchestrator"
  dns_label         = "orch"
  route_table_id    = oci_core_route_table.orchestrator.id
  security_list_ids = [oci_core_security_list.orchestrator.id]
}
