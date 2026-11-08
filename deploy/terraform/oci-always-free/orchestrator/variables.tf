variable "region" {
  description = "OCI region (the tenancy's home region: Always Free compute exists only there)."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID. Policies are created at the root so the dynamic group can reach the cluster compartment."
  type        = string
}

variable "orchestrator_compartment_id" {
  description = "Compartment of the fixed orchestrator. Its instances form the dynamic group, and nothing else in the tenancy does."
  type        = string
}

variable "cluster_compartment_id" {
  description = "Dedicated compartment for the ephemeral cluster. The sweep and the Resource Manager policy are limited to it."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain of the orchestrator micro."
  type        = string
}

variable "stack_id" {
  description = "OCID of the Resource Manager stack the daily run drives. Created once at bootstrap with the OCI CLI: the Terraform provider in use has no Resource Manager stack resource (see README)."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.ormstack\\.", var.stack_id))
    error_message = "stack_id must be a Resource Manager stack OCID (ocid1.ormstack...)."
  }
}

variable "notify_email" {
  description = "E-mail that receives the daily report, failures and the absence alarm. Confirmed once through Notifications."
  type        = string
}

variable "image_tag" {
  description = "Pinned Malachi image tag the probe runs. Never latest."
  type        = string

  validation {
    condition     = var.image_tag != "latest" && length(var.image_tag) > 0
    error_message = "image_tag must be a pinned tag, never empty and never latest."
  }
}

variable "run_hour_utc" {
  description = "Hour (UTC) of the daily run. The timer fires once a day at this hour."
  type        = number
  default     = 3

  validation {
    condition     = var.run_hour_utc >= 0 && var.run_hour_utc <= 23
    error_message = "run_hour_utc must be between 0 and 23."
  }
}
