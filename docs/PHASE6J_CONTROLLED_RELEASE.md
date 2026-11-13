# Phase 6J – Controlled host-side Woodpecker → Ansible release handoff

## Why

Woodpecker builds/publishes images in isolated containers. ECS deployment must run on the **existing Ubuntu 22.04 EC2 host** with its instance-profile credentials. Do **not** mount the Docker socket, instance metadata endpoints, AWS credentials, or host directories into Woodpecker build steps.

This is an **additive preparation patch**: only three new files. It does **not** change `.woodpecker/verify.yml`, Terraform, Ansible's existing deploy playbook, Docker containers, ngrok, or any AWS resources. It does **not** set up a timer or enable continuous polling.

## Before installing: what the controller does

1. Takes a single-host exclusive lock (`/run/lock/slice-sip-release-controller.lock`).
2. Uses the existing protected API token (`/etc/slice-sip-ci/woodpecker-api-token`) and Phase 6I module to select the latest successful push to `devops/woodpecker-fargate` in the exact approved repository.
3. Checks a protected local release record (if present) and refuses to treat unfinished attempts as complete.
4. Calls the existing Ansible `ecs-deploy.yml` **without** `deploy_enabled`, verifying the image tag in **both** ECR repositories.
5. In default preview mode, reports that ECS is `not_ready` until it is provisioned. **No AWS write operations occur.** A successful preview with missing ECS is NOT a deploy success.
6. A future live mode exists in the source, but it requires *all* of: `--deploy`, an exact confirmation string, the exact expected image tag, and a root-owned 0600 authorization file with a specific content. This file is **NOT created in Phase 6J**. The controller additionally checks current ECS status, rechecks that the GitHub/Woodpecker candidate has not changed, and records an attempt before any AWS write.
7. On live mode return, any write attempt remains `awaiting_verification` or `failed_requires_review` in `/var/lib/slice-sip-ci/release-controller.json`; there is **no automated repeat** and no automatic rollback. A successful Ansible command does **not** mean ALB traffic was fully switched or the bake period ended.

The controller cannot prove production traffic routing, successful database migrations, or full blue/green bake completion. Those are manual acceptance gates until live monitoring and listener verification are exercised. If the controller ever records an attempt, do **not** delete the state file as a retry shortcut; reconcile it against AWS service-deployment history and obtain explicit authorization first.

## Step 1: Work on the existing Git branch (Windows / VS Code Git Bash)

Unzip the Phase 6J patch in `~/Downloads/slice_sip_phase6j_release_controller`, then:

```bash
cd "$HOME/git-repo/new build/slice_sip_git"
git status -sb
cp -a "$HOME/Downloads/slice_sip_phase6j_release_controller/." .
git status --short
git diff --check
```

Only new files should appear:

- `ci/release_controller.py`
- `ci/tests/test_release_controller.py`
- `docs/PHASE6J_CONTROLLED_RELEASE.md`

Review and commit if correct:

```bash
git add ci/release_controller.py ci/tests/test_release_controller.py docs/PHASE6J_CONTROLLED_RELEASE.md
git diff --cached --stat
git diff --cached --check
git commit -m "ci: prepare guarded host-side ECS release controller"
git push origin devops/woodpecker-fargate
```

This push triggers the *existing* test and ECR publishing pipeline, **not** an ECS deployment.

## Step 2: Pull and test on EC2 (Session Manager)

```bash
cd ~/slice-sip-ci-source
git pull --ff-only origin devops/woodpecker-fargate
python3 -m unittest discover -s ci/tests -p 'test_release_controller.py' -v
```

Expected: **14 offline tests passed**. Tests mock subprocesses and never call AWS or Woodpecker.

## Step 3: Install reviewed files into root-owned directories (EC2)

For this phase, **do not run `sudo python3 ci/release_controller.py` from the user-writable checkout**. A privileged script reading a protected API token should be executed from a root-owned, reviewed installation instead.

```bash
sudo install -d -o root -g root -m 0755 /opt/slice-sip-release/ci /opt/slice-sip-release/ansible
sudo install -o root -g root -m 0755 ci/release_controller.py /opt/slice-sip-release/ci/release_controller.py
sudo install -o root -g root -m 0644 ci/woodpecker_release_candidate.py /opt/slice-sip-release/ci/woodpecker_release_candidate.py
sudo install -o root -g root -m 0644 ci/ecs_deploy.py /opt/slice-sip-release/ci/ecs_deploy.py
sudo install -o root -g root -m 0644 ci/ecs_release_status.py /opt/slice-sip-release/ci/ecs_release_status.py
sudo install -o root -g root -m 0644 ansible/ecs-deploy.yml /opt/slice-sip-release/ansible/ecs-deploy.yml
```

Check file ownership without printing the protected token:

```bash
sudo stat -c '%U:%G %a %n' /opt/slice-sip-release/ci/release_controller.py
sudo stat -c '%U:%G %a %n' /etc/slice-sip-ci/woodpecker-api-token
```

Expected: `root:root 755` for the installed controller, `root:root 600` for the token file.

If the application source or Ansible deployment code changes in a later phase, reinstall the corresponding reviewed copies deliberately. The controller's code is not auto-updated from Git.

## Step 4: Run the controller in PREVIEW-ONLY mode

```bash
sudo /opt/slice-sip-release/ci/release_controller.py
```

Typical output while IAM approvals and initial ECS provisioning are pending:

```text
CANDIDATE: <full-git-sha>-<pipeline-number> | branch=devops/woodpecker-fargate | pipeline #...
RELEASE RECORD: new
ANSIBLE PREFLIGHT: both ECR images verified; ECS not_ready
PREVIEW ONLY: No ECS APIs were modified, no release was marked deployed.
```

`not_ready` is correct before `slice-sip-ecs` exists. If ECR verification fails, the program exits nonzero without changing AWS resources. The output contains no Woodpecker token or AWS credential.

## Do NOT activate live release yet

Do not create `/etc/slice-sip-ci/enable-ecs-deploy`, add a systemd service/timer for this controller, add Woodpecker pipeline deployment steps, or use `--deploy` in Phase 6J.

Before live deployment: instructor-managed ECS IAM roles and SQS/Logs/EventBridge permissions; initial ALB/ECS/RDS deployment and database readiness; successful manual Ansible update; branch protection; full native service-deployment status and ALB production listener verification; an explicit operator policy for reconciling release state and failure handling.

Future automatic release integration should invoke this controller **on EC2**, ideally as a narrowly controlled host-side unit, after validating a newly successful Woodpecker push. It should not give CI build containers host-level access. A timer or webhook listener is not installed by this patch.

## Offline test limitations

The 14 unit tests cover release/number verification, preview-only behavior, missing ECR images, no ECS readiness, protected live authorization, changed pipeline, duplicate/unfinished state, and recording before AWS writes. They do not test real ECS transitions or security guarantees from operating system configuration.
