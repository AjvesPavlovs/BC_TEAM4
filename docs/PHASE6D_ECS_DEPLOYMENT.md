# Phase 6D — safe preparation of Ansible → ECS Fargate deployments

## What this patch does (and does not do)

Adds `ansible/ecs-deploy.yml` plus `ci/ecs_deploy.py`. **Neither file runs on its own.** Existing Woodpecker pipelines, Terraform files, ECR repositories, EC2 services, and runtime configuration are unchanged.

**Default execution is read-only.** The script checks AWS identity, confirms both ECR image tags exist, and checks whether the ECS cluster and service have been provisioned. Before Terraform deploys ECS, it prints `NOT READY`; that is expected and does not mean the working CI system is broken.

A live update requires **both** `deploy_enabled=true` and `deploy_confirmation=DEPLOY_SLICE_SIP`. Do not enable these until the instructor supplies appropriate IAM roles, Fargate and RDS are healthy, and the EC2 instance role can deploy to ECS.

## 1. Copy files to your existing Git branch

From Git Bash on Windows:

```bash
cd "$HOME/git-repo/new build/slice_sip_git"
git status -sb
# Copy contents of the extracted patch directory into this repository.
git diff --check
python -m py_compile ci/ecs_deploy.py
```

Inspect and commit **only after reviewing** the additive files.

## 2. Preview on EC2 (no changes)

Update the EC2 checkout over your existing approved HTTPS Git method, then in Session Manager:

```bash
cd ~/slice-sip-ci-source
ansible-playbook -i 'localhost,' -c local ansible/ecs-deploy.yml \
  -e image_tag=0619ea40a81c67b88e97cdb20febb57ed5eedb17-9
```

The preview uses only the EC2 IAM role, with no permanent AWS keys. It confirms ECR tags and may report that ECS is **not yet provisioned**. The script does **not** create ECS resources or task revisions in this mode.

If ECS DescribeClusters is denied, the preview explains that the EC2 role lacks read access. Ask the instructor for the necessary narrowly-scoped permissions rather than increasing permissions yourself.

## 3. How deployment mode will work later (DO NOT EXECUTE YET)

Ansible is required for deployments. After the first Terraform apply is approved and the service is healthy, the playbook can register new task revisions (preserving existing environment, RDS secret references and logging settings) and ask ECS to update its **native BLUE_GREEN** application service. ECS then performs load-balancer traffic switching and a bake period. For a backend change, `deploy_worker=true` optionally performs a separate rolling update to the notification worker service.

A deployment will require the EC2 instance role to have appropriate scoped permissions including `ecs:DescribeClusters`, `ecs:DescribeServices`, `ecs:DescribeTaskDefinition`, `ecs:RegisterTaskDefinition`, `ecs:UpdateService`, and `iam:PassRole` for the task roles. The initial Terraform user also needs approved IAM role provisioning or suitable pre-created roles. Ensure EC2's AWS CLI version can report native `BLUE_GREEN` deployment configuration; this helper deliberately blocks live deployments when that status cannot be confirmed.

The deployment includes an ECS `services-stable` wait, but **that is not a substitute for verifying the public ALB `/ready` endpoint and ECS deployment history**. Our future pipeline will add that validation as a release gate. Blue/green reduces planned downtime but does not guarantee zero downtime during every possible failure.

**Do not connect this file to `.woodpecker/verify.yml` yet.** Woodpecker's unprivileged build steps must not be given host Docker socket access or unfettered access to EC2 role credentials. A secure, audited trigger mechanism for the host-side Ansible deployment remains to be designed.

## 4. Operational notes

- Both immutable images must exist in ECR under the same `<full-sha>-<pipeline-number>` tag before preview/deployment.
- Changes to Terraform task-definition bootstrapping and application/worker role ARNs will be reviewed after the instructor responds.
- Do not edit Terraform state or use the old `phase6-initial-v2.tfplan` after IAM/Terraform changes.
- Application traffic is currently planned over HTTP through ALB; use **synthetic demo orders/support data only** until TLS is configured.
- Secrets Manager placeholders for Discord webhooks must be populated securely before testing notifications.
- ECS and RDS continue to incur costs while running; confirm bootcamp authorization before first apply.
