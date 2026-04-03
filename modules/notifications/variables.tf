
variable "environment"  { 
    type = string 
    }

variable "project"      { 
    type = string 
    }

variable "alert_email"  { 
    type = string 
    }

variable "slack_webhook" {
  type      = string
  default   = ""
  sensitive = true
}
