###############################################################################
# Root Outputs
###############################################################################

output "drift_table_name" {
  description = "DynamoDB table storing drift events"
  value       = var.drift_table_name
}

output "sns_topic_arn" {
  description = "SNS topic ARN for drift alerts"
  value       = module.notifications.sns_topic_arn
}

output "lambda_function_name" {
  description = "Drift detection Lambda function name"
  value       = module.drift_detection.lambda_function_name
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = module.dashboard.dashboard_url
}

output "github_actions_role_arn" {
  description = "IAM role ARN to configure in GitHub Actions OIDC secret"
  value       = module.drift_detection.github_actions_role_arn
}

output "monitored_sg_id" {
  description = "Security Group ID used for drift simulation"
  value       = module.monitored_infra.security_group_id
}

output "monitored_s3_bucket" {
  description = "S3 bucket used for drift simulation"
  value       = module.monitored_infra.s3_bucket_name
}
