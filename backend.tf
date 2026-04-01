// Create this bucket beforehand to store the Terraform state  (remote backend)
terraform {
   # Remote state -- bootstrapped via modules/state-backend first run
  backend "s3" {
    bucket         = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "${var.project}-lock" # Enable state locking with DynamoDB (to prevent concurrent modifications)
    encrypt        = true # Encrypt state files at rest
  }
}