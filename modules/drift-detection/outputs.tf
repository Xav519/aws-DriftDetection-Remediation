output "lambda_function_name" {
  value = aws_lambda_function.drift_parser.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.drift_parser.arn
}

output "drift_table_arn" {
  value = aws_dynamodb_table.drift_events.arn
}

output "github_actions_role_arn" {
  description = "Paste this ARN into GitHub repo secret: AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}