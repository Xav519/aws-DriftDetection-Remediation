#!/usr/bin/env bash
###############################################################################
# bootstrap.sh
# For Unix environments only (Linux, macOS).
# First-time setup: provisions S3 + DynamoDB for remote state, then migrates.
# Run once from your local machine before any GitHub Actions deployments.
###############################################################################
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-drift-detection}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="${PROJECT}-tfstate-${ACCOUNT_ID}"
DYNAMO_TABLE="${PROJECT}-lock"

echo "=================================================="
echo " Drift Detection Bootstrap"
echo " Region  : $REGION"
echo " Account : $ACCOUNT_ID"
echo " Bucket  : $BUCKET_NAME"
echo "=================================================="
echo ""

###############################################################################
# Step 1 - Apply the state-backend module with a LOCAL backend first
###############################################################################
echo "Step 1: Bootstrapping remote state infrastructure..."
cd modules/state-backend

cat > backend_override.tf << EOF
terraform {
  backend "local" {}
}
EOF

terraform init -no-color
terraform apply \
  -auto-approve \
  -no-color \
  -var="project=${PROJECT}" \
  -var="aws_region=${REGION}"

rm backend_override.tf
cd ../..

###############################################################################
# Step 2 - Update backend config in main.tf with actual bucket name
###############################################################################
echo ""
echo "Step 2: Configuring remote backend..."
sed -i "s/drift-detection-tfstate/${BUCKET_NAME}/" main.tf
sed -i "s/drift-detection-lock/${DYNAMO_TABLE}/" main.tf

###############################################################################
# Step 3 - Initialize root module with remote backend
###############################################################################
echo ""
echo "Step 3: Initializing root module with remote backend..."
terraform init \
  -migrate-state \
  -no-color \
  -backend-config="bucket=${BUCKET_NAME}" \
  -backend-config="key=dev/terraform.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="dynamodb_table=${DYNAMO_TABLE}" <<< "yes"

###############################################################################
# Step 4 - Copy terraform.tfvars
###############################################################################
if [ ! -f terraform.tfvars ]; then
  cp terraform.tfvars.example terraform.tfvars
  echo ""
  echo "Step 4: Created terraform.tfvars - edit it before running terraform apply:"
  echo "  nano terraform.tfvars"
else
  echo ""
  echo "Step 4: terraform.tfvars already exists - skipping copy"
fi

echo ""
echo "=================================================="
echo " Bootstrap complete!"
echo ""
echo " Next steps:"
echo "  1. Edit terraform.tfvars with your email and settings"
echo "  2. Run: terraform plan"
echo "  3. Run: terraform apply"
echo "  4. Copy the github_actions_role_arn output"
echo "  5. Add to GitHub repo secrets: AWS_ROLE_ARN"
echo "     Also add: TF_STATE_BUCKET, TF_LOCK_TABLE, ALERT_EMAIL"
echo "=================================================="
