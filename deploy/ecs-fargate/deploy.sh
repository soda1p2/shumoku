#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Shumoku - ECS Fargate deploy helper
# ==================================================
# Usage:
#   ./deploy.sh                  # interactive (prompts for missing values)
#   ./deploy.sh --build-push     # build image and push to ECR, then deploy
#
# Required environment variables (or will be prompted):
#   AWS_REGION          - AWS region       (default: ap-northeast-1)
#   AWS_ACCOUNT_ID      - AWS account ID
#   VPC_ID              - VPC ID
#   SUBNET_IDS          - Comma-separated subnet IDs
# ==================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

APP_NAME="${APP_NAME:-shumoku}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
STACK_NAME="${APP_NAME}-fargate"
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

# ---------- pre-flight ----------
require_cmd aws
require_cmd docker

prompt_if_empty AWS_ACCOUNT_ID "AWS Account ID"
prompt_if_empty VPC_ID         "VPC ID (vpc-xxx)"
prompt_if_empty SUBNET_IDS     "Subnet IDs (comma-separated, 2+ AZs)"

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${ECR_URI}/${ECR_REPO_NAME}:${IMAGE_TAG}"

# ---------- Step 1: ECR ----------
ensure_ecr_repo() {
  info "Ensuring ECR repository: ${ECR_REPO_NAME}"
  aws ecr describe-repositories \
    --repository-names "$ECR_REPO_NAME" \
    --region "$AWS_REGION" &>/dev/null \
  || aws ecr create-repository \
    --repository-name "$ECR_REPO_NAME" \
    --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256
}

# ---------- Step 2: Build & Push ----------
build_and_push() {
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

# ---------- Step 3: CloudFormation deploy ----------
deploy_stack() {
  info "Deploying CloudFormation stack: ${STACK_NAME}"
  aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "${SCRIPT_DIR}/cfn.yaml" \
    --parameter-overrides \
      AppName="$APP_NAME" \
      ImageUri="$IMAGE_URI" \
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

# ---------- main ----------
main() {
  ensure_ecr_repo

  if [[ "${1:-}" == "--build-push" ]]; then
    build_and_push
  else
    info "Skipping image build (use --build-push to build & push image)"
    info "Using image: ${IMAGE_URI}"
  fi

  deploy_stack

  info "Done! Access the app at the ALB DNS shown above."
}

main "$@"
