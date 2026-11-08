# Resource Manager offers Terraform 1.5.7 as its newest version (Oracle, Supported Terraform Versions), so
# the root must validate there. Providers are pinned to a minor series and committed as a lock file.
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
