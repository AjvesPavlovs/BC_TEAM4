#!/usr/bin/env python3
"""Guarded ECS Fargate deploy helper for Slice & Sip.

Preview is the default and performs AWS read operations only. A real deployment
requires --deploy and is intended to be invoked by ansible/ecs-deploy.yml.
This script embeds no AWS credentials; the AWS CLI uses its normal credential chain.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from typing import Any

TAG_PATTERN = re.compile(r"^[0-9a-f]{40}-[1-9][0-9]*$")
REGISTRABLE_KEYS = (
    "family", "taskRoleArn", "executionRoleArn", "networkMode", "containerDefinitions",
    "volumes", "placementConstraints", "requiresCompatibilities", "cpu", "memory",
    "tags", "pidMode", "ipcMode", "proxyConfiguration", "inferenceAccelerators",
    "ephemeralStorage", "runtimePlatform", "enableFaultInjection",
)


class DeploymentError(Exception):
    pass


def aws(region: str, *args: str) -> dict[str, Any]:
    """Run AWS CLI without shell interpolation; parse its JSON response."""
    result = subprocess.run(
        ["aws", *args, "--region", region, "--output", "json"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    if result.returncode:
        message = result.stderr.strip().splitlines()[-1:] or ["AWS CLI error"]
        raise DeploymentError(f"{' '.join(args[:2])}: {message[0]}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise DeploymentError(f"AWS CLI did not return valid JSON for {args[:2]}") from exc


def run_aws(region: str, *args: str) -> None:
    """Run AWS command that may be silent (e.g. waiter)."""
    result = subprocess.run(["aws", *args, "--region", region], check=False)
    if result.returncode:
        raise DeploymentError(f"AWS command {' '.join(args[:2])} failed (exit {result.returncode})")


def register_payload(current: dict[str, Any], images: dict[str, str]) -> dict[str, Any]:
    """Carry forward supported task attributes and replace ONLY chosen images."""
    payload = {key: current[key] for key in REGISTRABLE_KEYS if key in current}
    payload["containerDefinitions"] = [dict(container) for container in current["containerDefinitions"]]
    seen = set()
    for container in payload["containerDefinitions"]:
        if container["name"] in images:
            container["image"] = images[container["name"]]
            seen.add(container["name"])
    missing = set(images) - seen
    if missing:
        raise DeploymentError(f"Expected container names not found: {', '.join(sorted(missing))}")
    return payload


def write_private_json(payload: dict[str, Any]) -> str:
    fd, path = tempfile.mkstemp(prefix="slice-sip-ecs-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream)
        os.chmod(path, 0o600)
        return path
    except Exception:
        os.unlink(path)
        raise


def get_ecr_images(region: str, project: str, tag: str) -> dict[str, str]:
    images: dict[str, str] = {}
    for component in ("frontend", "backend"):
        repository = f"{project}-{component}"
        repo = aws(region, "ecr", "describe-repositories", "--repository-names", repository)
        entries = repo.get("repositories", [])
        if len(entries) != 1:
            raise DeploymentError(f"Expected one ECR repository named {repository}")
        image = aws(region, "ecr", "describe-images", "--repository-name", repository,
                    "--image-ids", f"imageTag={tag}")
        if not image.get("imageDetails"):
            raise DeploymentError(f"Image tag {tag} missing from {repository}")
        images[component] = f"{entries[0]['repositoryUri']}:{tag}"
        print(f"ECR verified: {repository} tag {tag}")
    return images


def get_service(region: str, cluster: str, name: str) -> dict[str, Any] | None:
    data = aws(region, "ecs", "describe-services", "--cluster", cluster, "--services", name)
    matches = [service for service in data.get("services", []) if service.get("serviceName") == name]
    if not matches or matches[0].get("status") != "ACTIVE":
        return None
    return matches[0]


def update_service(
    region: str, cluster: str, name: str, images: dict[str, str], deploy: bool,
) -> None:
    service = get_service(region, cluster, name)
    if service is None:
        print(f"NOT READY: ECS service {name} has not been provisioned")
        if deploy:
            raise DeploymentError(f"ECS service {name} does not exist or is not active")
        return

    if name.endswith("-app"):
        strategy = service.get("deploymentConfiguration", {}).get("strategy")
        if strategy != "BLUE_GREEN":
            print(f"NOT VERIFIED: service {name} strategy was {strategy!r}; requires BLUE_GREEN")
            if deploy:
                raise DeploymentError("ECS BLUE_GREEN not confirmed: check service and update AWS CLI")

    task_arn = service["taskDefinition"]
    current = aws(region, "ecs", "describe-task-definition", "--task-definition", task_arn)["taskDefinition"]
    payload = register_payload(current, images)
    original = {container["name"]: container["image"] for container in current["containerDefinitions"]}
    updated = {container["name"]: container["image"] for container in payload["containerDefinitions"]}
    if all(original[key] == updated[key] for key in images):
        print(f"UNCHANGED: {name} already uses the requested images")
        return

    print(f"{'DEPLOY' if deploy else 'PREVIEW'}: {name}: register revision of {current['family']}")
    for container in sorted(images):
        print(f"  {container}: {original.get(container, '<missing>')} -> {updated[container]}")
    if not deploy:
        return

    # The task definition may contain sensitive environment entries inherited
    # from ECS. Never print the JSON, store it with mode 0600, and delete it.
    file_path = write_private_json(payload)
    try:
        registered = aws(region, "ecs", "register-task-definition", "--cli-input-json", f"file://{file_path}")
    finally:
        os.unlink(file_path)
    new_arn = registered["taskDefinition"]["taskDefinitionArn"]
    aws(region, "ecs", "update-service", "--cluster", cluster, "--service", name,
        "--task-definition", new_arn)
    print(f"Requested ECS deployment: {name} -> {new_arn}")
    run_aws(region, "ecs", "wait", "services-stable", "--cluster", cluster, "--services", name)
    after = get_service(region, cluster, name)
    if not after or after.get("taskDefinition") != new_arn:
        raise DeploymentError(f"{name} did not report the intended task-definition revision")
    if after.get("runningCount", -1) < after.get("desiredCount", 0):
        raise DeploymentError(f"{name} has fewer running tasks than desired")
    print(f"ECS service stabilized: {name}; validate ALB /ready and deployment events")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", default="eu-west-1")
    parser.add_argument("--project", default="slice-sip")
    parser.add_argument("--tag", required=True, help="Immutable tag: 40-character SHA + pipeline number")
    parser.add_argument("--deploy", action="store_true", help="Opt in to AWS writes")
    parser.add_argument("--include-worker", action="store_true", help="Also update rolling notification service")
    args = parser.parse_args(argv)
    if not TAG_PATTERN.fullmatch(args.tag):
        raise DeploymentError("Invalid tag: expected lowercase 40-character git SHA and -pipelineNumber")

    identity = aws(args.region, "sts", "get-caller-identity")
    print("Identity type:", identity.get("Arn", "unknown").split(":")[-1].split("/")[0])
    images = get_ecr_images(args.region, args.project, args.tag)
    cluster = f"{args.project}-ecs"
    try:
        clusters = aws(args.region, "ecs", "describe-clusters", "--clusters", cluster)
    except DeploymentError:
        if args.deploy:
            raise
        print("ECS cluster could not be inspected with current IAM role; deployment disabled")
        return 0
    active = [c for c in clusters.get("clusters", []) if c.get("clusterName") == cluster and c.get("status") == "ACTIVE"]
    if not active:
        print(f"NOT READY: {cluster} is not deployed yet. This is expected while IAM approval is pending.")
        if args.deploy:
            raise DeploymentError("Cannot deploy before Terraform provisions ECS")
        return 0

    app_images = {"frontend": images["frontend"], "backend": images["backend"]}
    update_service(args.region, cluster, f"{args.project}-app", app_images, args.deploy)
    if args.include_worker:
        worker_images = {"outbox": images["backend"], "discord": images["backend"]}
        update_service(args.region, cluster, f"{args.project}-notifications", worker_images, args.deploy)
    if not args.deploy:
        print("READ-ONLY PREVIEW COMPLETE: No AWS resources were modified")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DeploymentError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(2)
