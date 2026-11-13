# Slice & Sip demo

## Architecture

- Ansible → Ubuntu EC2 → Woodpecker server and Docker agent
- GitHub checkout → Woodpecker → Terraform validation and tests → Docker build → NGINX HTTP smoke test
- Docker build → Docker Hub → image pinned by digest → ECS Fargate
- Terraform → Application Load Balancer and ECS Fargate → infrastructure state in team S3
- Browser → Application Load Balancer → NGINX container on Fargate

## What we verified

Woodpecker started on EC2 through Ansible. Terraform validation and tests, Docker build, and the NGINX smoke test passed. We published a versioned image to Docker Hub and deployed the demo manually with Terraform. The load balancer returned HTTP 200 from an allowed client.

GitHub webhook delivery and an end-to-end Fargate deployment from Woodpecker are still pending verification.

## Working on the project

1. Clone the demo branch and create a branch for your changes.

   ```bash
   git clone --branch feature/woodpecker-rebuild https://github.com/SvetlanaUtkina/check.git
   cd check
   git switch -c feature/your-change
   ```

2. Run the verification command in [README.md](README.md). The Woodpecker CLI can run it on EC2 without a public CI hostname.
3. Share changes in a pull request targeting `feature/woodpecker-rebuild`, or cherry-pick the relevant commits into the team repository.
4. For a release to the existing AWS environment, reuse the team S3 bucket and the exact Terraform state key. Moving the source to another branch or repository does not require an infrastructure apply by itself.

## Presentation bonuses

| Bonus | Demo status |
| --- | --- |
| NGINX reverse proxy in front of the app | Open. The ALB fronts the NGINX app container. |
| S3 backend with DynamoDB locking | Partial. The backend uses S3 with native S3 lockfiles. |
| GitHub webhook builds on every push | Pending. The verify workflow accepts push events. Webhook delivery still needs testing. |
| Secure registry and AWS credentials | Configured through Woodpecker repository secrets in the workflow. End-to-end use still needs verification. |
| Blue/green deployment with a health check before switching traffic | Open. |
| CloudWatch logging and alarms | Open. The Terraform module supports container logs when an execution role is configured. Logging and alarms were not verified for this demo. |
| Versioned image tags using the CI build number | Demonstrated with a run number and commit SHA in the published tag. |
| Automatic Terraform destroy after testing | Open. |

Confirm with the mentor whether the Woodpecker and native S3 locking equivalents count toward the original Jenkins and DynamoDB bonuses.
