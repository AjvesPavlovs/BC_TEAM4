#!/usr/bin/env python3
"""Host-side Slice & Sip release handoff. Preview is the default.

Works from a root-owned installed copy on EC2. No service/timer or pipeline
integration is installed by this patch. Live mode is deliberately triple-gated.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any

from woodpecker_release_candidate import CandidateError, find_candidate, read_token

ROOT = Path(__file__).resolve().parent.parent
PLAYBOOK = ROOT / "ansible/ecs-deploy.yml"
STATUS_SCRIPT = ROOT / "ci/ecs_release_status.py"
LOCK = Path("/run/lock/slice-sip-release-controller.lock")
STATE = Path("/var/lib/slice-sip-ci/release-controller.json")
LIVE_GATE = Path("/etc/slice-sip-ci/enable-ecs-deploy")
TAG = re.compile(r"^[0-9a-f]{40}-[1-9][0-9]*$")
ALLOW_WORD = "ENABLE_LIVE_DEPLOYMENT"
APPROVAL = "DEPLOY_SLICE_SIP"


class ReleaseError(Exception):
    pass


def validate_candidate(pipeline: dict[str, Any], image_tag: str) -> int:
    number = pipeline.get("number")
    if type(number) is not int or number <= 0 or not TAG.fullmatch(image_tag):
        raise ReleaseError("Invalid Woodpecker release candidate")
    if not image_tag.endswith(f"-{number}"):
        raise ReleaseError("Pipeline number does not match immutable image tag")
    return number


@contextmanager
def exclusive_lock(path: Path = LOCK):
    try:
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if info.st_uid != 0 or info.st_mode & 0o077 or not stat.S_ISREG(info.st_mode):
                raise ReleaseError("Release lock must be a root-owned private regular file")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ReleaseError("Another Slice & Sip release check/deployment is running") from exc
            try:
                yield
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
    except OSError as exc:
        raise ReleaseError("Cannot obtain protected release lock") from exc


def load_state(path: Path = STATE) -> dict[str, Any]:
    if not path.exists() and not path.is_symlink():
        return {"version": 1, "last_attempt": None}
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
            raise ReleaseError("Release state must be a root-owned private regular file")
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        raise ReleaseError("Release state is unreadable or malformed") from exc
    if not isinstance(state, dict) or state.get("version") != 1:
        raise ReleaseError("Unsupported release state schema")
    attempt = state.get("last_attempt")
    if attempt is not None and (not isinstance(attempt, dict) or type(attempt.get("number")) is not int
                                or attempt["number"] <= 0 or attempt.get("status") not in
                                {"started", "awaiting_verification", "failed_requires_review"}):
        raise ReleaseError("Invalid release attempt in state; review manually")
    return state


def write_state(data: dict[str, Any], path: Path = STATE) -> None:
    directory = path.parent
    if directory.is_symlink():
        raise ReleaseError("Refusing symlinked release state directory")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.stat()
    if info.st_uid != 0 or info.st_mode & 0o077:
        raise ReleaseError("Release state directory must be root-owned and private")
    fd, temp_path = tempfile.mkstemp(prefix=".release-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump(data, file, sort_keys=True, indent=2)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def check_live_gate(path: Path = LIVE_GATE) -> None:
    try:
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077
                or path.read_text(encoding="utf-8").strip() != ALLOW_WORD):
            raise ReleaseError("Live deployment gate is not a valid root-owned 0600 approval file")
    except OSError as exc:
        raise ReleaseError("Live deployment disabled: protected approval file is absent") from exc


def run_process(command: list[str], *, timeout: int) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["PATH"] = "/opt/slice-sip/bin:/usr/local/bin:/usr/bin:/bin"
    env["ANSIBLE_NOCOLOR"] = "1"
    try:
        return subprocess.run(command, text=True, capture_output=True, check=False, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ReleaseError(f"Release command could not complete ({type(exc).__name__})") from exc


def ansible_command(tag: str, *, deploy: bool) -> list[str]:
    cmd = ["ansible-playbook", "-i", "localhost,", "-c", "local", str(PLAYBOOK),
           "-e", f"image_tag={tag}"]
    if deploy:
        cmd.extend(["-e", "deploy_enabled=true", "-e", f"deploy_confirmation={APPROVAL}"])
    return cmd


def classify_preview(result: subprocess.CompletedProcess, tag: str) -> str:
    output = result.stdout
    if result.returncode:
        raise ReleaseError("Ansible preflight failed; inspect it manually (no deployment requested)")
    if (f"ECR verified: slice-sip-frontend tag {tag}" not in output
            or f"ECR verified: slice-sip-backend tag {tag}" not in output):
        raise ReleaseError("Ansible did not verify both expected ECR images")
    if "NOT READY:" in output or "NOT VERIFIED:" in output:
        return "not_ready"
    if "READ-ONLY PREVIEW COMPLETE" not in output:
        raise ReleaseError("Ansible did not confirm a complete read-only preflight")
    return "ready"


def healthy_service() -> bool:
    result = run_process(["python3", str(STATUS_SCRIPT), "--region", "eu-west-1",
                          "--cluster", "slice-sip-ecs", "--service", "slice-sip-app"], timeout=180)
    # The status helper's exit code is fail-closed: it must *not* use --allow-missing.
    return result.returncode == 0 and "ECS deployment successful" in result.stdout


def determine_decision(candidate_number: int, state: dict[str, Any]) -> str:
    previous = state.get("last_attempt")
    if previous is None:
        return "new"
    if previous["status"] in {"started", "awaiting_verification", "failed_requires_review"}:
        return "blocked_previous_attempt_requires_manual_review"
    if previous["number"] >= candidate_number:
        return "already_requested"
    return "new"


def release(preview: bool, expected_tag: str | None = None,
            confirm: str | None = None) -> int:
    if os.geteuid() != 0:
        raise ReleaseError("Run the installed, root-owned controller as root on EC2")
    with exclusive_lock():
        state = load_state()
        # Gate *before* any possible write. Do not create the gate file in this patch.
        if not preview:
            if confirm != APPROVAL or not expected_tag:
                raise ReleaseError("Live deployment requires explicit confirmation and --expected-tag")
            check_live_gate()
        pipeline, tag = find_candidate(read_token())
        number = validate_candidate(pipeline, tag)
        print(f"CANDIDATE: {tag} | branch=devops/woodpecker-fargate | pipeline #{number}")
        if expected_tag is not None and expected_tag != tag:
            raise ReleaseError("Expected release tag differs from the latest successful branch push")

        decision = determine_decision(number, state)
        print(f"RELEASE RECORD: {decision}")
        preflight = run_process(ansible_command(tag, deploy=False), timeout=180)
        readiness = classify_preview(preflight, tag)
        print(f"ANSIBLE PREFLIGHT: both ECR images verified; ECS {readiness}")
        if preview:
            print("PREVIEW ONLY: No ECS APIs were modified, no release was marked deployed.")
            return 0
        if decision != "new":
            raise ReleaseError("Refusing another release while prior attempt needs manual verification")
        if readiness != "ready" or not healthy_service():
            raise ReleaseError("Existing ECS service not verified healthy; live deployment prohibited")
        # Avoid deploying a tag superseded during our preflight checks.
        latest, latest_tag = find_candidate(read_token())
        if latest_tag != tag or validate_candidate(latest, latest_tag) != number:
            raise ReleaseError("A newer Woodpecker push appeared during preflight; aborting")

        # A write MAY partially succeed even if Ansible later fails. Record the
        # attempt *before* issuing it so no automatic retry could duplicate it.
        attempt = {"number": number, "tag": tag, "status": "started",
                   "started_at": datetime.now(timezone.utc).isoformat()}
        write_state({"version": 1, "last_attempt": attempt})
        result = run_process(ansible_command(tag, deploy=True), timeout=3600)
        attempt["status"] = "awaiting_verification" if result.returncode == 0 else "failed_requires_review"
        write_state({"version": 1, "last_attempt": attempt})
        if result.returncode:
            raise ReleaseError("Ansible returned failure; a partial ECS update is possible. Review manually")
        print("DEPLOYMENT REQUESTED: manual ECS deployment-status, production routing and ALB health verification required.")
        print("State retained as awaiting_verification; automatic follow-on releases are blocked.")
        return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deploy", action="store_true", help="Request live deployment (DISABLED without host gate)")
    parser.add_argument("--confirm", help="Required exact confirmation word for live mode")
    parser.add_argument("--expected-tag", help="Must equal current release candidate for live mode")
    args = parser.parse_args(argv)
    try:
        return release(preview=not args.deploy, expected_tag=args.expected_tag, confirm=args.confirm)
    except (ReleaseError, CandidateError) as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
