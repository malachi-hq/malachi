# The report and the failures go to one topic. E-mail is confirmed once by the maintainer after the first apply.
resource "oci_ons_notification_topic" "report" {
  compartment_id = var.orchestrator_compartment_id
  name           = "malachi-daily-report"
  description    = "Daily cluster report and failures from malachi-orchestrator."
}

resource "oci_ons_subscription" "report_email" {
  compartment_id = var.orchestrator_compartment_id
  topic_id       = oci_ons_notification_topic.report.id
  protocol       = "EMAIL"
  endpoint       = var.notify_email
}

# Heartbeat without a custom metric: the orchestrator's own CPU series from the built-in agent namespace. When
# the instance is gone or stopped, the series stops, and the alarm fires on the absence of data.
resource "oci_monitoring_alarm" "orchestrator_absent" {
  compartment_id        = var.orchestrator_compartment_id
  metric_compartment_id = var.orchestrator_compartment_id
  display_name          = "malachi-orchestrator-absent"
  namespace             = "oci_computeagent"
  query                 = "CpuUtilization[5m]{resourceId = \"${oci_core_instance.orchestrator.id}\"}.count() < 1"
  severity              = "CRITICAL"
  destinations          = [oci_ons_notification_topic.report.id]
  is_enabled            = true
  pending_duration      = "PT15M"
  body                  = "The Malachi orchestrator has stopped reporting: the daily cluster run may not be happening."
}
