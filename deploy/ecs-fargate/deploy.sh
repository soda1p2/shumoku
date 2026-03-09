#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Shumoku - ECS Fargate deploy (ecspresso)
# ==================================================
# Usage:
#   ./deploy.sh infra          # Deploy infrastructure (CFn)
#   ./deploy.sh build-push     # Build & push Docker image to ECR
#   ./deploy.sh deploy         # Deploy ECS service via ecspresso
#   ./deploy.sh all            # All of the above in sequence
#   ./deploy.sh status         # Show current service status
#   ./deploy.sh logs           # Tail CloudWatch logs
#   ./deploy.sh exec           # ECS Exec into running container
#   ./deploy.sh rollback       # Rollback to previous task definition
#   ./deploy.sh destroy        # Delete ECS service, then infra stack
#
# Required environment variables:
#   AWS_REGION          (default: ap-northeast-1)
#   AWS_ACCOUNT_ID
#   VPC_ID
#   SUBNET_IDS          Comma-separated subnet IDs
# ==================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

APP_NAME="${APP_NAME:-shumoku}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
STACK_NAME="${APP_NAME}-infra"
ECR_REPO_NAME="${APP_NAME}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# ---------- helpers ----------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

require_cmd() {
  command -v "$1" &>/dev/null || { error "$1 is required but not installed."; exit 1; }
}

prompt_if_empty() {
  local var_name="$1" prompt_msg="$2"
  if [ -z "${!var_name:-}" ]; then
    read -rp "$prompt_msg: " "$var_name"
  fi
}

get_stack_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey==\`$1\`].OutputValue" \
    --output text
}

# ---------- pre-flight ----------
require_cmd aws

# ---------- commands ----------

cmd_infra() {
  prompt_if_empty AWS_ACCOUNT_ID "AWS Account ID"
  prompt_if_empty VPC_ID         "VPC ID (vpc-xxx)"
  prompt_if_empty SUBNET_IDS     "Subnet IDs (comma-separated, 2+ AZs)"

  info "Deploying infrastructure stack: ${STACK_NAME}"
  aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "${SCRIPT_DIR}/cfn-infra.yaml" \
    --parameter-overrides \
      AppName="$APP_NAME" \
      VpcId="$VPC_ID" \
      SubnetIds="$SUBNET_IDS" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$AWS_REGION" \
    --no-fail-on-empty-changeset

  info "Stack outputs:"
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs' \
    --output table
}

cmd_build_push() {
  require_cmd docker
  prompt_if_empty AWS_ACCOUNT_ID "AWS Account ID"

  local ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  export IMAGE_URI="${ECR_URI}/${ECR_REPO_NAME}:${IMAGE_TAG}"

  # Ensure ECR repo
  info "Ensuring ECR repository: ${ECR_REPO_NAME}"
  aws ecr describe-repositories \
    --repository-names "$ECR_REPO_NAME" \
    --region "$AWS_REGION" &>/dev/null \
  || aws ecr create-repository \
    --repository-name "$ECR_REPO_NAME" \
    --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256

  info "Logging in to ECR"
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_URI"

  info "Building Docker image"
  docker build \
    -t "${ECR_REPO_NAME}:${IMAGE_TAG}" \
    -f apps/server/Dockerfile \
    "$REPO_ROOT"

  info "Tagging and pushing to ECR"
  docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "$IMAGE_URI"
  docker push "$IMAGE_URI"
}

setup_ecspresso_env() {
  require_cmd ecspresso
  prompt_if_empty AWS_ACCOUNT_ID "AWS Account ID"

  local ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  export AWS_REGION
  export AWS_ACCOUNT_ID
  export IMAGE_URI="${IMAGE_URI:-${ECR_URI}/${ECR_REPO_NAME}:${IMAGE_TAG}}"
  export SERVICE_SG_ID="$(get_stack_output ServiceSgId)"
  export TARGET_GROUP_ARN="$(get_stack_output TargetGroupArn)"
  export EFS_FILE_SYSTEM_ID="$(get_stack_output EfsFileSystemId)"
  export EFS_ACCESS_POINT_ID="$(get_stack_output EfsAccessPointId)"
  export SUBNET_1="$(get_stack_output Subnet1)"
  export SUBNET_2="$(get_stack_output Subnet2)"
}

cmd_deploy() {
  setup_ecspresso_env

  info "Deploying ECS service via ecspresso"
  cd "$SCRIPT_DIR"
  ecspresso deploy --config ecspresso.yml
  info "Deploy complete!"

  local alb_dns
  alb_dns="$(get_stack_output AlbDnsName)"
  info "Application URL: http://${alb_dns}"
}

cmd_status() {
  setup_ecspresso_env
  cd "$SCRIPT_DIR"
  ecspresso status --config ecspresso.yml
}

cmd_logs() {
  setup_ecspresso_env
  cd "$SCRIPT_DIR"
  ecspresso logs --config ecspresso.yml --follow
}

cmd_exec() {
  setup_ecspresso_env
  cd "$SCRIPT_DIR"
  ecspresso exec --config ecspresso.yml --command "/bin/sh"
}

cmd_rollback() {
  setup_ecspresso_env
  cd "$SCRIPT_DIR"
  info "Rolling back to previous task definition"
  ecspresso rollback --config ecspresso.yml
}

cmd_destroy() {
  setup_ecspresso_env

  info "Deleting ECS service via ecspresso"
  cd "$SCRIPT_DIR"
  ecspresso delete --config ecspresso.yml --force || true

  info "Deleting infrastructure stack: ${STACK_NAME}"
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"

  info "All resources deleted."
}

# ---------- main ----------
case "${1:-help}" in
  infra)       cmd_infra ;;
  build-push)  cmd_build_push ;;
  deploy)      cmd_deploy ;;
  all)
    cmd_infra
    cmd_build_push
    cmd_deploy
    ;;
  status)      cmd_status ;;
  logs)        cmd_logs ;;
  exec)        cmd_exec ;;
  rollback)    cmd_rollback ;;
  destroy)     cmd_destroy ;;
  help|*)
    echo "Usage: $0 {infra|build-push|deploy|all|status|logs|exec|rollback|destroy}"
    echo ""
    echo "  infra        Deploy infrastructure (CloudFormation)"
    echo "  build-push   Build & push Docker image to ECR"
    echo "  deploy       Deploy ECS service (ecspresso)"
    echo "  all          Run infra + build-push + deploy"
    echo "  status       Show service status"
    echo "  logs         Tail CloudWatch logs"
    echo "  exec         ECS Exec into container"
    echo "  rollback     Rollback to previous task definition"
    echo "  destroy      Delete service and infrastructure"
    ;;
esac
