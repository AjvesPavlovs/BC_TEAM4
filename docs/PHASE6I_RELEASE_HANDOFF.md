# Phase 6I – Read-only Woodpecker release candidate discovery

## Why

The existing `.woodpecker/verify.yml` performs unit tests and publishes two immutable images to ECR. The current Ansible deployment playbook runs on the EC2 host, not inside a Woodpecker pipeline container. Do not assume a container receives EC2 instance-profile credentials. Do not mount the host Docker socket or the instance's credentials into build steps to make it work.

The secure handoff design is to **inspect completed Woodpecker pipelines on the EC2 host** using the existing protected API token, then (once approved) call the guarded Ansible playbook with the discovered image tag using the host's IAM role.

## What this patch provides

- `ci/woodpecker_release_candidate.py` performs **GET-only** requests to the local Woodpecker API.
- Only considers `reinsonsronalds-design/BC_TEAM4`, `push` events, and `devops/woodpecker-fargate`.
- Uses the latest push on that branch and **fails closed** if it is not successful.
- Requires a full 40-character hexadecimal commit SHA and a positive pipeline number.
- Prints a candidate `sha-number` tag matching the publishing pipeline.
- Never registers ECS task definitions, updates services, modifies secrets, or changes AWS resources.
- Does **not** verify the images in ECR; the already-existing `ci/ecs_deploy.py` does that during its host-side preflight.

## Installation and test

Copy only the files in this patch to the repository, commit on `devops/woodpecker-fargate`, and pull on EC2. Existing pipeline YAML is unchanged.

On EC2:

```bash
cd ~/slice-sip-ci-source
python3 -m unittest discover -s ci/tests -p 'test_woodpecker_release_candidate.py' -v
sudo python3 ci/woodpecker_release_candidate.py
```

The script reads `/etc/slice-sip-ci/woodpecker-api-token` and calls `http://127.0.0.1:8000/api` locally. Its output contains no token. `sudo` is used because the token is root-readable only. Do not paste the token or API response headers into logs.

If successful, take the tag from `RELEASE CANDIDATE:` and perform the existing EC2 read-only Ansible deployment preflight:

```bash
ansible-playbook -i 'localhost,' -c local ansible/ecs-deploy.yml \
  -e 'image_tag=<candidate-sha>-<pipeline-number>'
```

Until ECS is provisioned this should report `NOT READY`, without changing AWS.

## Conditions before automatic deployment can be enabled

1. Instructor-provided IAM roles and missing Terraform permissions are available.
2. Initial ECS services, ALB and RDS are healthy, and first manual deployment is validated.
3. A host-side deployment controller uses a protected configuration, an explicit enable switch, a persistent record of already-processed pipeline numbers, and a single-instance lock to prevent overlapping deployments.
4. The controller independently confirms both ECR image tags exist before calling Ansible and verifies ECS service-deployment status and ALB health afterwards.
5. Rollback is an explicitly approved host-side action, never triggered by a pipeline simply receiving a failure status.
6. Production release authorization/branch protection is reviewed with the repository owner.

Do **not** place this script in `.woodpecker/` as a workflow or create any systemd timer yet. Do **not** modify the working `.woodpecker/verify.yml` or set `deploy_enabled=true` at this phase.

## Known limitation of the existing deployment helper

`aws ecs wait services-stable` only checks the `describe-services` deployment count and desired/running task counts. It is not sufficient alone to prove the full native blue/green bake period and traffic shift have completed. Use Phase 6H release monitoring and AWS `describe-service-deployments` before declaring a live release successful.
