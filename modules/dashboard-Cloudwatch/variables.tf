variable "environment"      {
     type = string 
     }

variable "project"          { 
    type = string
     }

variable "aws_region"       { 
    type = string
     }

variable "drift_table_name" { 
    type = string
     }

variable "lambda_name"      { 
    type = string 
    }
    
variable "sns_topic_arn"    {
  type    = string
  default = ""
}
