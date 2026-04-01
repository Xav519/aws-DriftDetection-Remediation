#------------------------------------------------------------------------
# Drift Detection & Remediation -- Root Module
# Author : Xavier Dupuis
# Project: Portfolio -- AWS Infrastructure Drift Detection
#------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "drift-detection"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

#----------------------------------------------------------------------------
# Modules
#---------------------------------------------------------------------------

module "monitored_infra" {
  source      = "./modules/monitored-infra"
  environment = var.environment
  project     = var.project
}