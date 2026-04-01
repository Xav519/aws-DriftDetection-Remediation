output "security_group_id" {
  description = "Security Group ID - used in drift simulation scripts"
  value       = aws_security_group.monitored.id
}

output "s3_bucket_name" {
  description = "Monitored S3 bucket name"
  value       = aws_s3_bucket.monitored.id
}

output "iam_role_name" {
  description = "Monitored IAM role name"
  value       = aws_iam_role.monitored.name
}

output "iam_role_arn" {
  description = "Monitored IAM role ARN"
  value       = aws_iam_role.monitored.arn
}
