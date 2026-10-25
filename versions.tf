terraform {
  required_version = ">= 1.7"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
  # Portfolio upgrade (do AFTER first apply works): remote state
  # backend "s3" { bucket = "greg-tfstate", key = "demand-test/terraform.tfstate", region = "us-east-1" }
}

provider "aws" {
  region = "us-east-1" # keep everything here; CloudFront requires us-east-1 ACM certs
  default_tags {
    tags = {
      project    = "demand-test"
      managed_by = "terraform"
    }
  }
}