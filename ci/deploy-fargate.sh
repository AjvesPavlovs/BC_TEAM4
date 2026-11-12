#!/bin/sh
set -eu

mode=${1:-}
case "$mode" in
    check|apply) ;;
    *) exit 2 ;;
esac
test "${CI_PIPELINE_EVENT:-}" = deployment
test "${CI_PIPELINE_DEPLOY_TARGET:-}" = fargate
test "${CI_COMMIT_BRANCH:?}" = "${CI_REPO_DEFAULT_BRANCH:?}"
: "${TF_VAR_aws_account_id:?Expected AWS account ID is required}"
: "${TF_VAR_aws_region:?AWS region is required}"
: "${AWS_ACCESS_KEY_ID:?Deployment role session is required}"
: "${AWS_SECRET_ACCESS_KEY:?Deployment role session is required}"
: "${AWS_SESSION_TOKEN:?Deployment role session is required}"

export AWS_DEFAULT_REGION="$TF_VAR_aws_region"
export AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=true
account=$(aws sts get-caller-identity --query Account --output text)
if [ "$account" != "$TF_VAR_aws_account_id" ]; then
    echo "Unexpected AWS account: $account" >&2
    exit 1
fi

umask 077
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
export TF_DATA_DIR="$scratch/terraform-data"
printf '%s\n' "${FARGATE_BACKEND_CONFIG:?S3 backend HCL is required}" > "$scratch/backend.hcl"
printf '%s\n' "${FARGATE_VARS:?Fargate tfvars HCL is required}" > "$scratch/environment.tfvars"
unset FARGATE_BACKEND_CONFIG FARGATE_VARS

if [ "$mode" = apply ]; then
    application_image=$(cat .woodpecker-release-image)
    printf '%s\n' "$application_image" |
        grep -Eq '^docker\.io/[a-z0-9_-]+/[a-z0-9._-]+@sha256:[a-f0-9]{64}$'
fi

cd terraform-fargate
terraform init -reconfigure -input=false -lockfile=readonly -backend-config="$scratch/backend.hcl"

if [ "$mode" = check ]; then
    terraform validate
    exit 0
fi

terraform plan -input=false -lock-timeout=5m -var-file="$scratch/environment.tfvars" \
    -var="aws_account_id=$TF_VAR_aws_account_id" -var="aws_region=$TF_VAR_aws_region" \
    -var="application_image=$application_image" -out="$scratch/release.tfplan"
terraform apply -input=false -lock-timeout=5m "$scratch/release.tfplan"

cluster=$(terraform output -raw ecs_cluster_name)
service=$(terraform output -raw ecs_service_name)
revision=$(terraform output -raw task_definition_arn)
url=$(terraform output -raw application_url)
aws ecs wait services-stable --cluster "$cluster" --services "$service"
task=$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" \
    --desired-status RUNNING --query 'taskArns[0]' --output text)
test -n "$task" && test "$task" != None || exit 1
running=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" \
    --query "tasks[?lastStatus=='RUNNING'].[taskDefinitionArn, (containers[?name=='slice-sip'].imageDigest | [0])]" \
    --output text)
expected=$(printf '%s\t%s' "$revision" "${application_image##*@}")
if [ "$running" != "$expected" ]; then
    printf 'Expected revision and digest: %s\nActual: %s\n' "$expected" "$running" >&2
    exit 1
fi
curl --fail --silent --show-error --retry 6 --retry-all-errors \
    --retry-delay 3 --max-time 10 "$url/" -o /dev/null
printf 'Image: %s\nTask definition: %s\nApplication: %s\n' "$application_image" "$revision" "$url"
