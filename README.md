# Slice & Sip

Woodpecker CI runs on EC2. The website runs on ECS Fargate behind an Application Load Balancer.

## Verify on EC2

From the repository root on Ubuntu with Docker and Buildx:

```bash
sudo docker run --rm --user 0:0 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" \
  woodpeckerci/woodpecker-cli:v3.19.0 exec \
  --backend-engine docker --repo-trusted-volumes \
  --pipeline-event manual .woodpecker/verify.yml
```

This runs Terraform validation and tests, builds the image, and checks NGINX over HTTP.

## Run the Woodpecker server on EC2

Requires Ubuntu x86-64, Ansible, Docker, Compose and Buildx.

```bash
sudo touch /etc/slice-sip-woodpecker.env
sudo chown root:root /etc/slice-sip-woodpecker.env
sudo chmod 0600 /etc/slice-sip-woodpecker.env
openssl rand -hex 32
sudoedit /etc/slice-sip-woodpecker.env
```

Set these values in the environment file:

```dotenv
WOODPECKER_HOST=https://ci.example.com
WOODPECKER_ADMIN=github-login
WOODPECKER_REPO_OWNERS=github-owner
WOODPECKER_GITHUB_CLIENT=oauth-client-id
WOODPECKER_GITHUB_SECRET=oauth-client-secret
WOODPECKER_AGENT_SECRET=generated-secret
```

```bash
sudo ansible-playbook -i localhost, ansible/playbook.yml
sudo ansible-playbook -i localhost, ansible/verify-woodpecker.yml
curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:18000/healthz
```

Expect HTTP 204. For the UI and GitHub webhooks, route the HTTPS hostname to port 18000 via a reverse proxy, set the GitHub OAuth callback to `https://ci.example.com/authorize` using your hostname, then activate the approved repo with **Trusted → Volumes**.

## Release from Woodpecker

Enable **Allow deployments** on the approved repo. From a successful default-branch run, select target `registry` to publish the tested image or `fargate` to publish, deploy and verify the existing ECS service.

- Docker step (`docker:28.5.2-cli`) uses `dockerhub_repo`, `dockerhub_user` and `dockerhub_token` for the team registry.
- Fargate steps (`hashicorp/terraform:1.13.5`) use `aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`, `fargate_aws_account_id`, `fargate_aws_region`, `fargate_backend_config` and `fargate_vars`. Use short-lived credentials for the approved deploy role and the existing environment's S3 state key with `use_lockfile = true`.

Set the secrets for **Deployment** events only. The deploy role needs S3 state and lock access and permissions for ECS, EC2 networking and ELBv2. If the environment configures a task execution role, it also needs scoped `iam:PassRole`.
