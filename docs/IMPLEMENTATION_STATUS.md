# Implementation status — after Phase 3

| Area | Status | Remaining check |
|---|---|---|
| Frontend → API | implemented in Phase 2 | local Docker and real browser test |
| PostgreSQL tickets | implemented in Phase 2 | live migration/integration test |
| Transactional outbox | implemented in Phase 2 | SQS end-to-end delivery |
| SQS retry + DLQ | Terraform drafted | provision and test redrive |
| Four webhook secret names | Terraform drafted | populate 4 secret values manually |
| Monitoring alarms → Discord | Terraform drafted | live EventBridge/SQS worker test |
| CI EC2 only | Terraform drafted | AWS plan/apply + SSM access |
| RDS managed password | Terraform + backend drafted | real RDS connectivity |
| ECS Fargate application | Terraform drafted, gated | pre-push images, plan/apply |
| ALB + CodeDeploy blue/green | Terraform drafted, gated | live health checks/rollback |
| Ansible installation/configuration | NOT YET | Phase 4 |
| Woodpecker server/agent | NOT YET | Phase 4 |
| GitHub webhook-triggered pipeline | NOT YET | Phase 4 |
| Remote Terraform state | NOT YET | separate bootstrap/migration |
| Public HTTPS | NOT YET | DNS and ACM/Caddy setup |
| AWS provisioning and costs | NOT DONE | user authorizes after review |

The included infrastructure is an **unapplied draft**. Python tests pass in
this review environment. Terraform provider validation, live AWS provisioning,
Docker builds and live Discord messages are still outstanding.
