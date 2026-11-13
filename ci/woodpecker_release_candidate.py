#!/usr/bin/env python3
"""Read-only: identify a candidate Slice & Sip release from Woodpecker.

Runs on the EC2 *host*, where the existing Woodpecker API token is protected.
Never deploys, writes to Woodpecker, or changes AWS resources. The selected tag
must still be independently verified in *both* ECR repositories before deploy.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

API_BASE = "http://127.0.0.1:8000/api"
TOKEN_FILE = Path("/etc/slice-sip-ci/woodpecker-api-token")
REPOSITORY = "reinsonsronalds-design/BC_TEAM4"
BRANCH = "devops/woodpecker-fargate"
SHA = re.compile(r"^[0-9a-f]{40}$")


class CandidateError(Exception):
    pass


def read_token() -> str:
    try:
        token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise CandidateError("Cannot read protected Woodpecker API token on EC2") from exc
    if not token:
        raise CandidateError("Woodpecker API token file is empty")
    return token


def get_json(path: str, token: str):
    if not path.startswith("/") or path.startswith("//"):
        raise CandidateError("Invalid API path")
    req = Request(API_BASE + path, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    try:
        with urlopen(req, timeout=10) as response:
            return json.load(response)
    except HTTPError as exc:
        raise CandidateError(f"Woodpecker API returned HTTP {exc.code}") from exc
    except (URLError, TimeoutError, ValueError) as exc:
        raise CandidateError("Woodpecker local API unavailable or returned invalid JSON") from exc


def select_candidate(pipelines: object) -> tuple[dict, str]:
    """Fail closed if the latest push is unsuccessful, from a fork, or malformed."""
    if not isinstance(pipelines, list):
        raise CandidateError("Unexpected Woodpecker pipelines response")
    matching = [p for p in pipelines if isinstance(p, dict)
                and p.get("branch") == BRANCH and p.get("event") == "push"]
    if not matching:
        raise CandidateError("No push pipelines found for the deployment branch")
    if any(type(p.get("number")) is not int or p["number"] <= 0 for p in matching):
        raise CandidateError("A matching pipeline has an invalid pipeline number")
    latest = max(matching, key=lambda p: p["number"])
    if latest.get("status") != "success":
        raise CandidateError(f"Latest branch push (pipeline #{latest['number']}) is not successful")
    if latest.get("from_fork") is True:
        raise CandidateError("Latest pipeline came from a fork")
    commit = latest.get("commit")
    if not isinstance(commit, str) or not SHA.fullmatch(commit):
        raise CandidateError("Latest successful pipeline has no full 40-character Git SHA")
    return latest, f"{commit}-{latest['number']}"


def find_candidate(token: str) -> tuple[dict, str]:
    owner, repo = REPOSITORY.split("/", 1)
    info = get_json(f"/repos/lookup/{quote(owner, safe='')}/{quote(repo, safe='')}", token)
    if not isinstance(info, dict) or info.get("full_name") != REPOSITORY:
        raise CandidateError("Woodpecker repository does not match the approved repository")
    repo_id = info.get("id")
    if type(repo_id) is not int or repo_id <= 0:
        raise CandidateError("Woodpecker repository ID is invalid")
    query = urlencode({"page": 1, "perPage": 50, "branch": BRANCH, "event": "push"})
    records = get_json(f"/repos/{repo_id}/pipelines?{query}", token)
    return select_candidate(records)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Print safe candidate metadata as JSON")
    args = parser.parse_args(argv)
    try:
        pipeline, tag = find_candidate(read_token())
    except CandidateError as exc:
        print(f"NOT ELIGIBLE: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({"repository": REPOSITORY, "branch": BRANCH,
                          "pipeline_number": pipeline["number"], "image_tag": tag,
                          "status": "candidate_only"}, sort_keys=True))
    else:
        print(f"RELEASE CANDIDATE: {tag}")
        print(f"SOURCE: {REPOSITORY} | branch={BRANCH} | pipeline #{pipeline['number']}")
        print("READ-ONLY: No images were changed and no ECS deployment was requested.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
