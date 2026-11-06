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

variable "config_commit_sha" {
  description = "Commit of this repository whose cluster/ root the daily run applies. Pinned, never a branch."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.config_commit_sha))
    error_message = "config_commit_sha must be a full 40-character commit SHA."
  }
}

variable "config_tarball_sha256" {
  description = "SHA-256 of the GitHub tarball for config_commit_sha. The daily run refuses any archive that does not match."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.config_tarball_sha256))
    error_message = "config_tarball_sha256 must be a 64-character hex SHA-256."
  }
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
