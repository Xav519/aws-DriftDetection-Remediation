###############################################################################
# Root Variables
###############################################################################

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "project" {
  description = "Project name used as a prefix for all resource names"
  type        = string
  default     = "drift-detection"
}

variable "owner" {
  description = "Owner tag — your name or team"
  type        = string
  default     = "xavier"
}

variable "alert_email" {
  description = "Email address that receives drift alert notifications"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for drift alerts (leave empty to disable)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "drift_table_name" {
  description = "DynamoDB table name for storing drift events"
  type        = string
  default     = "drift-events"
}

variable "detection_schedule" {
  description = "EventBridge cron schedule for drift detection runs"
  type        = string
  default     = "cron(0 */6 * * ? *)" # Every 6 hours
}

variable "auto_remediate_enabled" {
  description = "If true, low-severity drift is auto-remediated. Critical always requires manual approval."
  type        = bool
  default     = false
}
