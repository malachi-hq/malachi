# Same ceiling as the cluster root: Resource Manager runs at most Terraform 1.5.7 (Oracle, Supported Terraform
# Versions), so this root must validate there too.
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.12"
    }
  }
}
