###############################################################################
# Drift Detection & Remediation — Root Module
# Author : Xavier
# Project: Portfolio — AWS Infrastructure Drift Detection
###############################################################################

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

data "aws_caller_identity" "current" {}
###############################################################################
# Modules
###############################################################################

module "monitored_infra" {
  source      = "../modules/monitored-infra"
  environment = var.environment
  project     = var.project
}

module "notifications" {
  source         = "../modules/notifications"
  environment    = var.environment
  project        = var.project
  alert_email    = var.alert_email
  slack_webhook  = var.slack_webhook_url
}

module "drift_detection" {
  source                  = "../modules/drift-detection"
  environment             = var.environment
  project                 = var.project
  aws_region              = var.aws_region
  drift_table_name        = var.drift_table_name
  sns_topic_arn           = module.notifications.sns_topic_arn
  detection_schedule      = var.detection_schedule
  auto_remediate_enabled  = var.auto_remediate_enabled
}

module "dashboard" {
  source           = "../modules/dashboard-CloudWatch"
  environment      = var.environment
  project          = var.project
  aws_region       = var.aws_region
  drift_table_name = var.drift_table_name
  lambda_name      = module.drift_detection.lambda_function_name
}
