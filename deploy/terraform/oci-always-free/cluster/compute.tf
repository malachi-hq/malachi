# Newest Ubuntu 24.04 image per architecture, so an arm64 A1 and an amd64 micro each get the right image.
data "oci_core_images" "arm" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_core_images" "amd" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "node" {
  for_each = local.nodes

  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = each.key
  shape               = each.value.shape

  # shape_config exists only on the flex shape. The micro takes its fixed size.
  dynamic "shape_config" {
    for_each = each.value.shape == "VM.Standard.A1.Flex" ? [1] : []
    content {
      ocpus         = 1
      memory_in_gbs = var.a1_memory_gbs
    }
  }

  source_details {
    source_type = "image"
    source_id   = each.value.arch == "arm" ? data.oci_core_images.arm.images[0].id : data.oci_core_images.amd.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.nodes.id
    hostname_label   = each.key
    assign_public_ip = true
  }

  metadata = {
    user_data = base64encode(templatefile("${path.module}/templates/node.cloud-init.yaml.tftpl", {
      node_name       = each.key
      node_fqdn       = local.node_fqdns[each.key]
      log_nodes       = local.log_nodes
      image_tag       = var.image_tag
      cookie          = random_password.cookie.result
      admin_pass      = random_password.admin.result
      producer_pass   = random_password.producer.result
      consumer_pass   = random_password.consumer.result
      app_pass        = random_password.app.result
      node_key_b64    = base64encode(tls_private_key.node[each.key].private_key_pem)
      node_cert_b64   = base64encode(tls_locally_signed_cert.node[each.key].cert_pem)
      ca_cert_b64     = base64encode(tls_self_signed_cert.ca.cert_pem)
      client_key_b64  = base64encode(tls_private_key.client.private_key_pem)
      client_cert_b64 = base64encode(tls_locally_signed_cert.client.cert_pem)
    }))
  }
}
