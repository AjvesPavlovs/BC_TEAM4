# Phase 5A – Woodpecker image builds (no ECR writes)

## Scope

Current: GitHub -> ngrok -> Woodpecker on EC2 -> Python tests (14 passing).

This patch adds **two unprivileged Kaniko build-validation jobs** after the tests:

1. Frontend image from repository `Dockerfile` (NGINX + `index.html`).
2. Backend image from `backend/Dockerfile` (FastAPI).

No AWS resources are created, no images are published to ECR, no Docker host socket is mounted in the CI steps, and no long-lived AWS keys are introduced. `dry_run: true` and no `repo` setting both ensure the Kaniko plugin uses `--no-push`.

The EC2 IAM role can obtain an ECR auth token, but **ECR image upload permissions are still unverified**, and the ECR repositories have not been provisioned. Keep those as later milestones.

## What each new or changed file does

- `.woodpecker/verify.yml`: keeps Python tests, then builds the frontend and backend sequentially in unprivileged Kaniko steps. The branch remains `devops/woodpecker-fargate`.
- `.dockerignore`: sends **only** the NGINX Dockerfile, HTML, and its config template to the frontend build context.
- `backend/.dockerignore`: excludes local credentials and test artifacts from the Python image context.
- `ansible/playbook.yml`: adds an *opt-in* `ngrok_manage` variable (default `false`) so the working systemd service isn't touched by normal playbook runs.
- `ansible/templates/ngrok-woodpecker.service.j2`: source-controlled systemd unit with no ngrok authtoken.

## Integrate patch into existing private Git clone (Windows, Git Bash)

1. Extract the Phase 5A patch ZIP into `~/Downloads/slice_sip_phase5a_patch`.
2. Run in VS Code Git Bash:

```bash
cd "$HOME/git-repo/new build/slice_sip_git"
git status -sb
# Must show branch devops/woodpecker-fargate and no local changes.
cp -a "$HOME/Downloads/slice_sip_phase5a_patch/." .
git diff --check
git diff -- .woodpecker/verify.yml ansible/playbook.yml
```

3. Stage only the intended files:

```bash
git add .woodpecker/verify.yml .dockerignore backend/.dockerignore   ansible/playbook.yml ansible/templates/ngrok-woodpecker.service.j2   docs/PHASE5A_IMAGE_BUILDS.md
# Look for accidental files:
git status --short
# Basic secrets screening; no output is good:
git diff --cached --name-only | grep -E '(\.tfstate|\.tfvars$|\.env$|\.pem$|\.key$)' || true
```

4. If the staged changes match the plan:

```bash
git commit -m "ci: validate frontend and backend image builds"
git push origin devops/woodpecker-fargate
```

5. Open Woodpecker. A new pipeline should start, with steps `unit-tests`, `build-frontend-check`, and `build-backend-check`. Builds may need a few minutes to pull images on the first run. If one fails, **stop** and share the step's final error lines (redact any secrets). Don't enable trusted mode or privileged steps to work around a failure.

## Put ngrok under Ansible control later (EC2, optional)

The existing systemd service already works. Leave it alone until the image-build tests pass. When ready, inspect the proposed unit template and run:

```bash
cd ~/slice-sip-ci-source
# On EC2, update checked-out repo *after* GitHub push; this is read-only source sync.
git pull --ff-only origin devops/woodpecker-fargate
sudo ansible-playbook -i 'localhost,' -c local ansible/playbook.yml   -e 'ngrok_manage=true' --check --diff
```

Review any diffs before applying; the playbook will reload/restart ngrok only if the unit changes. Existing OAuth and ngrok tokens remain outside Git.

## Next: ECR provisioning and publishing (NOT included yet)

1. From Windows in `infrastructure/`, review a Terraform plan that creates two private ECR repositories (`slice-sip-frontend` and `slice-sip-backend`) and their lifecycle policies. **Do not run the existing full Terraform apply** just to create ECR: it still proposes many additional resources. Avoid routine `-target`; prefer separately managed bootstrap modules or a reviewed one-time targeted apply with follow-up full plan and state reconciliation.
2. Obtain instructor approval for ECR create/push permissions on the bootcamp role. `ecr:GetAuthorizationToken` was verified, but upload actions have not been.
3. Design a push step so the *host's temporary IAM role credentials* can be used without leaking permanent keys into CI containers or widening IMDS permissions for untrusted code. An ordinary Woodpecker Docker step may not be able to reach IMDSv2 due to hop-limit restrictions. Avoid mounting `/var/run/docker.sock` into arbitrary pipeline steps.
4. Only then implement ECR push, immutable commit-SHA tags, and downstream ECS/Ansible deployment.
