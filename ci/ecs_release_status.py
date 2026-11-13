#!/usr/bin/env python3
"""Read-only ECS native blue/green release inspection for Slice & Sip.

No AWS writes, no shell commands, no credentials printed. Requires recent AWS CLI.
Return codes: 0 = healthy success or explicitly allowed missing infrastructure;
2 = deploying/not ready; 3 = failed/rolled back; 4 = AWS API error.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
import subprocess
import sys
from typing import Any

ACTIVE_STATES = {"PENDING", "IN_PROGRESS", "STOP_REQUESTED", "ROLLBACK_REQUESTED", "ROLLBACK_IN_PROGRESS"}
FAILED_STATES = {"STOPPED", "ROLLBACK_SUCCESSFUL", "ROLLBACK_FAILED"}


class StatusError(Exception):
    pass


def aws(region: str, *args: str) -> dict[str, Any]:
    """Call only read APIs from the allowlist, without a shell."""
    permitted = {
        ("ecs", "describe-clusters"),
        ("ecs", "describe-services"),
        ("ecs", "list-service-deployments"),
        ("ecs", "describe-service-deployments"),
        ("elbv2", "describe-target-health"),
    }
    if len(args) < 2 or (args[0], args[1]) not in permitted:
        raise StatusError("Refusing non-read-only AWS operation")
    command = ["aws", *args, "--region", region, "--output", "json", "--no-cli-pager"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=40)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise StatusError(f"Unable to execute AWS CLI: {type(exc).__name__}") from exc
    if result.returncode:
        # AWS errors sometimes contain resource names; never log credential-bearing arguments.
        reason = result.stderr.strip().splitlines()[-1:] or ["Unknown AWS API error"]
        raise StatusError(f"{args[0]} {args[1]} failed: {reason[0][:300]}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise StatusError("AWS CLI returned invalid JSON") from exc


def unique_target_groups(service: dict[str, Any]) -> list[str]:
    groups: list[str] = []
    for lb in service.get("loadBalancers", []):
        for arn in (lb.get("targetGroupArn"), (lb.get("advancedConfiguration") or {}).get("alternateTargetGroupArn")):
            if arn and arn not in groups:
                groups.append(arn)
    return groups


def target_health(region: str, target_group_arn: str) -> Counter:
    data = aws(region, "elbv2", "describe-target-health", "--target-group-arn", target_group_arn)
    return Counter(x.get("TargetHealth", {}).get("State", "unknown") for x in data.get("TargetHealthDescriptions", []))


def run(region: str, cluster: str, name: str, allow_missing: bool = False) -> int:
    clusters = aws(region, "ecs", "describe-clusters", "--clusters", cluster)
    matches = [c for c in clusters.get("clusters", []) if c.get("clusterName") == cluster and c.get("status") == "ACTIVE"]
    if not matches:
        print(f"NOT DEPLOYED: ECS cluster {cluster} is not ACTIVE. No live deployment has been verified.")
        return 0 if allow_missing else 2

    response = aws(region, "ecs", "describe-services", "--cluster", cluster, "--services", name)
    services = [s for s in response.get("services", []) if s.get("serviceName") == name and s.get("status") == "ACTIVE"]
    if not services:
        print(f"NOT DEPLOYED: ECS service {name} is not ACTIVE. No live deployment has been verified.")
        return 0 if allow_missing else 2

    service = services[0]
    desired = service.get("desiredCount", 0)
    running = service.get("runningCount", 0)
    pending = service.get("pendingCount", 0)
    strategy = service.get("deploymentConfiguration", {}).get("strategy")
    print(f"ECS service: {cluster}/{name}")
    print(f"Strategy: {strategy or 'not reported'} | desired={desired}, running={running}, pending={pending}")
    if strategy != "BLUE_GREEN":
        print("NOT VERIFIED: expected native BLUE_GREEN deployment strategy")
        return 2

    history = aws(region, "ecs", "list-service-deployments", "--cluster", cluster, "--service", name, "--max-results", "10")
    summaries = history.get("serviceDeployments", [])
    if not summaries:
        print("NOT VERIFIED: no ECS service deployments returned")
        return 2
    latest = max(summaries, key=lambda d: str(d.get("createdAt", "")))
    arn = latest.get("serviceDeploymentArn")
    if not arn:
        raise StatusError("Latest service deployment has no ARN")
    details = aws(region, "ecs", "describe-service-deployments", "--service-deployment-arns", arn)
    entries = details.get("serviceDeployments", [])
    if not entries:
        raise StatusError("Deployment details unavailable")
    deployment = entries[0]
    state = deployment.get("status", "UNKNOWN")
    print(f"Latest deployment: {arn}")
    print(f"Deployment status: {state} | lifecycle: {deployment.get('lifecycleStage', 'unknown')}")
    if deployment.get("statusReason"):
        print(f"Reason: {str(deployment['statusReason'])[:250]}")
    rollback = deployment.get("rollback") or {}
    if rollback.get("reason"):
        print(f"Rollback: {str(rollback['reason'])[:250]}")

    # Observe both target groups. During a healthy blue/green rollout the inactive
    # group may have zero targets; do not misclassify that as a production outage.
    groups = unique_target_groups(service)
    healthy_any = False
    if not groups:
        print("WARNING: no ALB target groups found; cannot verify target health")
    for index, group in enumerate(groups, 1):
        counts = target_health(region, group)
        healthy_any |= counts.get("healthy", 0) > 0
        description = ", ".join(f"{key}={counts[key]}" for key in sorted(counts)) or "no targets"
        print(f"Target group {index}: {group} | {description}")

    if state in FAILED_STATES:
        print("ATTENTION: latest deployment was stopped or rolled back. Inspect before any new release.")
        return 3
    if state in ACTIVE_STATES:
        print("IN PROGRESS: deployment is not yet complete. Do not assume production is healthy.")
        return 2
    if state != "SUCCESSFUL":
        print("NOT VERIFIED: unrecognized deployment status")
        return 2
    if desired < 1 or running < desired or pending:
        print("NOT READY: ECS service task counts are not stable")
        return 2
    if not groups or not healthy_any:
        print("NOT VERIFIED: no healthy ALB targets observed")
        return 2
    print("ECS deployment successful and running tasks have healthy ALB targets.")
    print("NOTE: This check does NOT prove which target group serves production traffic or test HTTP /ready.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", default="eu-west-1")
    parser.add_argument("--cluster", default="slice-sip-ecs")
    parser.add_argument("--service", default="slice-sip-app")
    parser.add_argument("--allow-missing", action="store_true", help="Allow pre-provisioning inspection to exit 0")
    args = parser.parse_args(argv)
    try:
        return run(args.region, args.cluster, args.service, args.allow_missing)
    except StatusError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(main())
