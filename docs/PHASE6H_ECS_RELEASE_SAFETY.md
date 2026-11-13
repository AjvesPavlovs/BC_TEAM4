# Phase 6H – ECS release inspection and rollback runbook

## Scope and prerequisites

This patch is **additive**. It does not modify `.woodpecker/verify.yml`, Terraform, or the existing Ansible deploy playbook. `ci/ecs_release_status.py` performs **read-only** AWS API calls. It uses the EC2 instance's IAM role and the modern AWS CLI installed at `/opt/slice-sip/bin/aws` when invoked by `ansible/ecs-status.yml`.

ECS cluster and service are currently **not deployed**. The read-only inspection may therefore be run with `ecs_allow_missing=true` to confirm the script works. This does **not** mean the application is healthy or deployed. Do **not** enable automated ECS deployment or Terraform apply until instructor-managed IAM roles and remaining provisioning permissions are resolved.

## Initial dry run on EC2

After committing these files, pull the new branch into `/home/ssm-user/slice-sip-ci-source`, then run:

```bash
ansible-playbook -i 'localhost,' -c local ansible/ecs-status.yml -e 'ecs_allow_missing=true'
```

Expected before infrastructure provisioning: `NOT DEPLOYED: ECS cluster slice-sip-ecs is not ACTIVE`. Ansible should report `changed=0, failed=0` because missing infrastructure was explicitly allowed for this *preparatory inspection only*.

After the application has been provisioned, remove `-e 'ecs_allow_missing=true'`:

```bash
ansible-playbook -i 'localhost,' -c local ansible/ecs-status.yml
```

The monitor reports the ECS strategy and task counts, latest service deployment state, and the observable health states of the primary/alternate target groups. It deliberately does not treat an empty inactive green/blue target group as failure. It does not validate the production listener rule or query the application HTTP endpoint; those checks must be done separately. This is **not** a complete deployment health gate yet.

### Exit codes

- `0` — successful deployment, adequate running tasks and at least one healthy ALB target; **or** missing cluster/service when `--allow-missing` is explicitly set. The output distinguishes these situations.
- `2` — missing or unready service, pending deployment, or incomplete health verification.
- `3` — most recent deployment was stopped/rolled back.
- `4` — AWS API or CLI failure.

## Manual diagnostics after ECS exists

Use the modern AWS CLI on EC2:

```bash
AWS=/opt/slice-sip/bin/aws
$AWS ecs describe-services --region eu-west-1 --cluster slice-sip-ecs --services slice-sip-app \
  --query 'services[0].[serviceName,desiredCount,runningCount,deployments[0].status]' --output table
$AWS ecs list-service-deployments --region eu-west-1 --cluster slice-sip-ecs --service slice-sip-app \
  --query 'serviceDeployments[].[serviceDeploymentArn,status]' --output table
```

To check a **specific deployment**, copy its ARN from the list command:

```bash
$AWS ecs describe-service-deployments --region eu-west-1 \
  --service-deployment-arns 'PASTE_EXACT_DEPLOYMENT_ARN' \
  --query 'serviceDeployments[0].[status,lifecycleStage,statusReason]' --output table
```

For the ALB, verify the `productionListenerRule` and its forwarding weights with `elbv2 describe-rules` (requires `elasticloadbalancing:DescribeRules`). Inspect **active** target group health with `elbv2 describe-target-health` (the EC2 role previously tested allowed for this). After Terraform creates the ALB, separately request `http://<ALB-DNS>/ready` using synthetic demo data only; until HTTPS is enabled, do not transmit real customer details.

## Manual rollback – DO NOT RUN BEFORE LIVE DEPLOYMENT

1. Identify the exact **ongoing** ECS service deployment ARN using `list-service-deployments`.
2. Check its status with `describe-service-deployments` and confirm it belongs to `slice-sip-ecs/slice-sip-app`.
3. Consult the instructor or service owner and obtain explicit approval to roll back; do not confuse a historical successful deployment with the active one.
4. Once authorized, run:

   ```bash
   /opt/slice-sip/bin/aws ecs stop-service-deployment \
     --region eu-west-1 \
     --service-deployment-arn 'PASTE_EXACT_ONGOING_DEPLOYMENT_ARN' \
     --stop-type ROLLBACK
   ```

5. Re-run the monitoring playbook and verify the public application's `/ready` response, expected image version, and ECS/ALB status.

This command **changes AWS resources** and requires `ecs:StopServiceDeployment` permission. We have **not** simulated that permission yet. AWS permits rollback while a service deployment is ongoing; if the bake period has ended and the deployment completed, restoring the older image normally requires a **new deployment** of the earlier task definition instead. Do not attempt automatic rollbacks yet.

## Follow-up items before CI/CD deployment gating

- Verify `ecs:StopServiceDeployment` (EC2 role; request only if authorized rollback is desired).
- Verify `elasticloadbalancing:DescribeRules` (EC2 role) for authoritative production target group inspection.
- Check CloudWatch alarms relevant to HTTP 5xx, unhealthy targets, and ECS task failures once the infrastructure is live.
- Exercise failure and rollback safely with synthetic data and instructor approval.
- Do not make this script a required Woodpecker job until deployed-service checks and ALB listener routing are fully validated.

## Source documentation

- [ECS service deployment status](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-deployment.html)
- [Stopping/rolling back service deployments](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/stop-service-deployment.html)
- [Blue/green ALB behavior](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/alb-resources-for-blue-green.html)
