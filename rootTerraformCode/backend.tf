// Create this bucket beforehand to store the Terraform state  (remote backend)
terraform {
   # Remote state -- bootstrapped via modules/state-backend first run
  backend "s3" {}
}