# One VCN, one public subnet, an internet gateway and no NAT gateway: NAT is not in the Always Free list
# (Oracle, Always Free Resources), so the nodes take public IPs and the security list is what closes them.
resource "oci_core_vcn" "cluster" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "malachi-cluster"
  dns_label      = "malachi"
}

resource "oci_core_internet_gateway" "cluster" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.cluster.id
  display_name   = "malachi-cluster-igw"
  enabled        = true
}

resource "oci_core_route_table" "cluster" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.cluster.id
  display_name   = "malachi-cluster-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.cluster.id
  }
}

# Ingress: the client port from anywhere (TLS only, enforced by the broker), SSH never, and the distribution
# and dashboard ports only from inside the VCN. Egress is open so the nodes can pull the image and the
# distribution packages over the internet gateway.
resource "oci_core_security_list" "cluster" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.cluster.id
  display_name   = "malachi-cluster-sl"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6" # TCP
    description = "client protocol, TLS enforced by the broker"

    tcp_options {
      min = 4040
      max = 4040
    }
  }

  ingress_security_rules {
    source      = var.vcn_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    description = "epmd, inside the VCN only"

    tcp_options {
      min = 4369
      max = 4369
    }
  }

  ingress_security_rules {
    source      = var.vcn_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    description = "pinned Erlang distribution port, inside the VCN only"

    tcp_options {
      min = 9100
      max = 9100
    }
  }

  ingress_security_rules {
    source      = var.vcn_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    description = "dashboard, inside the VCN only"

    tcp_options {
      min = 4041
      max = 4041
    }
  }
}

resource "oci_core_subnet" "nodes" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.cluster.id
  cidr_block        = var.subnet_cidr
  display_name      = "malachi-nodes"
  dns_label         = "nodes"
  route_table_id    = oci_core_route_table.cluster.id
  security_list_ids = [oci_core_security_list.cluster.id]
}
