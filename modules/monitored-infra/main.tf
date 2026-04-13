# aws_caller_identity is used to get the current AWS account ID and user information. 
data "aws_caller_identity" "current" {}
################################################################################
# Module: monitored-infra
# Purpose: Dummy target infrastructure that will be monitored for drift.
#          Includes a Security Group, IAM role, and S3 bucket -- the three
#          resource types most commonly involved in real-world security drift.
###############################################################################
# Default VPC data source, used for SG creation.
data "aws_vpc" "default" {
  default = true
}
# Security Group - primary drift target
# Simulation: script adds a new sg rule and detection catches it immediately
resource "aws_security_group" "monitored" {
  name        = "${var.project}-${var.environment}-monitored-sg"
  description = "Monitored security group - managed by Terraform, drift-detected"
  vpc_id      = data.aws_vpc.default.id

  # Explicitly declare zero ingress rules as desired state.
  # Without this, Terraform treats ingress as unmanaged and will never
  # flag manually-added rules as drift. With ingress = [], any rule
  # added outside Terraform shows up as a change in terraform plan.
  ingress = []

  # Only allow HTTPS outbound - intentionally locked down
  egress {
    description = "HTTPS outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Prevent Terraform from ignoring externally-added ingress rules.
  # This ensures drift detection sees any manual changes to ingress.
  lifecycle {
    ignore_changes = []
  }

  tags = {
    Name        = "${var.project}-monitored-sg"
    DriftTarget = "true"
  }
}
# S3 Bucket - secondary drift target
# Simulation: script disables encryption or makes bucket public
resource "aws_s3_bucket" "monitored" {
  bucket        = "${var.project}-${var.environment}-monitored-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags = {
    Name        = "${var.project}-monitored-bucket"
    DriftTarget = "true"
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "monitored" {
  bucket = aws_s3_bucket.monitored.id
  # Enforce AES256 encryption by default
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
# Block public access to the bucket - drift simulation could disable this and detection should catch it
resource "aws_s3_bucket_public_access_block" "monitored" {
  bucket = aws_s3_bucket.monitored.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "monitored" {
  bucket = aws_s3_bucket.monitored.id
  # Enable versioning to add another potential drift target - simulation could disable this and detection should catch it
  versioning_configuration {
    status = "Enabled"
  }
}
# IAM Role - third drift target
# Simulation: script adds AdministratorAccess policy attachment
# Who can use the role?
data "aws_iam_policy_document" "monitored_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
# Create the IAM Role
resource "aws_iam_role" "monitored" {
  name               = "${var.project}-${var.environment}-monitored-role"
  assume_role_policy = data.aws_iam_policy_document.monitored_assume.json
  description        = "Monitored IAM role - drift detection target"
  tags = {
    DriftTarget = "true"
  }
}
# Permission Policy - What the role can do
resource "aws_iam_role_policy" "monitored_inline" {
  name = "monitored-minimal-policy"
  role = aws_iam_role.monitored.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.monitored.arn}/*"
      }
    ]
  })
}
