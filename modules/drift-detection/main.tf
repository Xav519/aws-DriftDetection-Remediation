###############################################################################
# Module: drift-detection
# Purpose: Orchestrates a serverless pipeline to identify when AWS resources 
#          manually deviate from Terraform code (drift).
###############################################################################
###############################################################################
# DynamoDB - The Persistent Audit Log
# Stores a history of every drift event detected for reporting and tracking.
###############################################################################
resource "aws_dynamodb_table" "drift_events" {
  name         = var.drift_table_name
  billing_mode = "PAY_PER_REQUEST" # Scales automatically; no fixed monthly cost
  hash_key     = "resource_address"
  range_key    = "detected_at"      # Timestamp to allow history for the same resource
  attribute {
    name = "resource_address"
    type = "S"
  }
  attribute {
    name = "detected_at"
    type = "S"
  }
  attribute {
    name = "severity"
    type = "S"
  }
  # Allows quick lookup of "Critical" vs "Low" drift across the whole table
  global_secondary_index {
    name            = "SeverityIndex"
    hash_key         = "severity"
    range_key        = "detected_at"
    projection_type = "ALL"
  }
  # Automatically deletes old drift records to save storage costs over time
  ttl {
    attribute_name = "expires_at"
    enabled         = true
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
  tags = {
    Name = var.drift_table_name
  }
}
###############################################################################
# Lambda - The Brains
# This function processes raw Terraform JSON and decides if the drift is 
# dangerous (e.g., an open security group) or minor (e.g., a tag change).
###############################################################################
# Packages the Python code located in the /lambda folder into a ZIP for deployment
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda"
  output_path = "${path.root}/lambda_payload.zip"
}
resource "aws_lambda_function" "drift_parser" {
  function_name    = "${var.project}-${var.environment}-drift-parser"
  description      = "Parses terraform plan JSON, classifies severity, writes to DynamoDB"
  filename         = "${path.root}/../lambda_payload.zip"
  source_code_hash = filebase64sha256("${path.root}/../lambda_payload.zip")
  handler          = "handler.lambda_handler" # Entry point in your Python script
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  role             = aws_iam_role.lambda_exec.arn
  # Configuration passed to the Python code via OS Environment Variables
  environment {
    variables = {
      DRIFT_TABLE_NAME       = var.drift_table_name
      SNS_TOPIC_ARN          = var.sns_topic_arn
      AWS_REGION_NAME        = var.aws_region
      AUTO_REMEDIATE_ENABLED = tostring(var.auto_remediate_enabled)
      ENVIRONMENT            = var.environment
    }
  }
  tracing_config {
    mode = "Active" # Enables AWS X-Ray for debugging performance bottlenecks
  }
  tags = {
    Name = "${var.project}-drift-parser"
  }
}
# Standard practice: define how long to keep the Lambda logs (default is 'forever')
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.drift_parser.function_name}"
  retention_in_days = 30
}
###############################################################################
# EventBridge - The Alarm Clock
# Automates the check so you don't have to run it manually.
###############################################################################
resource "aws_cloudwatch_event_rule" "drift_schedule" {
  name                = "${var.project}-${var.environment}-drift-schedule"
  description         = "Triggers drift detection Lambda on schedule"
  schedule_expression = var.detection_schedule # e.g., "cron(0 * * * ? *)" for hourly
  state               = "ENABLED"
}
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule = aws_cloudwatch_event_rule.drift_schedule.name
  arn  = aws_lambda_function.drift_parser.arn
  # Data sent to the Lambda so it knows it was started by a schedule
  input = jsonencode({
    source  = "scheduled"
    trigger = "eventbridge"
  })
}
# Specifically grants EventBridge permission to "poke" the Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_parser.function_name
  principal     = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.drift_schedule.arn
}
###############################################################################
# IAM - Lambda Permissions
# Least-privilege access for the Lambda function.
###############################################################################
# Allows the Lambda service to assume this role
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project}-${var.environment}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  description        = "Drift detection Lambda execution role"
}
# The specific "Work" permissions for the Lambda
data "aws_iam_policy_document" "lambda_permissions" {
  # Write logs
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"]
  }
  # Read plan JSON uploaded by GitHub Actions to S3
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.project}-tfstate-${data.aws_caller_identity.current.account_id}/drift-plans/*"]
  }
  # Read/Write to its own DynamoDB log table
  statement {
    effect  = "Allow"
    actions = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:UpdateItem"]
    resources = [
      aws_dynamodb_table.drift_events.arn,
      "${aws_dynamodb_table.drift_events.arn}/index/*"
    ]
  }
  # Send alerts via SNS (email/Slack/PagerDuty)
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }
  # Record performance metrics and traces
  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData", "xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}
resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "drift-lambda-permissions"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}
###############################################################################
# IAM OIDC - Secure GitHub Actions Integration
# This is the modern way to connect CI/CD to AWS without using long-lived
# Access Keys that can be leaked or stolen.
###############################################################################
# Fetches the current AWS Account ID for resource names
data "aws_caller_identity" "current" {}
# Verifies GitHub's identity via HTTPS
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}
# Establishes a "trust relationship" between your AWS account and GitHub
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}
# Defines the rules for WHO at GitHub can use this role
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # CRITICAL SECURITY: Only allows your specific repo to assume this role
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = ["repo:${var.github_repo}:*"]
    }
  }
}
resource "aws_iam_role" "github_actions" {
  name                 = "${var.project}-${var.environment}-github-actions"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume.json
  description          = "Role assumed by GitHub Actions via OIDC - no static credentials"
  max_session_duration = 3600
}
# Permissions for the GitHub Runner to run 'terraform plan' and check drift
data "aws_iam_policy_document" "github_actions_permissions" {
  # Access to the state files in S3
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${var.project}-tfstate-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project}-tfstate-${data.aws_caller_identity.current.account_id}/*"
    ]
  }
  # Lock the state so two runs don't collide
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.project}-lock"]
  }
  # Read-only permissions to inspect infrastructure for drift comparison.
  # Uses broad Get*/List*/Describe* per service so terraform plan never hits
  # AccessDenied when reading tags, TTL, backups, dashboards, etc.
  statement {
    effect = "Allow"
    actions = [
      "ec2:Describe*", "ec2:Get*",
      "iam:Get*", "iam:List*",
      "s3:Get*", "s3:List*",
      "dynamodb:Describe*", "dynamodb:List*",
      "lambda:Get*", "lambda:List*",
      "sns:Get*", "sns:List*",
      "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*",
      "events:Describe*", "events:Get*", "events:List*",
      "logs:Describe*", "logs:Get*", "logs:List*",
      "xray:Get*", "xray:List*"
    ]
    resources = ["*"]
  }
  # Permission to trigger the classification Lambda manually if needed
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.drift_parser.arn]
  }
  # Permission to read the drift history table for generating CI reports
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:Query", "dynamodb:Scan"]
    resources = [
      aws_dynamodb_table.drift_events.arn,
      "${aws_dynamodb_table.drift_events.arn}/index/*"
    ]
  }
}
resource "aws_iam_role_policy" "github_actions_permissions" {
  name   = "github-actions-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
###############################################################################
# Remediation Policy
# OPTIONAL: If auto-remediation is enabled, this grants GitHub the power 
# to "fix" (terraform apply) changes to security groups, S3, and IAM.
###############################################################################
resource "aws_iam_role_policy" "github_actions_remediate" {
  count = var.auto_remediate_enabled ? 1 : 0 # Only creates this if the variable is 'true'
  name = "github-actions-remediate"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupEgress",
          "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
          "s3:PutBucketEncryption", "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketVersioning",
          "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy"
        ]
        Resource = "*"
      }
    ]
  })
}
