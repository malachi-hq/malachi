data "oci_core_images" "orchestrator" {
  compartment_id           = var.orchestrator_compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "orchestrator" {
  availability_domain = var.availability_domain
  compartment_id      = var.orchestrator_compartment_id
  display_name        = "malachi-orchestrator"
  shape               = "VM.Standard.E2.1.Micro"

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.orchestrator.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.orchestrator.id
    hostname_label   = "orchestrator"
    assign_public_ip = true
  }

  metadata = {
    user_data = base64encode(templatefile("${path.module}/templates/orchestrator.cloud-init.yaml.tftpl", {
      run_script_b64         = base64encode(file("${path.module}/files/daily-run.sh"))
      run_hour               = var.run_hour_utc
      stack_id               = var.stack_id
      cluster_compartment_id = var.cluster_compartment_id
      topic_id               = oci_ons_notification_topic.report.id
      image_tag              = var.image_tag
      region                 = var.region
      availability_domain    = var.availability_domain
    }))
  }
}
