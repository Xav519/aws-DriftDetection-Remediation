#!/usr/bin/env python3
"""
Drift History Query Tool
=========================
Query the DynamoDB drift event log and display formatted reports.

Usage:
    python query_drift.py                          # Show all events last 7 days
    python query_drift.py --severity CRITICAL      # Filter by severity
    python query_drift.py --days 30                # Last 30 days
    python query_drift.py --resource "aws_security_group"  # Filter by resource type
    python query_drift.py --export drift_report.json
"""

import os
import json
import boto3
import click
from datetime import datetime, timezone, timedelta
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich import box
from boto3.dynamodb.conditions import Key, Attr

console = Console()

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
DRIFT_TABLE = os.environ.get("DRIFT_TABLE", "drift-events")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)


def query_drift_events(
    days: int = 7,
    severity: str | None = None,
    resource_filter: str | None = None,
) -> list[dict]:
    table = dynamodb.Table(DRIFT_TABLE)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()

    if severity:
        response = table.query(
            IndexName="SeverityIndex",
            KeyConditionExpression=Key("severity").eq(severity) & Key("detected_at").gte(cutoff),
        )
        items = response.get("Items", [])
    else:
        response = table.scan(
            FilterExpression=Attr("detected_at").gte(cutoff)
        )
        items = response.get("Items", [])

    if resource_filter:
        items = [i for i in items if resource_filter in i.get("resource_type", "")]

    return sorted(items, key=lambda x: x.get("detected_at", ""), reverse=True)


def print_drift_table(events: list[dict]) -> None:
    SEVERITY_STYLES = {
        "CRITICAL": "bold red",
        "HIGH": "bold yellow",
        "MEDIUM": "yellow",
        "LOW": "dim",
    }

    table = Table(
        title=f"Drift Events ({len(events)} total)",
        box=box.ROUNDED,
        show_lines=True,
    )
    table.add_column("Detected At", style="cyan", width=22)
    table.add_column("Severity", width=10)
    table.add_column("Resource", width=40)
    table.add_column("Change Type", width=10)
    table.add_column("Environment", width=12)

    for e in events:
        sev = e.get("severity", "LOW")
        table.add_row(
            e.get("detected_at", "")[:19].replace("T", " "),
            f"[{SEVERITY_STYLES.get(sev, '')}]{sev}[/]",
            e.get("resource_address", ""),
            e.get("change_type", ""),
            e.get("environment", ""),
        )

    console.print(table)


def print_summary(events: list[dict]) -> None:
    from collections import Counter
    by_severity = Counter(e.get("severity") for e in events)
    by_type = Counter(e.get("change_type") for e in events)

    console.print(Panel(
        f"[bold]Total events:[/bold] {len(events)}\n"
        f"[bold red]Critical:[/bold red]  {by_severity.get('CRITICAL', 0)}\n"
        f"[bold yellow]High:[/bold yellow]      {by_severity.get('HIGH', 0)}\n"
        f"[yellow]Medium:[/yellow]    {by_severity.get('MEDIUM', 0)}\n"
        f"[dim]Low:[/dim]       {by_severity.get('LOW', 0)}\n\n"
        f"[bold]By change type:[/bold]\n"
        + "\n".join(f"  {k}: {v}" for k, v in by_type.most_common()),
        title="Drift Summary",
        border_style="cyan",
    ))


@click.command()
@click.option("--days", "-d", default=7, help="Number of days to look back")
@click.option("--severity", "-s", type=click.Choice(["CRITICAL", "HIGH", "MEDIUM", "LOW"]), help="Filter by severity")
@click.option("--resource", "-r", default=None, help="Filter by resource type substring")
@click.option("--export", "-e", default=None, help="Export results to JSON file")
def main(days: int, severity: str, resource: str, export: str) -> None:
    """Query and display the drift event history from DynamoDB."""
    console.print(f"[dim]Querying {DRIFT_TABLE} — last {days} days[/dim]\n")

    events = query_drift_events(days=days, severity=severity, resource_filter=resource)

    if not events:
        console.print("[green]No drift events found for the selected filters.[/green]")
        return

    print_summary(events)
    print_drift_table(events)

    if export:
        with open(export, "w") as f:
            json.dump(events, f, indent=2, default=str)
        console.print(f"\n[green]Exported {len(events)} events to {export}[/green]")


if __name__ == "__main__":
    main()
