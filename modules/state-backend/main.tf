#-------------------------------------------------------------------------------
# Module: state-backend
# Purpose: Bootstrap S3 bucket and DynamoDB table for Terraform remote state.
# Run ONCE before the root module with a local backend, then migrate.
#--------------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

#--------------------------------------------------------------------------------
# S3 Bucket — remote state storage
#--------------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket        = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "Terraform Remote State"
    Project = var.project
  }
}

# Enable versioning to protect against accidental overwrites and deletions of state files
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption with AES-256 to protect state files at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block all public access to ensure state files are not exposed
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rule to expire non-current versions after 90 days to manage storage costs
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

#--------------------------------------------------------------------------------
# DynamoDB Table — state locking
#--------------------------------------------------------------------------------

# Create a DynamoDB table for Terraform state locking to prevent concurrent modifications
resource "aws_dynamodb_table" "lock" {
  name         = "${var.project}-lock"
  billing_mode = "PAY_PER_REQUEST" # On-Demand billing to avoid capacity planning
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Enable point-in-time recovery to protect against accidental deletions
  point_in_time_recovery {
    enabled = true
  }
  # Enable server-side encryption to protect lock data at rest
  server_side_encryption {
    enabled = true
  }

  tags = {
    Name    = "Terraform State Lock"
    Project = var.project
  }
}
