#Requires -Version 5.1
###############################################################################
# bootstrap.ps1
# For Windows/PowerShell environments.
# First-time setup for Windows/PowerShell.
# Provisions S3 + DynamoDB for Terraform remote state, then migrates the
# root module to use that remote backend.
#
# Run once from your local machine before any GitHub Actions deployments.
# Prerequisites: AWS CLI configured, Terraform installed, both in PATH.
#
# Usage:
#   cd C:\Users\xdup4\Documents\AWS_Learn\drift-detection
#   .\scripts\bootstrap.ps1
###############################################################################

# Stop on any error — equivalent to bash's set -e
$ErrorActionPreference = "Stop"

###############################################################################
# Config — override these by setting env vars before running, e.g.:
#   $env:AWS_REGION = "us-east-1"
#   $env:PROJECT    = "my-project"
###############################################################################

# Read from env var if set, otherwise use default — equivalent to ${VAR:-default}
$REGION  = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
$PROJECT = if ($env:PROJECT)    { $env:PROJECT    } else { "drift-detection" }

# Get your AWS account ID — equivalent to $(aws sts get-caller-identity ...)
Write-Host "Fetching AWS account ID..." -ForegroundColor Cyan
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)

if (-not $ACCOUNT_ID) {
    Write-Error "Could not retrieve AWS account ID. Is the AWS CLI configured? Run: aws configure"
    exit 1
}

# Build resource names — same logic as bash variable interpolation
$BUCKET_NAME  = "$PROJECT-tfstate-$ACCOUNT_ID"
$DYNAMO_TABLE = "$PROJECT-lock"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Yellow
Write-Host " Drift Detection Bootstrap"
Write-Host " Region  : $REGION"
Write-Host " Account : $ACCOUNT_ID"
Write-Host " Bucket  : $BUCKET_NAME"
Write-Host " Table   : $DYNAMO_TABLE"
Write-Host "==================================================" -ForegroundColor Yellow
Write-Host ""

###############################################################################
# Step 1 — Apply the state-backend module with a LOCAL backend first
#
# Why: The S3 bucket and DynamoDB table don't exist yet, so we can't use them
# as the backend. We bootstrap them with a local backend first, then migrate.
###############################################################################

Write-Host "Step 1: Bootstrapping remote state infrastructure..." -ForegroundColor Cyan

# Navigate into the state-backend module
Push-Location "..\modules\state-backend"

# Write a temporary backend_override.tf that forces a local backend.
# Equivalent to the bash heredoc: cat > file << EOF ... EOF
# The @" ... "@ syntax is PowerShell's multiline string (here-string).
$overrideContent = @"
terraform {
  backend "local" {}
}
"@
$overrideContent | Set-Content -Path "backend_override.tf" -Encoding UTF8

try {
    # Initialize Terraform with the local backend
    terraform init -no-color
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed" }

    # Apply the state-backend module (creates S3 bucket + DynamoDB table)
    # -auto-approve skips the "yes/no" prompt
    terraform apply `
        -auto-approve `
        -no-color `
        "-var=project=$PROJECT" `
        "-var=aws_region=$REGION"
    if ($LASTEXITCODE -ne 0) { throw "terraform apply failed for state-backend module" }
}
finally {
    # Always clean up the override file, even if apply failed
    # Equivalent to the bash: rm backend_override.tf
    if (Test-Path "backend_override.tf") {
        Remove-Item "backend_override.tf"
    }
}

# Go back to the project root — equivalent to cd ../..
Pop-Location

Write-Host "" 
Write-Host "Step 1 complete: S3 bucket and DynamoDB table created." -ForegroundColor Green

###############################################################################
# Step 2 — Update main.tf with the actual bucket and table names
#
# Why: main.tf has placeholder names in the backend block. We replace them
# with the real names now that we know the account ID.
#
# Equivalent to bash: sed -i "s/old/new/" main.tf
# PowerShell reads the whole file, does a string replace, writes it back.
###############################################################################

Write-Host ""
Write-Host "Step 2: Updating backend config in main.tf..." -ForegroundColor Cyan

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path "$scriptDir\.."
$mainTfPath = Join-Path $projectRoot "rootTerraformCode\main.tf"

if (-not (Test-Path $mainTfPath)) {
    Write-Error "main.tf not found. Make sure you're running this from the project root."
    exit 1
}

# Read file content, replace placeholder strings, write back
$mainTfContent = Get-Content -Path $mainTfPath -Raw
$mainTfContent = $mainTfContent -replace "drift-detection-tfstate", $BUCKET_NAME
$mainTfContent = $mainTfContent -replace "drift-detection-lock",    $DYNAMO_TABLE
$mainTfContent | Set-Content -Path $mainTfPath -Encoding UTF8 -NoNewline

Write-Host "Updated main.tf: bucket = $BUCKET_NAME, table = $DYNAMO_TABLE" -ForegroundColor Green

###############################################################################
# Step 3 — Re-initialize the root module with the remote S3 backend
#
# -migrate-state copies the local state file (from step 1's bootstrap apply,
# if any) into the remote S3 backend.
#
# The <<< "yes" in bash auto-answers the "do you want to copy state?" prompt.
# In PowerShell we pipe "yes" into terraform's stdin with: echo yes | terraform
###############################################################################

Write-Host ""
Write-Host "Step 3: Initializing root module with remote S3 backend..." -ForegroundColor Cyan

# Pipe "yes" to auto-confirm the state migration prompt
# Equivalent to bash: terraform init ... <<< "yes"
Write-Output "yes" | terraform init `
    -migrate-state `
    -no-color `
    "-backend-config=bucket=$BUCKET_NAME" `
    "-backend-config=key=dev/terraform.tfstate" `
    "-backend-config=region=$REGION" `
    "-backend-config=dynamodb_table=$DYNAMO_TABLE"

if ($LASTEXITCODE -ne 0) {
    Write-Error "terraform init with remote backend failed."
    exit 1
}

Write-Host "Root module initialized with remote backend." -ForegroundColor Green

###############################################################################
# Step 4 — Copy terraform.tfvars.example to terraform.tfvars
#
# Only copies if terraform.tfvars doesn't already exist (idempotent).
# Equivalent to bash: if [ ! -f terraform.tfvars ]; then cp ... fi
###############################################################################

Write-Host ""
Write-Host "Step 4: Checking terraform.tfvars..." -ForegroundColor Cyan

$tfvarsPath        = "terraform.tfvars"
$tfvarsExamplePath = "terraform.tfvars.example"

if (-not (Test-Path $tfvarsPath)) {
    if (Test-Path $tfvarsExamplePath) {
        Copy-Item -Path $tfvarsExamplePath -Destination $tfvarsPath
        Write-Host "Created terraform.tfvars from example." -ForegroundColor Green
        Write-Host "IMPORTANT: Edit it now before running terraform apply:" -ForegroundColor Yellow
        Write-Host "  notepad terraform.tfvars" -ForegroundColor White
    } else {
        Write-Warning "terraform.tfvars.example not found — create terraform.tfvars manually."
    }
} else {
    Write-Host "terraform.tfvars already exists — skipping copy." -ForegroundColor Green
}

###############################################################################
# Done
###############################################################################

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Bootstrap complete!"
Write-Host ""
Write-Host " Next steps:"
Write-Host "  1. Edit terraform.tfvars with your email and settings:"
Write-Host "       notepad terraform.tfvars"
Write-Host "  2. Run: terraform plan"
Write-Host "  3. Run: terraform apply"
Write-Host "  4. Copy the github_actions_role_arn output value"
Write-Host "  5. Add it to GitHub repo secrets as: AWS_ROLE_ARN"
Write-Host "     Also add: TF_STATE_BUCKET, TF_LOCK_TABLE, ALERT_EMAIL"
Write-Host "==================================================" -ForegroundColor Green
