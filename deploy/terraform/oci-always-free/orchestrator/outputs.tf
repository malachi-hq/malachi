output "orchestrator_public_ip" {
  description = "Public address of the orchestrator micro (outbound only, no ingress)."
  value       = oci_core_instance.orchestrator.public_ip
}

output "report_topic_id" {
  description = "Notification topic for the daily report."
  value       = oci_ons_notification_topic.report.id
}
