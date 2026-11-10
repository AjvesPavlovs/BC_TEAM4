
#!/bin/bash
set -euo pipefail

INSTANCE_ID="${1:?Usage: bash runansible.sh INSTANCE_ID}"
AWS_REGION="eu-west-1"

PARAM_FILE=$(mktemp)
trap 'rm -f "$PARAM_FILE"' EXIT

cat > "$PARAM_FILE" <<'EOF'
{
  "commands": [
    "set -eu",
    "export DEBIAN_FRONTEND=noninteractive",
    "apt-get update -y",
    "apt-get install -y ansible git",
    "if [ -d /opt/BC_TEAM4/.git ]; then git -C /opt/BC_TEAM4 pull --ff-only; else git clone https://github.com/AjvesPavlovs/BC_TEAM4.git /opt/BC_TEAM4; fi",
    "ansible-playbook -i 'localhost,' /opt/BC_TEAM4/ansible/playbook.yml"
  ]
}
EOF

COMMAND_ID=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "file://$PARAM_FILE" \
  --query "Command.CommandId" \
  --output text)

echo "SSM Command ID: $COMMAND_ID"

aws ssm wait command-executed \
  --region "$AWS_REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" || true

aws ssm get-command-invocation \
  --region "$AWS_REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json
