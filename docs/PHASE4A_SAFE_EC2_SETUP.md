# Phase 4A – Stage Woodpecker safely on the existing EC2

This document supersedes the **installation steps** in `PHASE4_CI_ANSIBLE_BEGINNER_GUIDE.md` for the verified instructor-provided instance. It is deliberately limited to installing *no packages* and *starting no new containers*. Review before performing any file changes.

## Observed EC2 baseline (2026-11-12)

- Ubuntu 22.04.5 x86_64; Docker Engine 29.9.3; Docker Compose plugin v5.7.0; Ansible Core 2.17.14; Git available.
- Docker daemon active, GitHub HTTPS reachable.
- Old stopped containers: `linux_tweet_app` and `mysql-container` (do not delete).
- No `/opt/slice-sip-ci` or `/etc/slice-sip-ci` directories exist yet.
- Instance owned/provided by instructor. Confirm permission to stage new configuration before proceeding.

## What the updated Ansible playbook does

1. Asserts the expected OS/architecture and existing Docker packages.
2. Checks Docker service, Docker Compose and Git (no package upgrades).
3. Creates `/opt/slice-sip-ci` mode 0755 and `/etc/slice-sip-ci` mode 0700.
4. Copies `ci/docker-compose.yml` into `/opt/slice-sip-ci/docker-compose.yml`, with backup if a file already exists.
5. DOES NOT create credentials, start Woodpecker, modify firewall/IAM, or touch old containers.

## Step 1: Verify what you have in local Git Bash

From the extracted project directory:

```bash
pwd
ls ansible/playbook.yml ci/docker-compose.yml
git remote -v
git status --short
```

If `git remote -v` is blank or Git reports `not a git repository`, that's okay. **Do not enter credentials or push the repo yet.** Tell the reviewer whether you have a GitHub repository and whether it is public or private. We will choose a secure transfer method before running Ansible on EC2.

## Step 2: Transfer source safely to EC2 (choose after repository status is known)

- **Public repo:** use `git clone --depth 1 https://github.com/<OWNER>/<REPO>.git` from the SSM session, after the updated code has been committed and pushed. Don't clone until the repo contains this revised playbook.
- **Private repo:** use an instructor-approved transfer method (for example a short-lived S3 object with instance-role read access, or a GitHub deploy key). Do not place tokens in the command line or shell history.
- **No GitHub repo yet:** first prepare the repository locally, excluding `.env`, `.tfvars`, Terraform state, keys, and credentials. Do not send a public archive containing secrets.

## Step 3: Run only when updated project exists on the EC2

From the repo root on the EC2, after being authorized to stage CI configuration:

```bash
sudo ansible-playbook -i 'localhost,' -c local ansible/playbook.yml --check --diff
```

Review the predicted directory creation. The Compose file copy is intentionally skipped in `--check` mode on a fresh host, because the destination directory does not exist yet. No containers should be started. If it looks right:

```bash
sudo ansible-playbook -i 'localhost,' -c local ansible/playbook.yml
```

Verify:

```bash
sudo ls -ld /opt/slice-sip-ci /etc/slice-sip-ci
sudo ls -l /opt/slice-sip-ci/docker-compose.yml
sudo docker ps -a --format '{{.Names}}  {{.Status}}'
```

The old containers should still be listed, and no Woodpecker containers should have started. Avoid sharing `docker inspect` environment data, credentials, or secret files.

## Next phase (not now)

1. Obtain an instructor-approved public HTTPS address for Woodpecker (GitHub must reach its webhook endpoint). Route 53 alone does not issue a free registered domain.
2. Configure GitHub OAuth app and root-only `/etc/slice-sip-ci/woodpecker.env` (mode 0600).
3. Verify no port conflict on `127.0.0.1:8000` and that network/security rules match the approved exposure pattern.
4. Start Woodpecker intentionally by rerunning with `-e woodpecker_enable=true`.
5. Verify test-only GitHub push pipeline, **before** AWS deployment permissions.

**Never run `terraform apply` or `terraform destroy` as part of this step.**
