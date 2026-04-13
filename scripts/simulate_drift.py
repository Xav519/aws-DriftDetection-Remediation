#!/usr/bin/env python3
"""
Drift Simulation Script
========================
Injects real infrastructure drift into the monitored AWS resources.
Each scenario is a standalone function you can run independently.

Usage:
    python simulate_drift.py --scenario sg_open_ssh
    python simulate_drift.py --scenario s3_disable_encryption
    python simulate_drift.py --scenario iam_escalate_privileges
    python simulate_drift.py --scenario all
    python simulate_drift.py --restore   # Undo all simulated drift

Prerequisites:
    pip install boto3 click rich
    AWS credentials configured with write access to monitored resources
    export SG_ID=sg-xxxx
    export S3_BUCKET=drift-detection-dev-monitored-xxxx
    export IAM_ROLE_NAME=drift-detection-dev-monitored-role
"""

import os
import sys
import json
import time
import boto3
import click
from datetime import datetime
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich import box

console = Console()

# Resource IDs - set via env vars or terraform output
SG_ID = os.environ.get("SG_ID", "")
S3_BUCKET = os.environ.get("S3_BUCKET", "")
IAM_ROLE_NAME = os.environ.get("IAM_ROLE_NAME", "")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

ec2 = boto3.client("ec2", region_name=AWS_REGION)
s3 = boto3.client("s3", region_name=AWS_REGION)
iam = boto3.client("iam")


###############################################################################
# Scenario 1 - Open SSH to the world on Security Group
###############################################################################

def scenario_sg_open_ssh(restore: bool = False) -> None:
    """Add/remove 0.0.0.0/0:22 inbound rule on the monitored Security Group."""
    if not SG_ID:
        console.print("[red]SG_ID env var not set. Run: export SG_ID=$(terraform output -raw monitored_sg_id)[/red]")
        sys.exit(1)

    if restore:
        console.print("[yellow]Restoring: removing SSH ingress rule...[/yellow]")
        try:
            ec2.revoke_security_group_ingress(
                GroupId=SG_ID,
                IpPermissions=[{
                    "IpProtocol": "tcp",
                    "FromPort": 22,
                    "ToPort": 22,
                    "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
                }],
            )
            console.print("[green]✓ SSH rule removed - drift restored[/green]")
        except ec2.exceptions.ClientError as e:
            if "InvalidPermission.NotFound" in str(e):
                console.print("[dim]Rule was already absent[/dim]")
            else:
                raise
    else:
        console.print(f"[bold red]INJECTING DRIFT: Opening SSH (port 22) to 0.0.0.0/0 on {SG_ID}[/bold red]")
        ec2.authorize_security_group_ingress(
            GroupId=SG_ID,
            IpPermissions=[{
                "IpProtocol": "tcp",
                "FromPort": 22,
                "ToPort": 22,
                "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "SIMULATED DRIFT - DELETE ME"}],
            }],
        )
        console.print("[red]✓ Drift injected: SSH open to internet - detection should fire within 6h[/red]")
        _log_drift_injection("sg_open_ssh", SG_ID, "CRITICAL")


###############################################################################
# Scenario 2 - Disable S3 encryption
###############################################################################

def scenario_s3_disable_encryption(restore: bool = False) -> None:
    """Remove/restore server-side encryption on the monitored S3 bucket."""
    if not S3_BUCKET:
        console.print("[red]S3_BUCKET env var not set. Run: export S3_BUCKET=$(terraform output -raw monitored_s3_bucket)[/red]")
        sys.exit(1)

    if restore:
        console.print("[yellow]Restoring: re-enabling S3 encryption...[/yellow]")
        s3.put_bucket_encryption(
            Bucket=S3_BUCKET,
            ServerSideEncryptionConfiguration={
                "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
            },
        )
        console.print("[green]✓ S3 encryption restored[/green]")
    else:
        console.print(f"[bold red]INJECTING DRIFT: Removing S3 encryption from {S3_BUCKET}[/bold red]")
        s3.delete_bucket_encryption(Bucket=S3_BUCKET)
        console.print("[red]✓ Drift injected: S3 bucket encryption disabled[/red]")
        _log_drift_injection("s3_disable_encryption", S3_BUCKET, "CRITICAL")


###############################################################################
# Scenario 3 - Disable S3 public access block
###############################################################################

def scenario_s3_public_access(restore: bool = False) -> None:
    """Enable/disable public access on the monitored S3 bucket."""
    if not S3_BUCKET:
        console.print("[red]S3_BUCKET env var not set.[/red]")
        sys.exit(1)

    if restore:
        console.print("[yellow]Restoring: re-enabling S3 public access block...[/yellow]")
        s3.put_public_access_block(
            Bucket=S3_BUCKET,
            PublicAccessBlockConfiguration={
                "BlockPublicAcls": True,
                "IgnorePublicAcls": True,
                "BlockPublicPolicy": True,
                "RestrictPublicBuckets": True,
            },
        )
        console.print("[green]✓ Public access block restored[/green]")
    else:
        console.print(f"[bold red]INJECTING DRIFT: Disabling public access block on {S3_BUCKET}[/bold red]")
        s3.put_public_access_block(
            Bucket=S3_BUCKET,
            PublicAccessBlockConfiguration={
                "BlockPublicAcls": False,
                "IgnorePublicAcls": False,
                "BlockPublicPolicy": False,
                "RestrictPublicBuckets": False,
            },
        )
        console.print("[red]✓ Drift injected: S3 public access block disabled[/red]")
        _log_drift_injection("s3_public_access", S3_BUCKET, "CRITICAL")


###############################################################################
# Scenario 4 - IAM privilege escalation (attach AdministratorAccess)
###############################################################################

def scenario_iam_escalate_privileges(restore: bool = False) -> None:
    """Attach/detach AdministratorAccess policy to the monitored IAM role."""
    if not IAM_ROLE_NAME:
        console.print("[red]IAM_ROLE_NAME env var not set. Run: export IAM_ROLE_NAME=$(terraform output -raw monitored_iam_role_name)[/red]")
        sys.exit(1)

    admin_arn = "arn:aws:iam::aws:policy/AdministratorAccess"

    if restore:
        console.print("[yellow]Restoring: detaching AdministratorAccess...[/yellow]")
        try:
            iam.detach_role_policy(RoleName=IAM_ROLE_NAME, PolicyArn=admin_arn)
            console.print("[green]✓ AdministratorAccess detached[/green]")
        except iam.exceptions.NoSuchEntityException:
            console.print("[dim]Policy was already detached[/dim]")
    else:
        console.print(f"[bold red]INJECTING DRIFT: Attaching AdministratorAccess to {IAM_ROLE_NAME}[/bold red]")
        iam.attach_role_policy(RoleName=IAM_ROLE_NAME, PolicyArn=admin_arn)
        console.print("[red]✓ Drift injected: IAM role now has AdministratorAccess[/red]")
        _log_drift_injection("iam_escalate_privileges", IAM_ROLE_NAME, "CRITICAL")


###############################################################################
# Helpers
###############################################################################

def _log_drift_injection(scenario: str, resource: str, severity: str) -> None:
    """Write a local log entry for tracking injected drift."""
    log_entry = {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "scenario": scenario,
        "resource": resource,
        "severity": severity,
        "note": "Simulated drift - run --restore to undo",
    }
    log_file = ".drift_simulations.json"
    existing = []
    try:
        with open(log_file) as f:
            existing = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        pass

    existing.append(log_entry)
    with open(log_file, "w") as f:
        json.dump(existing, f, indent=2)

    console.print(f"\n[dim]Logged to {log_file}[/dim]")


def _print_status_table() -> None:
    """Print current state of all monitored resources."""
    table = Table(title="Monitored Resource Status", box=box.ROUNDED)
    table.add_column("Resource", style="cyan")
    table.add_column("Type", style="white")
    table.add_column("Status", style="white")

    # Security Group
    if SG_ID:
        try:
            sg = ec2.describe_security_groups(GroupIds=[SG_ID])["SecurityGroups"][0]
            ssh_open = any(
                p["FromPort"] == 22 and any(r["CidrIp"] == "0.0.0.0/0" for r in p.get("IpRanges", []))
                for p in sg.get("IpPermissions", [])
                if p.get("FromPort") == 22
            )
            status = "[red]DRIFTED - SSH open[/red]" if ssh_open else "[green]Clean[/green]"
            table.add_row(SG_ID, "Security Group", status)
        except Exception as e:
            table.add_row(SG_ID, "Security Group", f"[yellow]Error: {e}[/yellow]")

    # S3 Encryption
    if S3_BUCKET:
        try:
            s3.get_bucket_encryption(Bucket=S3_BUCKET)
            table.add_row(S3_BUCKET, "S3 Encryption", "[green]Enabled[/green]")
        except s3.exceptions.ClientError as e:
            if "ServerSideEncryptionConfigurationNotFoundError" in str(e):
                table.add_row(S3_BUCKET, "S3 Encryption", "[red]DRIFTED - Disabled[/red]")
            else:
                table.add_row(S3_BUCKET, "S3 Encryption", f"[yellow]Error[/yellow]")

    # IAM Role
    if IAM_ROLE_NAME:
        try:
            policies = iam.list_attached_role_policies(RoleName=IAM_ROLE_NAME)["AttachedPolicies"]
            admin_attached = any(p["PolicyName"] == "AdministratorAccess" for p in policies)
            status = "[red]DRIFTED - AdministratorAccess attached[/red]" if admin_attached else "[green]Clean[/green]"
            table.add_row(IAM_ROLE_NAME, "IAM Role", status)
        except Exception as e:
            table.add_row(IAM_ROLE_NAME, "IAM Role", f"[yellow]Error: {e}[/yellow]")

    console.print(table)


###############################################################################
# CLI
###############################################################################

SCENARIOS = {
    "sg_open_ssh":              scenario_sg_open_ssh,
    "s3_disable_encryption":    scenario_s3_disable_encryption,
    "s3_public_access":         scenario_s3_public_access,
    "iam_escalate_privileges":  scenario_iam_escalate_privileges,
}


@click.command()
@click.option("--scenario", "-s",
              type=click.Choice(list(SCENARIOS.keys()) + ["all"]),
              help="Drift scenario to inject")
@click.option("--restore", "-r", is_flag=True, help="Undo all simulated drift")
@click.option("--status", is_flag=True, help="Print current resource status without making changes")
def main(scenario: str, restore: bool, status: bool) -> None:
    """
    \b
    Drift Simulation Tool
    Injects or restores real AWS infrastructure drift for demo purposes.
    """
    console.print(Panel.fit(
        "[bold]Drift Simulation Tool[/bold]\n"
        "[dim]Injects real drift into monitored AWS resources[/dim]",
        border_style="red" if not restore else "green",
    ))

    if status:
        _print_status_table()
        return

    if restore:
        console.print("[bold yellow]Restoring all simulated drift...[/bold yellow]\n")
        for name, fn in SCENARIOS.items():
            console.print(f"  → Restoring {name}...")
            try:
                fn(restore=True)
            except Exception as e:
                console.print(f"  [yellow]  Skipped ({e})[/yellow]")
        console.print("\n[green]All scenarios restored.[/green]")
        return

    if not scenario:
        console.print("[red]Error: provide --scenario or --restore. Use --help for usage.[/red]")
        sys.exit(1)

    if scenario == "all":
        console.print("[bold red]Injecting ALL drift scenarios...[/bold red]\n")
        for name, fn in SCENARIOS.items():
            console.print(f"\n→ Running: {name}")
            fn(restore=False)
            time.sleep(1)
    else:
        SCENARIOS[scenario](restore=False)

    console.print("\n[bold]Next steps:[/bold]")
    console.print("  1. Wait for the detection workflow to run (max 6h) OR")
    console.print("  2. Trigger manually: gh workflow run drift-detection.yml")
    console.print("  3. Check GitHub Issues for the drift alert")
    console.print("  4. Run [cyan]python simulate_drift.py --restore[/cyan] to clean up")


if __name__ == "__main__":
    main()
