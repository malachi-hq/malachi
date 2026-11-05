variable "region" {
  description = "OCI region (home region of the tenancy: Always Free compute exists only there)."
  type        = string
}

variable "compartment_id" {
  description = "OCID of the dedicated compartment for the cluster. The daily sweep only ever touches this one."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.compartment\\.", var.compartment_id))
    error_message = "compartment_id must be a compartment OCID (ocid1.compartment...)."
  }
}

variable "availability_domain" {
  description = "Availability domain for the instances, for example Uocm:PHX-AD-1. A1 capacity can be missing in one AD and present in another."
  type        = string
}

variable "image_tag" {
  description = "Published Malachi image tag (hectorcardoso/malachi). Required: there is deliberately no default, so latest can never be deployed by accident."
  type        = string

  validation {
    condition     = var.image_tag != "latest" && length(var.image_tag) > 0
    error_message = "image_tag must be a pinned tag, never empty and never latest."
  }
}

variable "vcn_cidr" {
  description = "CIDR of the VCN. Distribution ports are opened only to this range."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR of the node subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "a1_memory_gbs" {
  description = "Memory of each A1 node. The Always Free pool is 12 GB in total across A1 instances."
  type        = number
  default     = 6

  validation {
    condition     = var.a1_memory_gbs <= 6
    error_message = "a1_memory_gbs must be at most 6: the Always Free A1 pool is 12 GB across two A1 nodes."
  }
}

