###############################################################################
# Module: notifications
# Purpose: Creates an SNS topic for drift alerts and optionally forwards alerts
# to Slack using a Lambda function.
###############################################################################

###############################################################################
# SNS Topic: drift alerts
###############################################################################

# Creates an SNS topic to send drift alerts
resource "aws_sns_topic" "drift_alerts" {
  name              = "${var.project}-${var.environment}-drift-alerts"
  kms_master_key_id = "alias/aws/sns" # Use default AWS managed KMS key for encryption

  tags = {
    Name = "${var.project}-drift-alerts"
  }
}

# Subscribe an email endpoint to the SNS topic
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.drift_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # Destination email address from variable
}

###############################################################################
# Slack forwarder Lambda (optional)
###############################################################################

# Package the Python Lambda code into a zip file if a Slack webhook URL is provided
data "archive_file" "slack_lambda_zip" {
  count       = var.slack_webhook != "" ? 1 : 0 # Only create if Slack webhook is set
  type        = "zip" # Output archive type
  source_file = "${path.module}/slack_forwarder.py" # Lambda source code
  output_path = "${path.module}/slack_lambda.zip" # Output zip file
}

# Create a Lambda function that forwards SNS alerts to Slack
resource "aws_lambda_function" "slack_forwarder" {
  count = var.slack_webhook != "" ? 1 : 0 # Only create if Slack webhook is set

  function_name    = "${var.project}-${var.environment}-slack-forwarder"
  description      = "Forwards SNS drift alerts to Slack"
  filename         = data.archive_file.slack_lambda_zip[0].output_path # Lambda zip file
  source_code_hash = data.archive_file.slack_lambda_zip[0].output_base64sha256 # Ensures updates trigger redeploy
  handler          = "slack_forwarder.lambda_handler" # Python handler function
  runtime          = "python3.12" # Runtime environment
  timeout          = 30 # Max execution time in seconds
  role             = aws_iam_role.slack_lambda_exec[0].arn # Lambda execution IAM role

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook
    }
  }
}

# Subscribe the Lambda function to the SNS topic
resource "aws_sns_topic_subscription" "slack" {
  count     = var.slack_webhook != "" ? 1 : 0
  topic_arn = aws_sns_topic.drift_alerts.arn
  protocol  = "lambda" # Lambda subscription
  endpoint  = aws_lambda_function.slack_forwarder[0].arn
}

# Grant SNS permission to invoke the Lambda function
resource "aws_lambda_permission" "allow_sns_slack" {
  count         = var.slack_webhook != "" ? 1 : 0
  statement_id  = "AllowSNSInvoke" # Identifier for this permission
  action        = "lambda:InvokeFunction" # Allow invocation
  function_name = aws_lambda_function.slack_forwarder[0].function_name
  principal     = "sns.amazonaws.com" # SNS is allowed to invoke
  source_arn    = aws_sns_topic.drift_alerts.arn # Only allow this specific topic
}

###############################################################################
# IAM Role for Slack Lambda
###############################################################################

# Define the assume-role policy for Lambda
data "aws_iam_policy_document" "slack_assume" {
  count = var.slack_webhook != "" ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"] # Lambda can assume this role
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"] # Trusted entity: Lambda service
    }
  }
}

# Create the IAM role that Lambda assumes
resource "aws_iam_role" "slack_lambda_exec" {
  count              = var.slack_webhook != "" ? 1 : 0
  name               = "${var.project}-${var.environment}-slack-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.slack_assume[0].json
}

# Attach the basic execution policy to the Lambda role (allows logging)
resource "aws_iam_role_policy_attachment" "slack_logs" {
  count      = var.slack_webhook != "" ? 1 : 0
  role       = aws_iam_role.slack_lambda_exec[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
