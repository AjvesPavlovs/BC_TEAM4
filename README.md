# Slice & Sip

Woodpecker runs the CI server and Docker agent on an approved Ubuntu EC2 instance. 

## Prepare Woodpecker on EC2


1.  On the host, have the existing reverse proxy forward that name to `http://127.0.0.1:18000` with the original Host and forwarded protocol headers. 
2.  GitHub OAuth App with homepage `https://ci.example.com` and callback `https://ci.example.com/authorize`, using the real CI hostname. The repository administrator needs permission to register the webhook. 
3. Via SSM, create `/etc/slice-sip-woodpecker.env` owned by root with mode `0600`. Set these keys with approved values. Generate the shared agent secret using `openssl rand -hex 32`.

   ```dotenv
   WOODPECKER_HOST=https://ci.example.com
   WOODPECKER_ADMIN=approved-github-login
   WOODPECKER_REPO_OWNERS=approved-github-owner
   WOODPECKER_GITHUB_CLIENT=oauth-client-id
   WOODPECKER_GITHUB_SECRET=oauth-client-secret
   WOODPECKER_AGENT_SECRET=random-agent-secret
   ```

5. On the host, run the playbook from a reviewed checkout using `ansible-playbook -i localhost, --ask-become-pass ansible/playbook.yml`. Alternatively, from a Bash shell with the approved AWS CLI session, use the SSM helper once the reviewed commit is fetchable from the upstream URL:

   ```bash
   AWS_REGION=eu-west-1 bash ansible/runansible.sh i-REPLACE_WITH_INSTANCE_ID REVIEWED_40_CHARACTER_SHA
   ```

   The helper runs as root via `AWS-RunShellScript` and uses a temporary checkout of the supplied commit. The operator needs scoped `ssm:SendCommand` and `ssm:GetCommandInvocation`. The host needs the SSM agent and approved instance profile with managed-instance permissions. For a private checkout, use a team-authorized checkout over an SSM session and run the playbook on the host.

6. Confirm the agent is online in Woodpecker, activate the approved repo, enable **Trusted → Volumes**, and restrict repository hooks to pushes. Keep deployment disabled until the release credentials and IAM have been approved. Check a GitHub webhook delivery and a Woodpecker verification run. To recheck the local services, run `ansible-playbook -i localhost, --ask-become-pass ansible/verify-woodpecker.yml` on the host.

## Verify a change

Pushes and manual runs use `.woodpecker/verify.yml`. The workflow checks Terraform formatting, initializes with the backend disabled, validates the Fargate configuration, and runs three mocked tests. It then builds the amd64 Docker image and checks NGINX over HTTP from a temporary container. The smoke check uses an isolated network namespace and consumes no host listening port.

To run the same checks from a Bash shell in the checkout with Terraform, Docker and Buildx available:

```bash
sh ci/check-terraform.sh
sh ci/check-image.sh
```

## Release to Fargate

Enable Woodpecker **Allow deployments** only after the team has approved the target, credentials and trusted access. Protect the repository's default branch. From a successful default-branch pipeline, use Woodpecker's deployment action with target `fargate`. Routine pushes and manual verification runs carry no release credentials. Deployments are queued one at a time.

Add these Woodpecker repository secrets with the event filter set to **Deployment** only. Use the image filter for the listed step image.

| Step image | Secret names and values |
| --- | --- |
| `docker:28.5.2-cli` | `dockerhub_repo` as `team-namespace/repository`, `dockerhub_user` and `dockerhub_token` from the team registry account. Use an approved public Docker Hub repository so Fargate can pull the image. |
| `hashicorp/terraform:1.13.5` | `aws_access_key_id`, `aws_secret_access_key` and `aws_session_token` from a short-lived session for the approved deployment role. Refresh the session before promotion. |
| `hashicorp/terraform:1.13.5` | `fargate_aws_account_id`, `fargate_aws_region`, `fargate_backend_config` containing the S3 backend HCL, and `fargate_vars` containing the environment tfvars HCL. |

Use a pre-created S3 state bucket with an environment-specific key, region, encryption and `use_lockfile = true`. Give the deployment role access to the state and lock objects, any applicable KMS key, the ECS/EC2 networking/ELBv2/CloudWatch Logs operations needed by the module, and scoped `iam:PassRole` for the existing ECS task execution role. The execution role needs CloudWatch Logs permissions. Supply `vpc_id`, at least two approved public subnet IDs in different Availability Zones, `task_execution_role_arn` and `alb_ingress_cidrs` in the environment tfvars. Include the Woodpecker agent's egress address in the allowed ALB CIDRs. The release supplies the account, region and image digest.

The release repeats verification, checks the AWS account and initializes the configured backend before publishing. It rebuilds and smoke-tests the image it publishes, deploys the resulting immutable digest using a saved Terraform plan, waits for the ECS service, and checks the running task definition, image digest and application URL. The release log records those identifiers.
