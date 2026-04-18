# AWS Infrastructure Drift Detection & Automated Remediation
> **Portfolio project** by Xavier Dupuis

[![AWS](https://img.shields.io/badge/AWS-Cloud-FF9900?logo=amazonaws&logoColor=white)](https://aws.amazon.com)
[![Terraform](https://img.shields.io/badge/Terraform-1.7.5-7B42BC?logo=terraform&logoColor=white)](https://terraform.io)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)](https://python.org)
[![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-CI%2FCD-2088FF?logo=githubactions&logoColor=github)](https://github.com/features/actions)

---

## 🚨 Why This Project Matters

### The Problem This Solves

Every company running infrastructure in the cloud faces the same silent risk: **someone changes something manually, and no one finds out until it causes an incident.**

A developer opens a firewall port "just for testing" and forgets to close it. An engineer tweaks a security setting directly in the console during an outage. A script runs and disables encryption on a storage bucket. These changes bypass code review, leave no audit trail, and create security vulnerabilities that can go undetected for weeks or months.

This is called **infrastructure drift** - and it's one of the leading causes of cloud security breaches.

### What I Built

I designed and built an **end-to-end automated system** that continuously monitors AWS cloud infrastructure, detects unauthorized or accidental changes, classifies them by risk level, and alerts the security team - all without human intervention.

When a critical change is detected (like someone opening SSH access to the internet), the system:
1. **Automatically opens a security ticket** (GitHub Issue) with full details
2. **Sends an alert** to the team via email or Slack
3. **Logs the event** to a permanent audit database for compliance
4. **Enables one-click remediation** - an engineer reviews the proposed fix and approves it, and the system automatically restores the intended state

The entire cycle from detection to remediation can happen in under 10 minutes.

### Why This Matters to a Business

| Business Risk | How This System Addresses It |
|---------------|------------------------------|
| Security breaches from misconfigured infrastructure | Detects misconfigurations within 6 hours (or on-demand in seconds) |
| Compliance violations (SOC 2, ISO 27001, PCI-DSS) | Permanent audit log of every infrastructure change with timestamps |
| Manual remediation taking hours or days | Automated fix pipeline with human approval gate - minutes, not hours |
| No visibility into what changed and when | Full before/after diff stored in database, searchable at any time |
| Junior engineers making undocumented changes | Every change is detected, classified, and logged regardless of who made it |

### What This Demonstrates About Me as an Engineer

- **I build for production, not demos** - this system handles real edge cases: concurrent state locks, IAM permission boundaries, large payload limits, cross-platform tooling differences
- **I think about security at every layer** - no long-lived credentials anywhere, least-privilege IAM throughout, human approval gates before any automated changes to production
- **I balance automation with safety** - the system detects and alerts automatically, but requires human sign-off before fixing anything, because automated deletes without review cause outages
- **I document and explain my decisions** - every architectural choice in this project has a written rationale

---

## 🎯 Key Accomplishments

- ✅ Built a **fully automated drift detection pipeline** running every 6 hours and on-demand
- ✅ Implemented **severity-based classification** (CRITICAL / HIGH / MEDIUM / LOW) with custom rules per resource type
- ✅ Integrated **4 AWS services** (Lambda, DynamoDB, SNS, CloudWatch) into a cohesive observability pipeline
- ✅ Designed **zero-credential CI/CD** using AWS OIDC federation - no static access keys anywhere in the pipeline
- ✅ Built a **human-gated remediation workflow** that shows engineers exactly what will change before applying anything
- ✅ Created a **90-day audit trail** in DynamoDB queryable by severity, resource type, and time range
- ✅ Validated the full end-to-end flow with **4 real drift scenarios** (open firewall, changed encryption, disabled security settings, IAM privilege escalation)
- ✅ Implemented **duplicate issue guard** - prevents repeated remediation triggers when drift persists across scheduled runs

---

## 🏗️ System Architecture

```
GitHub Actions (every 6 hours + on-demand)
    │
    ├── terraform plan → compares real AWS state vs. intended code
    │       │
    │       ├── No changes → ✅ Infrastructure is clean
    │       └── Changes detected → 🚨 Drift found
    │               │
    │               └── Lambda function (drift-parser)
    │                       ├── Identifies what changed and how
    │                       ├── Assigns risk level (CRITICAL / HIGH / MEDIUM / LOW)
    │                       ├── Stores event in audit database (DynamoDB)
    │                       ├── Sends alert email + optional Slack message
    │                       ├── Updates security metrics dashboard
    │                       └── Opens GitHub Issue for CRITICAL findings
    │
    └── Remediation workflow (triggered by engineer approval)
            ├── Shows engineer exactly what will be fixed (plan preview)
            ├── Waits for explicit human approval
            ├── Applies the fix automatically after approval
            └── Closes the ticket + records remediation in audit log
```

### Drift Issue Lifecycle

```
drift-detection.yml detects drift
    │
    ├── Open drift issue already exists for this env?
    │       ├── YES → add comment "drift still present" → skip (remediation already in progress)
    │       └── NO  → create new issue with drift/env labels
    │                       │
    │                       └── Add "auto-remediate" label (via PAT_TOKEN)
    │                               │
    │                               └── Triggers auto-remediate.yml via on: issues: [labeled]
```

> **Why a PAT for the label step?** GitHub Actions' default `GITHUB_TOKEN` cannot trigger other workflows via issue label events - it's a platform restriction to prevent accidental infinite loops. A Personal Access Token with `repo` scope bypasses this limitation, allowing the `auto-remediate` label to reliably fire the remediation workflow.

---

## 🔍 Risk Classification Engine

The system automatically categorizes each detected change:

| Risk Level | What Triggers It | Example |
|------------|-----------------|---------|
| 🔴 **CRITICAL** | IAM policy changes, open firewall rules, modified encryption, public storage access | Port 22 open to the entire internet |
| 🟠 **HIGH** | Server size changes, database class changes | Production server downgraded to smaller instance |
| 🟡 **MEDIUM** | Any meaningful configuration change not matching above rules | Lambda function timeout modified |
| 🟢 **LOW** | Labels, descriptions, non-security metadata | Resource name tag changed |

CRITICAL findings automatically open a GitHub Issue and trigger alerts. All findings are logged regardless of severity.

---

## 📁 Repository Structure

```
aws-DriftDetection-Remediation/
├── rootTerraformCode/              # Infrastructure entry point
│   ├── main.tf                     # Module orchestration
│   ├── variables.tf                # Input variables with validation
│   ├── outputs.tf                  # Key outputs (ARNs, URLs, etc.)
│   └── backend.tf                  # Remote state config (S3 + DynamoDB)
│
├── modules/
│   ├── state-backend/              # Terraform remote state bootstrap
│   ├── monitored-infra/            # Target resources (SG, S3, IAM role)
│   ├── drift-detection/            # Lambda, EventBridge, DynamoDB, OIDC role
│   ├── notifications/              # SNS topic + email subscription
│   └── dashboard-Cloudwatch/       # CloudWatch dashboard + metric alarms
│
├── lambda/
│   └── handler.py                  # Drift parser, classifier, DynamoDB writer
│
├── .github/workflows/
│   ├── drift-detection.yml         # Scheduled detection + issue creation
│   └── auto-remediate.yml          # Human-gated terraform apply
│
└── scripts/
    ├── simulate_drift.py           # Inject real drift for demos
    ├── bootstrap.sh / .ps1         # Backend bootstrap (cross-platform)
    ├── query_drift.py              # Query drift history from DynamoDB
    └── requirements.txt            # Python dependencies
```

---

## 🚀 Deployment Guide

### Prerequisites

- AWS account with permissions to create IAM roles, Lambda, DynamoDB, S3, SNS, CloudWatch
- Terraform >= 1.7
- Python 3.12+
- GitHub repository with Actions enabled
- AWS CLI configured locally

### Step 1 - Bootstrap Remote State

```bash
git clone https://github.com/Xav519/aws-DriftDetection-Remediation
cd aws-DriftDetection-Remediation
aws configure

# For Linux / MacOS
chmod +x ./scripts/bootstrap.sh
./scripts/bootstrap.sh

# For Windows
./scripts/bootstrap.ps1
```

### Step 2 - Configure Variables

```bash
# Edit at minimum: alert_email
# For Linux / MacOS
cp terraform.tfvars.example terraform.tfvars

# For Windows
copy terraform.tfvars.example terraform.tfvars
```

### Step 3 - Deploy Infrastructure

```bash
cd rootTerraformCode
terraform apply -var="environment=dev" -var="alert_email=your@email.com"
```

### Step 4 - Create a Personal Access Token (PAT)

The remediation trigger relies on a PAT to add the `auto-remediate` label to issues. GitHub's default `GITHUB_TOKEN` cannot fire workflow triggers from within a workflow run - a PAT with `repo` scope is required.

**4a. Generate the token**

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Click **Generate new token (classic)**
3. Set a descriptive name: e.g. `drift-detection-workflow-trigger`
4. Set expiration to your preference (90 days recommended, renew as needed)
5. Under **Select scopes**, check **`repo`** (full control of private repositories)
6. Click **Generate token** and **copy the value immediately** - it won't be shown again

> **Scope note:** The `repo` scope is required because the workflow needs to add labels to issues in your repository. For public repositories, `public_repo` is sufficient.

**4b. Add the PAT as a repository secret**

1. In your repository, go to **Settings → Secrets and variables → Actions**
2. Click **New repository secret**
3. Name: `PAT_TOKEN`
4. Value: paste the token you copied above
5. Click **Add secret**

This secret is referenced in `drift-detection.yml` as `${{ secrets.PAT_TOKEN }}` in the label-adding step.

### Step 5 - Configure GitHub Secrets

After `terraform apply`, add these to your GitHub repo (**Settings → Secrets → Actions**):

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | Output of `terraform output github_actions_role_arn` |
| `TF_STATE_BUCKET` | Your S3 state bucket name |
| `TF_LOCK_TABLE` | Your DynamoDB lock table name |
| `ALERT_EMAIL` | Your notification email |
| `SLACK_WEBHOOK_URL` | Optional Slack webhook |
| `PAT_TOKEN` | Personal Access Token from Step 4 |

### Step 6 - Create Approval Environment

**Settings → Environments → New environment** → name it `remediation` → add yourself as required reviewer.

This is the human approval gate that prevents automated remediation from running without sign-off.

---

## 🧪 Running a Drift Simulation

```bash
cd ..\scripts
pip install -r requirements.txt

# For Linux / MacOS
export SG_ID=$(cd ../rootTerraformCode && terraform output -raw monitored_sg_id)
export S3_BUCKET=$(cd ../rootTerraformCode && terraform output -raw monitored_s3_bucket)
export IAM_ROLE_NAME=$(cd ../rootTerraformCode && terraform output -raw monitored_iam_role_name)

# For Windows
$env:SG_ID=$(cd ../rootTerraformCode && terraform output -raw monitored_sg_id)
$env:S3_BUCKET=$(cd ../rootTerraformCode && terraform output -raw monitored_s3_bucket)
$env:IAM_ROLE_NAME=$(cd ../rootTerraformCode && terraform output -raw monitored_iam_role_name)

# Inject drift
cd ../scripts
python simulate_drift.py --scenario sg_open_ssh
python simulate_drift.py --scenario s3_change_encryption
python simulate_drift.py --scenario s3_public_access
python simulate_drift.py --scenario iam_escalate_privileges
python simulate_drift.py --scenario all

# Trigger detection immediately
gh workflow run drift-detection.yml -f environment=dev
gh run watch

# Restore desired state
python simulate_drift.py --restore
```

### Available Scenarios

| Scenario | Severity | What It Does |
|----------|----------|--------------|
| `sg_open_ssh` | CRITICAL | Opens port 22 to `0.0.0.0/0` on the Security Group |
| `s3_change_encryption` | CRITICAL | Changes S3 encryption from AES256 to aws:kms |
| `s3_public_access` | CRITICAL | Disables all S3 public access block settings |
| `iam_escalate_privileges` | CRITICAL | Attaches `AdministratorAccess` to monitored IAM role |
| `all` | - | Runs all scenarios simultaneously |

---

## 🔁 Remediation Workflow

### Via GitHub Issue Label (Automatic)

1. Drift detected → issue `🚨 CRITICAL DRIFT - dev` opens automatically
2. `drift-detection.yml` adds the `auto-remediate` label (via `PAT_TOKEN`)
3. `auto-remediate.yml` triggers and **pauses for approval**
4. Review the Terraform plan in the workflow summary
5. Click **Approve** in the GitHub Environment gate
6. `terraform apply` fixes all drift → issue closes with audit comment

If drift is still present on a subsequent scheduled run and the issue is already open, a comment is added to the existing issue instead of opening a duplicate - preventing repeated remediation triggers while the first one is in progress.

### Manual Trigger

```bash
gh workflow run auto-remediate.yml -f environment=dev -f dry_run=false
```

Use `dry_run=true` to preview the fix without applying.

---

## 📊 Querying Drift History

```bash
# Last 24 hours
python ../scripts/query_drift.py --days 1

# Last 5 events
python ../scripts/query_drift.py --limit 5

# CloudWatch dashboard URL
cd rootTerraformCode
terraform output cloudwatch_dashboard_url
```

---

## 🔐 Security Design Decisions

### No Static AWS Credentials Anywhere

GitHub Actions authenticates to AWS via **OIDC federation** - short-lived tokens scoped to a single workflow run. No access keys to rotate, leak, or phish. The IAM trust policy restricts role assumption to your specific repository only.

### Human Approval Gate Before Every Apply

Automated remediation of a `delete` change on a production resource can cause an outage. The gate is intentional - the system is designed to **detect fast, remediate carefully**. An engineer always sees exactly what will change before it happens.

### PAT Token Scoped to Workflow Triggering Only

The `PAT_TOKEN` secret is used in exactly one place: adding the `auto-remediate` label to a newly created drift issue. It is not used for any other GitHub API operation. The `repo` scope is the minimum required for label management on private repositories.

### DynamoDB as Audit Log

Every drift event is stored with full before/after diffs, severity classification, timestamps, and a 90-day TTL. The table has a Global Secondary Index on severity for fast queries across environments. This supports compliance reporting independently of application logs.

### Duplicate Issue Guard

The detection workflow checks for an existing open drift issue before creating a new one. If one already exists, it comments on it rather than opening a duplicate. This prevents the 6-hour schedule from spawning multiple concurrent remediation runs for the same drift event.

### \"ignore_changes\" on Four Internal Resources

Two resources use `lifecycle { ignore_changes = [...] }`:

- **Lambda zip hash** - Windows and Linux zip tools produce different binary outputs from identical source code. The Lambda code is identical; only zip metadata differs. This is a cross-platform tooling artifact, not real drift.
- **`github_actions_permissions` IAM role policy** - AWS stores policy action arrays in a different order than Terraform's JSON serializer produces. Effective permissions are identical; only serialization order differs.
- **`github_actions_permissions` policy document (data source)** - Same serialization mismatch as above; the data source used to generate the policy triggers spurious drift for the same reason.
- **`github_actions_remediate` IAM role policy** - Identical serialization issue on the remediation role's policy.

All four exclusions apply only to the drift-detection system's own internal resources. All monitored target infrastructure has zero exclusions.

---

## 🛠️ Technical Stack

| Layer | Technology |
|-------|-----------|
| Infrastructure as Code | Terraform 1.7.5, 5 modules, 38+ resources |
| Cloud | AWS (Lambda, DynamoDB, S3, SNS, CloudWatch, EventBridge, IAM) |
| CI/CD | GitHub Actions with OIDC, environment gates, workflow outputs |
| Runtime | Python 3.12 on AWS Lambda |
| State Management | S3 remote backend + DynamoDB locking |
| Security | OIDC federation, least-privilege IAM, encrypted state, PAT-scoped workflow triggers |

---

## 👤 Author

**Xavier Dupuis**  
Cybersecurity Advisor - Banque Nationale du Canada  
B.Eng. Cybersecurity Engineering - École Polytechnique de Montréal (Graduating 2026)  

**Certifications:** AWS Security Specialty · AWS Solutions Architect Associate · AWS Cloud Practitioner · CompTIA Security+ · CompTIA Network+

[![GitHub](https://img.shields.io/badge/GitHub-Xav519-181717?logo=github)](https://github.com/Xav519)

---

<p align="center">
  <b>Let's build something secure.</b><br>
  <a href="https://www.linkedin.com/in/xavierdupuis/">LinkedIn</a>
</p>
