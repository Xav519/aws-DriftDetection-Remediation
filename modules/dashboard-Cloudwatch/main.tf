
# Module: dashboard
# Purpose: CloudWatch dashboard with drift metrics + alarms for critical events

# Retrieves AWS account ID dynamically
data "aws_caller_identity" "current" {}


# CloudWatch Dashboard

resource "aws_cloudwatch_dashboard" "drift" {
  dashboard_name = "${var.project}-${var.environment}-drift-dashboard"

  # JSON definition of the dashboard widgets
  dashboard_body = jsonencode({
    widgets = [
      # Widget 1: Drift Events by Severity (last 24h view)
      # Shows total drift events + breakdown by severity levels
      # Helps quickly assess risk exposure
      {
        type = "metric"
        x = 0
        y = 0
        width = 8
        height = 6
        properties = {
          title  = "Drift Events by Severity (24h)"
          view   = "timeSeries"
          stacked = false
          # Custom application metrics from DriftDetection namespace
          metrics = [
            ["DriftDetection", "DriftEventsTotal", "Environment", var.environment, { label = "Total" }],
            ["DriftDetection", "CriticalDriftCount", "Environment", var.environment, { color = "#E01E5A", label = "Critical" }],
            ["DriftDetection", "HighDriftCount", "Environment", var.environment, { color = "#ECB22E", label = "High" }],
          ]
          period = 3600
          stat   = "Sum"
          region = var.aws_region
        }
      },

      # Widget 2: Remediation Success vs Failure
      # Tracks how effective automated/manual remediation is
      # Useful to detect broken playbooks or failing automation
      {
        type   = "metric"
        x      = 8
        y = 0
        width = 8
        height = 6
        properties = {
          title   = "Remediation Success Rate"
          view    = "timeSeries"
          metrics = [
            ["DriftDetection", "RemediationSuccessCount", "Environment", var.environment, { color = "#2EB886", label = "Success" }],
            ["DriftDetection", "RemediationFailureCount", "Environment", var.environment, { color = "#E01E5A", label = "Failed" }],
          ]
          period = 3600
          stat   = "Sum"
          region = var.aws_region
        }
      },

      # Widget 3: Mean Time To Remediation (MTTR)
      # Measures how long it takes to fix drift issues
      # Key operational efficiency KPI
      {
        type   = "metric"
        x      = 16
        y = 0
        width = 8
        height = 6
        properties = {
          title   = "Mean Time To Remediation (minutes)"
          view    = "timeSeries"
          metrics = [
            ["DriftDetection", "MeanTimeToRemediation", "Environment", var.environment, { label = "MTTR (min)" }],
          ]
          
          # Average is used instead of Sum for time-based metric
          period = 3600
          stat   = "Average"
          region = var.aws_region
        }
      },

      # Widget 4: Recent Drift Events (Logs Insights)
      # Displays last 20 drift events from Lambda logs
      # Helps with quick investigation without leaving dashboard
      {
        type   = "log"
        x      = 0
        y = 6
        width = 24
        height = 6
        properties = {
          title   = "Recent Drift Events"
          region  = var.aws_region

          # Logs Insights query:
          # - Filters only drift events
          # - Extracts key fields for analysis
          # - Sorts by most recent
          query   = "SOURCE '/aws/lambda/${var.lambda_name}' | fields @timestamp, severity, resource_address, change_type | filter @message like /DRIFT_EVENT/ | sort @timestamp desc | limit 20"
          view    = "table"
        }
      },

      # Widget 5: Active Alarms
      # Displays critical alarms directly on dashboard
      # Avoids needing to navigate to CloudWatch Alarms separately
      {
        type   = "alarm"
        x      = 0
        y = 12
        width = 24
        height = 2
        properties = {
          title  = "Active Alarms"
          alarms = [
            "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project}-${var.environment}-critical-drift",
            "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project}-${var.environment}-lambda-errors"
          ]
        }
      }
    ]
  })
}

# CloudWatch Alarm: Critical Drift Detection
# ------------------------------------------------------------------------------
# Triggers when at least 1 CRITICAL drift event is detected
# Immediate alerting (evaluation_periods = 1)
resource "aws_cloudwatch_metric_alarm" "critical_drift" {
  alarm_name          = "${var.project}-${var.environment}-critical-drift"
  alarm_description   = "Fires when any CRITICAL severity drift event is detected"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CriticalDriftCount"
  namespace           = "DriftDetection"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching" # Avoid false positives when no data is reported

# Scope metric to specific environment
  dimensions = {
    Environment = var.environment
  }

  # Notify via SNS (both alarm and recovery)
  alarm_actions = [aws_sns_topic.drift_alerts.arn]
  ok_actions    = [aws_sns_topic.drift_alerts.arn]
}


# CloudWatch Alarm: Lambda Errors
# ------------------------------------------------------------------------------
# Detects failures in the drift detection Lambda function
# Uses 2 evaluation periods to reduce noise from transient errors
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project}-${var.environment}-lambda-errors"
  alarm_description   = "Drift detection Lambda is failing"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  treat_missing_data  = "notBreaching"

  # Scope to specific Lambda function
  dimensions = {
    FunctionName = var.lambda_name
  }

  alarm_actions = [aws_sns_topic.drift_alerts.arn]
}