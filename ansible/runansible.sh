#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 || ! $1 =~ ^i-[0-9a-f]{8}([0-9a-f]{9})?$ || ! $2 =~ ^[0-9a-f]{40}$ ]]; then
    echo "Usage: bash ansible/runansible.sh INSTANCE_ID REVIEWED_COMMIT_SHA" >&2
    exit 2
fi

instance_id=$1
revision=$2
region=${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}
parameter_file=$(mktemp)
trap 'rm -f "$parameter_file"' EXIT

# The validated SHA is the only input interpolated into the remote shell commands.
cat > "$parameter_file" <<EOF
{
  "executionTimeout": ["600"],
  "commands": [
    "set -eu",
    "command -v git >/dev/null",
    "command -v ansible-playbook >/dev/null",
    "checkout=\$(mktemp -d)",
    "trap 'rm -rf \"\$checkout\"' EXIT",
    "git -C \"\$checkout\" init -q",
    "git -C \"\$checkout\" fetch --depth 1 https://github.com/reinsonsronalds-design/BC_TEAM4.git $revision",
    "git -C \"\$checkout\" checkout --detach FETCH_HEAD",
    "test \"\$(git -C \"\$checkout\" rev-parse HEAD)\" = $revision",
    "ansible-playbook -i localhost, \"\$checkout/ansible/playbook.yml\""
  ]
}
EOF

command_id=$(aws ssm send-command --region "$region" --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript --parameters "file://$parameter_file" \
    --query 'Command.CommandId' --output text)
echo "SSM command ID: $command_id"

invocation=(aws ssm get-command-invocation --region "$region"
    --command-id "$command_id" --instance-id "$instance_id")
for ((attempt=0; attempt<132; attempt++)); do
    if status=$("${invocation[@]}" --query Status --output text 2>&1); then
        case "$status" in
            Pending|InProgress|Delayed|Cancelling) ;;
            *)
                "${invocation[@]}" \
                    --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
                    --output json
                [[ $status == Success ]]
                exit
                ;;
        esac
    elif [[ $status != *InvocationDoesNotExist* ]]; then
        printf '%s\n' "$status" >&2
        exit 1
    fi
    sleep 5
done

echo "Timed out waiting for SSM command $command_id" >&2
exit 1
