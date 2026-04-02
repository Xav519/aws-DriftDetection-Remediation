# Root Variables
#------------------------#

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ca-central-1"
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