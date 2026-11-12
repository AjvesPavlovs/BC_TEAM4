# Slice & Sip – DevOps Capstone

Slice & Sip is a demonstration food-ordering application used to demonstrate infrastructure as code, configuration management, container builds, CI/CD, blue/green deployment and operational notifications.

## Agreed architecture

- **EC2 (bootcamp custom OS; Ubuntu 22.04 pending verification):** Woodpecker CI server and agent, build execution and Ansible control node only. It does not host the website or application services.
- **ECS Fargate:** NGINX frontend, Python API and notification worker containers.
- **ECR:** application container images.
- **ALB + deployment controller (TBD):** ECS blue/green traffic shifting and rollback. The earlier Terraform still has CodeDeploy; native ECS deployment is being evaluated before activation.
- **RDS PostgreSQL:** order, invoice, support-ticket and notification-outbox data.
- **Secrets Manager:** four Discord webhook secrets.
- **SQS + DLQ:** asynchronous notification delivery and retry handling.
- **CloudWatch + EventBridge:** metrics, logs and monitoring notifications.
- **Terraform + Ansible:** infrastructure provisioning and configuration/deployment automation.

Jenkins and GitHub Actions are not used. GitHub remains the source repository and sends push webhooks to Woodpecker.

## Current application API

- `GET /health` – API liveness check.
- `GET /ready` – PostgreSQL readiness check.
- `POST /api/orders` – creates an order and its invoice in one database transaction.
- `POST /api/support` – creates a support ticket and notification event.

Ticket numbers are generated from independent PostgreSQL sequences:

- `ORD-YYYY-NNNNNN`
- `INV-YYYY-NNNNNN`
- `SUP-YYYY-NNNNNN`

Prices are looked up by product ID on the server. The browser cannot choose its own price or ticket number. Customer support message contents are stored in PostgreSQL but are not copied into Discord notifications.

The API writes notification events to a PostgreSQL transactional outbox. A separate publisher forwards committed events to SQS. A separate worker sends them to Discord and only deletes an SQS message after successful delivery. The SQS redrive policy and DLQ will be configured in Terraform in the infrastructure phase.

## Local application smoke test

Docker Compose is provided for local UI + API + PostgreSQL development. It does not start the AWS-dependent Discord worker.

```bash
docker compose -f docker-compose.dev.yml up --build
```

Open `http://localhost:8080`. The API is also reachable through the NGINX proxy at `/health` and `/ready`.

Stop the local stack:

```bash
docker compose -f docker-compose.dev.yml down
```

Remove the local database volume only when you intentionally want to delete local demo data:

```bash
docker compose -f docker-compose.dev.yml down -v
```

The database password in `docker-compose.dev.yml` is for local development only. Do not reuse it in AWS.

## Python tests

```bash
python -m pip install -r backend/requirements.txt
python -m pip install pytest httpx
PYTHONPATH=backend pytest -q backend/tests
```

## Required AWS secret names

Create four separate Secrets Manager secrets. Store each as JSON, for example `{"url":"https://discord.com/api/webhooks/..."}`:

- `slicesip/discord/orders`
- `slicesip/discord/invoices`
- `slicesip/discord/support`
- `slicesip/discord/monitoring`

Only the notification worker task role should be allowed to read these secrets. Never commit webhook URLs, credentials, Terraform state or real `.tfvars` files.

## Terraform infrastructure (Phase 3)

The new configuration lives in [`infrastructure/`](infrastructure/). Legacy Terraform,
EC2 user-data and Lambda-era scripts have been preserved only as references under
`legacy/` and must **not** be applied or executed. The new Terraform state is not
interchangeable with the old state: read `docs/PHASE3_AWS_BEGINNER_GUIDE.md` first.

The first plan has the database and application disabled to avoid surprise costs.
The core network, EC2 CI host, ECR, SQS/DLQ, Secrets Manager secret metadata,
EventBridge, IAM, ECS cluster and CloudWatch alarms are described in the new root.
Fargate/ALB/CodeDeploy are enabled only after the initial container images exist.
All four Discord webhook *values* must be entered manually in Secrets Manager;
Terraform creates only the secret names, never values.

The Python database connection now supports both `DATABASE_URL` for local
Docker Compose and `RDS_SECRET_ARN` for ECS managed master credentials.

**No infrastructure has been applied. CI/CD Ansible installation and Woodpecker
pipeline wiring are the next implementation phase, not yet deployed.**

## Migration status and safety note

The Terraform definitions for the target architecture are drafted in `infrastructure/`, but have NOT been applied to AWS or validated against the live AWS account. Old EC2/Lambda files are retained under `legacy/`; the existing Ansible playbook still needs replacement in the next phase.

**Do not run `terraform apply` until you have read the Phase 3 beginner guide, checked your AWS identity/budget, and reviewed any old AWS resources.** The old local state was NOT copied into this ZIP. Do not apply the new configuration to the old state. A first `terraform plan` inside `infrastructure/` is the safe next step after local setup.

Validation completed in the current environment: Python unit tests and frontend JavaScript syntax checks pass. A live PostgreSQL migration, Docker build, SQS/Discord delivery, Terraform plan and AWS deployment have not yet been run because Docker, PostgreSQL and Terraform are not available in this review environment.


### Existing bootcamp EC2 reuse (Phase 3 revision)

The CI machine is now looked up by instance ID, rather than created by this
Terraform root. Its lifecycle, security group, IAM profile, and networking
remain under instructor control. See `docs/EXISTING_CI_EC2_CHECKLIST.md`.
Do not run `terraform apply` until the revised plan and IAM requirements
have been reviewed.


## Phase 4 – CI/CD preparation (not deployed)

New files: `ci/docker-compose.yml`, `ci/woodpecker.env.example`,
`ci/bootstrap-ansible-ubuntu.sh`, `.woodpecker/verify.yml`, and an expanded
`ansible/playbook.yml`. See `docs/PHASE4_CI_ANSIBLE_BEGINNER_GUIDE.md`.

The CI server remains private and disabled until the bootcamp AMI, old Docker
containers, HTTPS address and OAuth secrets are confirmed. **Do not apply Terraform
or start Woodpecker yet.** The safe first pipeline currently runs tests only; it
does not yet build images or perform blue/green deployments.

### Phase 4A – Existing Docker reuse (2026-11-12)

The verified bootcamp EC2 already has Ubuntu 22.04, Docker CE, Docker Compose, Ansible and Git. The updated `ansible/playbook.yml` does **not** install or upgrade any packages; it only checks prerequisites and stages Woodpecker configuration, without starting containers by default. Read `docs/PHASE4A_SAFE_EC2_SETUP.md` before transfer or execution.
