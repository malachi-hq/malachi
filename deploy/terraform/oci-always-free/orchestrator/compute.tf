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

  # No hostname and no private DNS record: nothing connects to the orchestrator, and a hostname must be unique in
  # the subnet, which the replacement below would break while the old and the new instance both exist.
  create_vnic_details {
    subnet_id                 = oci_core_subnet.orchestrator.id
    assign_public_ip          = true
    assign_private_dns_record = false
  }

  # OCI refuses instance metadata above 32,000 bytes. The run script is gzipped before it is encoded, because the
  # whole template is base64-encoded once more and an uncompressed script alone took it past the limit. The
  # size is checked by tests/user_data.tftest.hcl.
  metadata = {
    user_data = base64encode(templatefile("${path.module}/templates/orchestrator.cloud-init.yaml.tftpl", {
      run_script_gz_b64      = base64gzip(file("${path.module}/files/daily-run.sh"))
      run_hour               = var.run_hour_utc
      stack_id               = var.stack_id
      cluster_compartment_id = var.cluster_compartment_id
      topic_id               = oci_ons_notification_topic.report.id
      image_tag              = var.image_tag
      region                 = var.region
      availability_domain    = var.availability_domain
    }))
  }

  # A change to the run script or the timer changes the user_data, and so replaces the instance. The new one is
  # created first: when OCI has no micro capacity, the create fails and the old orchestrator keeps running,
  # instead of being destroyed with nothing to replace it. Two micros fit the Always Free allowance only outside
  # the daily run, when the cluster's micro does not exist: apply this root then.
  lifecycle {
    create_before_destroy = true
  }
}
