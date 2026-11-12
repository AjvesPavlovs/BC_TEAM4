# Phase 5D — ECR automatic publishing (EC2 role, no AWS keys in CI)

This update **does not modify your running Woodpecker pipeline on its own**.
The production publish YAML is an example until the rotating ECR secret works.
Keep `.woodpecker/verify.yml` unchanged until the final activation step.

## Design and security decisions

- Your existing EC2 IAM instance profile obtains `aws ecr get-login-password` on the host.
- ECR registry passwords expire after **12 hours**. A systemd timer renews the token every **6 hours**.
- The host sends the temporary ECR password only to the **local Woodpecker API** (`127.0.0.1:8000`), using an API token stored root-only.
- The Woodpecker repository secret `ecr_password` is available only for push events and the exact `woodpeckerci/plugin-kaniko:2.3.4` plugin image. Do not grant repository Trusted/Volumes/Security permissions.
- No AWS access key, STS role session, Docker socket, ngrok token, GitHub token, or ECR password goes into Git.
- Anyone with write access to the deployment branch can influence what gets built and pushed; restrict writes to trusted teammates. The existing broad EC2 role might authorize more ECR repositories than desired; ask your instructor about least-privilege if this were production.
- Each published tag is `${CI_COMMIT_SHA}-${CI_PIPELINE_NUMBER}`, avoiding conflicts between separate pipeline numbers under immutable ECR tags. Re-running the same exact pipeline number may still encounter an existing tag.

## Step 1 — Copy the patch and commit safe infrastructure additions

In local **VS Code Git Bash** in your Git clone on branch `devops/woodpecker-fargate`:

```bash
cp -a "$HOME/Downloads/slice_sip_phase5d_ecr_publisher_setup/." .
git diff --check
git status --short
```

Only the existing Ansible playbook should change; new `ci/` files and this guide should appear. **Do not replace `.woodpecker/verify.yml` yet**. Stage the six safe setup files and commit/push. The running pipeline will still only test and dry-build images.

## Step 2 — Update the EC2 source checkout

On EC2 via SSM:

```bash
cd ~/slice-sip-ci-source
git pull --ff-only origin devops/woodpecker-fargate
```

If Git requests authentication, follow your approved HTTPS process. Do not include PATs in URLs or commands.

## Step 3 — Create the Woodpecker API token file on EC2

From your Woodpecker profile, obtain a **Woodpecker API token** (not GitHub OAuth client secret, not GitHub PAT). It can manage repository secrets and is sensitive; treat it like an administrator credential.

In your EC2 Session Manager terminal:

```bash
set +x
read -r -s -p 'Woodpecker API token: ' WP_API_TOKEN; echo
printf '%s' "$WP_API_TOKEN" | sudo tee /etc/slice-sip-ci/woodpecker-api-token >/dev/null
unset WP_API_TOKEN
sudo chown root:root /etc/slice-sip-ci/woodpecker-api-token
sudo chmod 600 /etc/slice-sip-ci/woodpecker-api-token
sudo stat -c '%U:%G %a %n' /etc/slice-sip-ci/woodpecker-api-token
```

Expected: `root:root 600`. Never `cat` the file, put it in Git, paste it in chat, or share it in screenshots. Bootcamp Session Manager recording may log interactive input; follow your instructor's guidance on secure secret entry.

## Step 4 — Prepare Ansible, then turn on the timer

On EC2:

```bash
cd ~/slice-sip-ci-source
sudo ansible-playbook -i 'localhost,' -c local ansible/playbook.yml \
  -e 'ecr_secret_refresh_manage=true' --check --diff
```

Check for `failed=0`. Then run the same command without `--check --diff`. **Do not add `woodpecker_enable=true`**, so the existing containers will remain unchanged.

Verify the service exists, then test it immediately:

```bash
sudo python3 /usr/local/libexec/slice-sip-ci/refresh-ecr-woodpecker-secret.py --check
sudo systemctl start slice-sip-ecr-secret.service
sudo systemctl status slice-sip-ecr-secret.service --no-pager
sudo systemctl list-timers slice-sip-ecr-secret.timer --no-pager
```

For a oneshot service, `inactive (dead)` after a successful exit is normal; verify the journal reports the secret refresh without any token disclosure:

```bash
sudo journalctl -u slice-sip-ecr-secret.service -n 15 --no-pager
```

Do NOT run `docker compose config` without `--quiet` because it can interpolate OAuth secrets.

## Step 5 — Verify secret restrictions in Woodpecker

In BC_TEAM4 repository settings, inspect the repository secret named `ecr_password`. Verify `push` event only and allowed plugin image `woodpeckerci/plugin-kaniko:2.3.4`. Do not reveal or export its value.

## Step 6 — Activate automatic image publishing

**Only after all previous steps work**, on your Windows Git Bash repository:

```bash
cp ci/verify-publish.yml.example .woodpecker/verify.yml
git diff --check
git diff -- .woodpecker/verify.yml
git add .woodpecker/verify.yml
git commit -m 'ci: publish versioned frontend and backend images to ECR'
git push origin devops/woodpecker-fargate
```

Woodpecker should run `unit-tests`, `publish-frontend`, `publish-backend`. Neither step has privileged Docker access. The ECR credential is injected as a restricted plugin secret. Check the two ECR repositories for matching tags:

```bash
aws ecr list-images --region eu-west-1 \
  --repository-name slice-sip-frontend \
  --query 'imageIds[].imageTag' --output table
aws ecr list-images --region eu-west-1 \
  --repository-name slice-sip-backend \
  --query 'imageIds[].imageTag' --output table
```

If one push fails, collect the **error text without any credentials**. Do not disable image immutability, turn on privileged mode or expose the instance metadata service to arbitrary CI containers.

## Notes

This is a bootcamp deployment pattern. A production pipeline would preferably use a dedicated narrowly scoped registry publisher identity/workload identity, isolate CI agents from EC2 instance metadata, gate protected branches, and implement image vulnerability approval and state locking. This setup deliberately uses a root-owned Woodpecker API token to rotate a scoped, 12-hour ECR password rather than storing static AWS keys.
