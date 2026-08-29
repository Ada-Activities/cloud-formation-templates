#!/usr/bin/env bash
set -euo pipefail
# Usage: ./deploy.sh <config-file>
# Example: ./deploy.sh e-commerce-intro/config.conf

CONFIG_FILE="${1:?Usage: $0 <config-file>}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${REGION:?Config must set REGION}"
: "${STACK_PREFIX:?Config must set STACK_PREFIX}"

# Convention: every lab lives in a directory named after its STACK_PREFIX,
# containing the following files. No path variables needed in the config.
ECR_TEMPLATE="${STACK_PREFIX}/bootstrap-ecr.yaml"
CODEBUILD_TEMPLATE="${STACK_PREFIX}/codebuild-projs.yaml"
MAIN_TEMPLATE="${STACK_PREFIX}/main-stack.yaml"
NETWORK_TEMPLATE="${STACK_PREFIX}/networking.yaml"
FRONTEND_TEMPLATE="${STACK_PREFIX}/frontend-codebuild.yaml"

require_file() {
  if [ ! -f "$1" ]; then
    echo "Expected to find '$1' based on STACK_PREFIX='${STACK_PREFIX}' - does the directory/file exist?"
    exit 1
  fi
}

# --- Helper: build + push a single image to its ECR repo ---
push_initial_image() {
  local repo_uri="$1"        # full URI, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp-orders
  local dockerfile_path="$2"
  local image_tag="${3:-latest}"

  local registry="${repo_uri%%/*}"
  local region
  region=$(echo "$registry" | cut -d. -f4)

  echo "Authenticating Docker with ECR (${region})..."
  aws ecr get-login-password --region "$region" \
    | docker login --username AWS --password-stdin "$registry"

  echo "Building image for ${repo_uri}..."
  docker build --platform linux/arm64 -t "${repo_uri}:${image_tag}" "$dockerfile_path"

  echo "Pushing ${repo_uri}:${image_tag}..."
  docker push "${repo_uri}:${image_tag}"
}

# --- Helper: add/replace a key in EXTRA_PARAM_OVERRIDES, skipping empty values ---
set_param_override() {
  local key="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    return   # leave existing/placeholder value untouched if nothing new was found
  fi

  local new_array=()
  local found=false

  for item in "${EXTRA_PARAM_OVERRIDES[@]}"; do
    if [[ "$item" == "${key}="* ]]; then
      new_array+=("${key}=${value}")
      found=true
    else
      new_array+=("$item")
    fi
  done

  if [[ "$found" == false ]]; then
    new_array+=("${key}=${value}")
  fi

  EXTRA_PARAM_OVERRIDES=("${new_array[@]}")
}

out() { # out <stack-name> <output-key>
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# Main stack is always required. All other stages only matter if they are set to true in the config file.
require_file "$MAIN_TEMPLATE"
[ "${RUN_NETWORK:-false}" = "true" ] && require_file "$NETWORK_TEMPLATE"
[ "${RUN_ECR_BOOTSTRAP:-false}" = "true" ] && require_file "$ECR_TEMPLATE"
[ "${RUN_CODEBUILD:-false}" = "true" ] && require_file "$CODEBUILD_TEMPLATE"
[ "${RUN_FRONTEND:-false}" = "true" ] && require_file "$FRONTEND_TEMPLATE"

if [ "${RUN_CODEBUILD:-false}" = "true" ]; then
  read -rsp "Enter your GitHub personal access token: " GITHUB_TOKEN
  echo
fi

if [ "${RUN_NETWORKING:-false}" = "true" ]; then
  echo "== Deploying Networking (${STACK_PREFIX}) =="
  aws cloudformation deploy --region "$REGION" \
    --stack-name "${STACK_PREFIX}-network" \
    --template-file "$NETWORK_TEMPLATE" \
    --parameter-overrides ServicePrefix="$STACK_PREFIX"
fi

VPC_ID=$(out "${STACK_PREFIX}-network" VPCId 2>/dev/null || echo "")
PUBLIC_SUBNET_IDS=$(out "${STACK_PREFIX}-network" PublicSubnetIds 2>/dev/null || echo "")
PRIVATE_SUBNET_IDS=$(out "${STACK_PREFIX}-network" PrivateSubnetIds 2>/dev/null || echo "")
ALB_SECURITY_GROUP_ID=$(out "${STACK_PREFIX}-network" ALBSecurityGroupId 2>/dev/null || echo "")
ECS_SECURITY_GROUP_ID=$(out "${STACK_PREFIX}-network" ECSSecurityGroupId 2>/dev/null || echo "")
RDS_SECURITY_GROUP_ID=$(out "${STACK_PREFIX}-network" RDSSecurityGroupId 2>/dev/null || echo "")

# --- Parallel arrays instead of associative array ---
NETWORK_PARAM_NAMES=(
  VpcId
  PublicSubnetIds
  PrivateSubnetIds
  ALBSecurityGroupId
  ECSSecurityGroupId
  RDSSecurityGroupId
)

NETWORK_PARAM_VALUES=(
  "$VPC_ID"
  "$PUBLIC_SUBNET_IDS"
  "$PRIVATE_SUBNET_IDS"
  "$ALB_SECURITY_GROUP_ID"
  "$ECS_SECURITY_GROUP_ID"
  "$RDS_SECURITY_GROUP_ID"
)

for i in "${!NETWORK_PARAM_NAMES[@]}"; do
  set_param_override "${NETWORK_PARAM_NAMES[$i]}" "${NETWORK_PARAM_VALUES[$i]}"
done


if [ "${RUN_ECR_BOOTSTRAP:-false}" = "true" ]; then
  echo "== Deploying ECR bootstrap (${STACK_PREFIX}) =="
  aws cloudformation deploy --region "$REGION" \
    --stack-name "${STACK_PREFIX}-ecr" \
    --template-file "$ECR_TEMPLATE" \
    --parameter-overrides ServicePrefix="$STACK_PREFIX"
fi

ORDERS_REPO=$(out "${STACK_PREFIX}-ecr" OrdersRepoUri 2>/dev/null || echo "")
USERS_REPO=$(out "${STACK_PREFIX}-ecr" UsersRepoUri 2>/dev/null || echo "")
PRODUCTS_REPO=$(out "${STACK_PREFIX}-ecr" ProductsRepoUri 2>/dev/null || echo "")

if [[ "${PUSH_INITIAL_IMAGES:-false}" == "true" ]]; then
  echo "== Pushing initial images =="
  for entry in "${INITIAL_IMAGE_SERVICES[@]}"; do
    service_name="${entry%%:*}"
    dockerfile_path="${entry#*:}"

    # Resolve "orders" -> "ORDERS_REPO", "users" -> "USERS_REPO", etc.
    var_name="$(echo "$service_name" | tr '[:lower:]' '[:upper:]')_REPO"
    repo_uri="${!var_name}"

    if [[ -z "$repo_uri" ]]; then
      echo "Skipping ${service_name} — ${var_name} is empty (ECR stack may not exist yet)"
      continue
    fi

    repo_name="${repo_uri#*/}"   # bare name, e.g. e-commerce-cicd-orders — only needed for list-images

    IMAGE_COUNT=$(aws ecr list-images --repository-name "$repo_name" --query 'length(imageIds)' --output text 2>/dev/null || echo "0")

    if [[ "$IMAGE_COUNT" == "0" ]]; then
      push_initial_image "$repo_uri" "$dockerfile_path" "latest"   # <- full URI, not bare name
    else
      echo "Skipping ${repo_name} — image already exists."
    fi
  done
fi

if [ "${RUN_CODEBUILD:-false}" = "true" ]; then
  echo "== Registering GitHub source credentials (safe to re-run) =="
  aws codebuild import-source-credentials --region "$REGION" --server-type GITHUB \
    --auth-type PERSONAL_ACCESS_TOKEN --token "$GITHUB_TOKEN" >/dev/null || echo "  (already registered)"

  echo "== Deploying CodeBuild projects (${STACK_PREFIX}) =="
  aws cloudformation deploy --region "$REGION" \
    --stack-name "${STACK_PREFIX}-codebuild" \
    --template-file "$CODEBUILD_TEMPLATE" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        OrdersRepoUrl="$ORDERS_REPO_GIT_URL" \
        UsersRepoUrl="$USERS_REPO_GIT_URL" \
        ProductsRepoUrl="$PRODUCTS_REPO_GIT_URL" \
        GitHubBranch="$GITHUB_BRANCH" \
        OrdersEcrRepoUri="$ORDERS_REPO" \
        UsersEcrRepoUri="$USERS_REPO" \
        ProductsEcrRepoUri="$PRODUCTS_REPO"

  ORDERS_PROJECT=$(out "${STACK_PREFIX}-codebuild" OrdersProjectName)
  USERS_PROJECT=$(out "${STACK_PREFIX}-codebuild" UsersProjectName)
  PRODUCTS_PROJECT=$(out "${STACK_PREFIX}-codebuild" ProductsProjectName)

  echo "== Triggering backend builds =="
  REGION="$REGION" ./trigger-builds.sh "$ORDERS_PROJECT" "$USERS_PROJECT" "$PRODUCTS_PROJECT"
fi

echo "== Deploying main stack: ${MAIN_TEMPLATE} (${STACK_PREFIX}-main) =="
aws cloudformation deploy --region "$REGION" \
  --stack-name "${STACK_PREFIX}-main" \
  --template-file "$MAIN_TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      OrdersImage="${ORDERS_REPO}:latest" \
      UsersImage="${USERS_REPO}:latest" \
      ProductsImage="${PRODUCTS_REPO}:latest" \
      ServicePrefix="$STACK_PREFIX" \
      "${EXTRA_PARAM_OVERRIDES[@]}"

if [ "${RUN_FRONTEND:-false}" = "true" ]; then
  AMPLIFY_APP_ID=$(out "${STACK_PREFIX}-main" AmplifyAppId)
  AMPLIFY_BRANCH_NAME=$(out "${STACK_PREFIX}-main" AmplifyBranchName)
  API_BASE_URL=$(out "${STACK_PREFIX}-main" ApiHttpsUrl)
  PRESIGN_API_URL=$(out "${STACK_PREFIX}-main" PresignApiUrl)

  echo "== Deploying frontend CodeBuild + triggering build (${STACK_PREFIX}) =="
  aws cloudformation deploy --region "$REGION" \
    --stack-name "${STACK_PREFIX}-frontend-codebuild" \
    --template-file "$FRONTEND_TEMPLATE" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        FrontendRepoUrl="$FRONTEND_REPO_GIT_URL" \
        GitHubBranch="$FRONTEND_BRANCH" \
        AmplifyAppId="$AMPLIFY_APP_ID" \
        AmplifyBranchName="$AMPLIFY_BRANCH_NAME" \
        ApiBaseUrl="$API_BASE_URL" \
        PresignApiUrl="$PRESIGN_API_URL" \
        BuildOutputDir="$FRONTEND_BUILD_OUTPUT_DIR"

  FRONTEND_PROJECT=$(out "${STACK_PREFIX}-frontend-codebuild" FrontendProjectName)
  REGION="$REGION" ./trigger-builds.sh "$FRONTEND_PROJECT"
fi

echo "== Done: ${STACK_PREFIX} =="
aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-main" \
  --query "Stacks[0].Outputs" --output table