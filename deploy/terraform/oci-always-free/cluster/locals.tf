locals {
  # Node names are alphanumeric on purpose: they become the OCI hostname label, which must be RFC 1123 safe
  # and is also the first label of the FQDN the nodes use as their Erlang node name.
  nodes = {
    malachi1 = { shape = "VM.Standard.A1.Flex", arch = "arm", in_lb = true }
    malachi2 = { shape = "VM.Standard.A1.Flex", arch = "arm", in_lb = true }
    malachi3 = { shape = "VM.Standard.E2.1.Micro", arch = "amd", in_lb = false }
  }

  # <hostname>.<subnet dns_label>.<vcn dns_label>.oraclevcn.com: the OCI internal DNS name, computable at plan.
  node_fqdns = {
    for name, _ in local.nodes :
    name => "${name}.${oci_core_subnet.nodes.dns_label}.${oci_core_vcn.cluster.dns_label}.oraclevcn.com"
  }

  # The one list every node is told about, so RELEASE_NODE, MALACHI_LOG_NODES and the certificate SANs cannot
  # drift apart.
  log_nodes = join(",", [for name in sort(keys(local.nodes)) : "malachi@${local.node_fqdns[name]}"])
}
