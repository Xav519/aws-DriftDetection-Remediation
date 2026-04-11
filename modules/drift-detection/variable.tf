
variable "environment"             {
     type = string 
     }
variable "project"                 { 
    type = string
     }
variable "aws_region"              { 
    type = string 
    }
variable "drift_table_name"        {
     type = string 
     }
variable "sns_topic_arn"           { 
    type = string 
    }
variable "detection_schedule"      { 
    type = string 
    }
variable "auto_remediate_enabled"  {
     type = bool 
     }

variable "github_repo" {
  description = "GitHub repo in format 'owner/repo-name"
  type        = string
  default     = "Xav519/aws-DriftDetection-Remediation"
}
