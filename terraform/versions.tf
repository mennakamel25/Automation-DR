terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.80" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }

  # backend "s3" {
  #   bucket       = "YOUR-TFSTATE-BUCKET"
  #   key          = "crp/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}

# Two regions of ONE AWS account.
#   default provider (aws)  = PRIMARY region: where production runs
#   aws.dr                  = DR region: DRS staging, recovery, the DR controller, the backup bucket
# Resources that live in the DR region always say `provider = aws.dr`.
provider "aws" {
  region = var.primary_region
  default_tags {
    tags = { Project = var.name_prefix, ManagedBy = "terraform", Site = "primary" }
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags {
    tags = { Project = var.name_prefix, ManagedBy = "terraform", Site = "dr" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  fqdn            = "${var.app_subdomain}.${var.domain_name}"
  internal_domain = var.internal_domain != "" ? var.internal_domain : "internal.${var.domain_name}"
}

resource "terraform_data" "region_guard" {
  lifecycle {
    precondition {
      condition     = var.primary_region != var.dr_region
      error_message = "primary_region and dr_region must be different regions."
    }
    precondition {
      condition     = var.primary_vpc_cidr != var.dr_vpc_cidr
      error_message = "The two VPC CIDRs must not overlap (they are peered)."
    }
  }
}
