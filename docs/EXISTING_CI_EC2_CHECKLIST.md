# Phase 3 revision — reuse the existing bootcamp EC2 for CI/CD

## Agreed boundary

- Existing instance: `i-0eb789ac23be694c0`, region `eu-west-1`, type `t3.medium`.
- Existing VPC: `vpc-04b6091923e283784` (Bootcamp-vpc).
- Existing subnet: `subnet-0085786c1374a372c`.
- Existing security group: `sg-029b67b9bcebb1776`.
- Existing instance profile: `Bootcamp-Instance-Profile`.
- Custom AMI: `Nov'26 Bootcamp base Image`. The actual Linux distribution is NOT verified.
- Instance was stopped at inspection time, with no public IPv4 address shown.

The EC2 runs **Woodpecker server, agent, Docker build tooling and Ansible** only.
The Slice & Sip web application will run on **ECS Fargate**, not on this host.

## Why lookup instead of Terraform import?

The instance is provided by the bootcamp and may already be tracked in old
Terraform state. This separate configuration uses `data.aws_instance.ci`, so
`terraform destroy` here will NOT terminate the existing EC2. **Do not** import
it into the new Terraform state without a deliberate ownership decision.

## Next checks — no AWS modifications yet

1. **Check the real OS**. When allowed to start the instance, use AWS Systems
   Manager Session Manager (preferred, no public SSH) and execute:
   `cat /etc/os-release`. Record `PRETTY_NAME`. Don't assume the custom AMI is
   Ubuntu 22.04.
2. **Check the existing IAM role**. The screenshot showed an instance profile
   called `Bootcamp-Instance-Profile`. In EC2 > Security, follow the IAM link
   and record the underlying IAM role name and attached policy names. Do not
   change or replace instructor-owned IAM without approval.
3. **Check SSM access**. Session Manager needs SSM Agent, required instance
   permissions (often `AmazonSSMManagedInstanceCore`), and outbound network
   access to Systems Manager endpoints. Confirm the instance appears as a
   managed node when started.
4. **Check networking**. GitHub requires a reachable HTTPS Woodpecker webhook
   endpoint with valid TLS and webhook-secret validation. No public IP appears
   in the stopped-instance screenshot. Check subnet route table, auto-assign
   public IP, allowed ingress/egress and whether the instructor can supply
   a subdomain or a safe public ingress (e.g. ALB) before exposing CI.
5. **Check pipeline IAM needs**. On the *existing* EC2 role, the instructor will
   likely need to authorize at least: ECR auth and image push; ECS task
   registration / inspection / deployment operations; narrowly-scoped
   `iam:PassRole` for ECS task roles; read-only deployment status; and
   whichever blue/green controller we finalize (native ECS or CodeDeploy).
   Do not grant blanket administrator access to the CI server.
6. **Check old Terraform state**. Preserve previous Terraform state and ensure
   the same EC2 isn't accidentally managed by two active Terraform roots.

## Safe PowerShell plan check

Open the **Phase 3 revision** folder in VS Code. In a PowerShell terminal,
using your already established AWS MFA session:

```powershell
Set-Location .\infrastructure
Copy-Item .\terraform.tfvars.example .\terraform.tfvars
terraform init
terraform validate
terraform plan
```

If you have previously planned using the older Phase 3 root and copied
`terraform.tfvars`, **update it** to use
`existing_ci_instance_id = "i-0eb789ac23be694c0"` and remove the obsolete
`ci_instance_type` entry (rather than blindly overwriting user settings).

Look for zero `aws_instance.ci` creations and zero `aws_eip.ci` creations.
The project can still propose other infrastructure resources. A read-only
EC2 data lookup may show `data.aws_instance.ci` being read.

**Stop after plan. Do not run terraform apply or destroy yet.**

## Important: deployment controller decision

This revision changes ONLY existing-EC2 reuse. The Phase 3 application template
still contains the older CodeDeploy blue/green plan. We previously discussed
native ECS blue/green as a future simplification. The final controller needs
one consistent implementation before enabling `enable_application=true`.
