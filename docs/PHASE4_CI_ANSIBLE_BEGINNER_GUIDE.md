# Phase 4 – Woodpecker + Ansible on the existing bootcamp EC2

## What changed and what has NOT changed

- EC2 **still belongs to the instructor**. Terraform references it but does not start or manage it.
- Ansible installs Docker and stages the Woodpecker definition **on the EC2 only**.
- The Woodpecker server and agent run as Docker containers on EC2; **the Slice & Sip website does not**.
- The initial Woodpecker pipeline (`.woodpecker/verify.yml`) runs **Python tests only**. It does not build/push images or deploy to ECS yet.
- The Compose port binding is `127.0.0.1:8000` **only**. No CI dashboard or webhook is publicly exposed until HTTPS ingress is agreed.
- We have not started EC2, created GitHub OAuth credentials, changed the instructor IAM profile, or deployed any AWS resources.

## Part A – Safe checks BEFORE starting EC2

1. Keep your working Phase 3 Terraform directory and existing old Terraform state backed up. **Do not run `terraform apply` yet.**
2. Confirm with your instructor that you may start/reconfigure existing instance `i-0eb789ac23be694c0`, and that Session Manager access is supported.
3. In EC2 > Security, inspect the current Security Group inbound rules and the IAM role policies (do not change anything). We need AWS Systems Manager permissions and outbound access to AWS/Docker Hub/GitHub.
4. Ask the instructor whether a public HTTPS subdomain and inbound routing can be provided for the CI service. Route 53 **does not** automatically issue a free domain. An existing domain or instructor-approved HTTPS gateway is required for normal GitHub OAuth/webhooks.
5. The EC2 may contain old website Docker containers and a custom OS. We must verify before installing packages.

## Part B – OS verification when permitted to start EC2

1. In the AWS EC2 Console, select your existing instance and click **Instance state > Start instance** (only after your instructor authorizes it).
2. Go to AWS Systems Manager > Session Manager > **Start session**. Select the same instance.
3. Run these read-only commands on the instance:

```bash
cat /etc/os-release
uname -m
command -v docker || true
sudo docker ps -a --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null || true
command -v ansible || true
```

4. Stop here and send the OS text and the **container names/statuses** (do not share any passwords or credentials).
5. If the instance is not Ubuntu 22.04 x86_64, **do not run the bootstrap script**; we will adapt Ansible to the actual image.
6. If the instance has Ubuntu `docker.io` already installed, the playbook intentionally refuses to replace it silently. We will decide how to reuse/upgrade Docker safely.

## Part C – Planned Ansible installation, NOT yet required

Once the OS and existing Docker containers have been checked, a one-time bootstrap installs Ansible. The `ci/bootstrap-ansible-ubuntu.sh` script only installs Ansible and Git on an Ubuntu 22.04 server. The script must be run on the **EC2**, not in Windows PowerShell.

We still need to select a **secure way to copy this project to EC2** before executing Ansible. If the GitHub repository is public, a read-only `git clone` is possible. If it is private, we will choose an approved read-only authentication or controlled S3 transfer. **Do not paste a GitHub personal access token into SSM shell history.**

When the source tree is present on the EC2 and Ansible has been installed, the intended command from the project root is:

```bash
sudo ansible-playbook -i 'localhost,' -c local ansible/playbook.yml
```

This performs package installation and stages `/opt/slice-sip-ci/docker-compose.yml`. It **does not start Woodpecker** by default.

## Part D – Later: Secrets, GitHub OAuth and Woodpecker activation

Only after the instructor approves public HTTPS access and a Woodpecker hostname:

- Create a **GitHub OAuth App** (not a GitHub App). Homepage URL = `https://<CI-hostname>`, callback URL = `https://<CI-hostname>/authorize`.
- Create an EC2-only configuration file `/etc/slice-sip-ci/woodpecker.env` as `root:root` mode `0600`. Use `ci/woodpecker.env.example` as a **reference**, never as the live file. Generate the agent shared secret with `openssl rand -hex 32` on EC2. Never paste GitHub OAuth secrets into Git or Terraform variables.
- During first administrator enrollment, temporarily enable registration (`WOODPECKER_OPEN=true`) only under a controlled approved access window; close registration (`false`) immediately after initial login. Do not leave arbitrary GitHub login enrollment enabled. Later we may prefer provisioning the first admin user with Woodpecker CLI instead.
- `sudo ansible-playbook -i 'localhost,' -c local ansible/playbook.yml -e woodpecker_enable=true` starts server/agent. Verify `sudo docker compose --env-file /etc/slice-sip-ci/woodpecker.env -f /opt/slice-sip-ci/docker-compose.yml ps`.
- Configure an authenticated HTTPS reverse proxy approved by the instructor. Keep port 9000 internal, and do not expose port 8000 publicly.
- Activate your GitHub repository in the Woodpecker UI, verify the webhook delivery, and test `.woodpecker/verify.yml` by pushing to `main`.

## Part E – Terraform status (your last plan: 46 to add)

Last reported summary was **46 add, 0 change, 0 destroy**, referencing the existing EC2. The 46 additions are primarily a new VPC, two public/private subnets, networking/security rules, task IAM roles, ECR repositories, Secrets Manager secret metadata, SQS/DLQ, an ECS cluster, alarms and EventBridge. The plan does **not** create another EC2 instance.

The initial plan has `enable_database=false` and `enable_application=false`; therefore it does **not** create RDS, the ALB, the Fargate application, or blue/green yet.

**Remaining blockers to apply:** bootcamp IAM permissions for VPC/roles/ECR/Secrets Manager/SQS; approval for new resources; an S3 remote-state strategy; the deployment-controller choice (existing CodeDeploy files vs native ECS blue/green); and a public HTTPS endpoint for Woodpecker.

## Useful checks

On your Windows laptop, no AWS changes:

```powershell
terraform -chdir=./infrastructure validate
terraform -chdir=./infrastructure plan
```

On the EC2 after Ansible (later):

```bash
sudo docker compose version
sudo docker compose -f /opt/slice-sip-ci/docker-compose.yml config --quiet  # Will need --env-file once secrets exist
```

Do not run `terraform destroy`: your bootcamp account may contain additional instructor-owned resources outside this Terraform state. Also do not run old scripts under `legacy/`.
