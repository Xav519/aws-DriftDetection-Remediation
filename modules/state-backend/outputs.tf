#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------

output "s3_bucket_name" {
  description = "S3 bucket name -- paste into root backend config"
  value       = aws_s3_bucket.tfstate.bucket
}

output "dynamodb_table_name" {
  description = "DynamoDB table name -- paste into root backend config"
  value       = aws_dynamodb_table.lock.name
}