# Slice & Sip

## Prepare the Jenkins agent

On the Ubuntu Jenkins host, run from the checkout as a user with sudo access. Install Ansible Core, Terraform 1.10+, and AWS CLI on the host before running the setup.

```bash
bash bootstrap-jenkins-agent.sh jenkins
```

## Verify on EC2

Run from a checkout owned by the `jenkins` user, in a shell running as that user.

```bash
ansible-playbook -i localhost, ansible/verify-jenkins-agent.yml
terraform -chdir=terraform-fargate init -backend=false -input=false -lockfile=readonly
terraform -chdir=terraform-fargate validate
terraform -chdir=terraform-fargate test -no-color
docker build --platform linux/amd64 -t slice-sip:rehearsal .
docker run --rm -p 127.0.0.1:8082:80 slice-sip:rehearsal
```

In a second session, run:

```bash
curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:8082/
```

Expect three passing Terraform tests and `HTTP 200`. Press Ctrl+C in the first session to stop the container.

## Run in Jenkins

Create a Pipeline from SCM with script path `Jenkinsfile` and a Linux agent labelled `linux-docker`. Run with `DEPLOY=false` to verify the build without creating AWS resources.

For a Fargate release, set `FARGATE_BACKEND_CONFIG` to the S3 backend configuration path and `FARGATE_VARS_FILE` to the environment variables file path. The variables are defined in `terraform-fargate/variables.tf`. Set `TF_VAR_aws_account_id`, `TF_VAR_aws_region`, `DOCKERHUB_REPO`, and the Jenkins credential `dockerhub-creds` before enabling `DEPLOY=true`.
