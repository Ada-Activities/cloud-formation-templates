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
FRONTEND_TEMPLATE="${STACK_PREFIX}/frontend-codebuild.yaml"

require_file() {
  if [ ! -f "$1" ]; then
    echo "Expected to find '$1' based on STACK_PREFIX='${STACK_PREFIX}' - does the directory/file exist?"
    exit 1
  fi
}
require_file "$MAIN_TEMPLATE"
[ "${RUN_ECR_BOOTSTRAP:-false}" = "true" ] && require_file "$ECR_TEMPLATE"
[ "${RUN_CODEBUILD:-false}" = "true" ] && require_file "$CODEBUILD_TEMPLATE"
[ "${RUN_FRONTEND:-false}" = "true" ] && require_file "$FRONTEND_TEMPLATE"

out() { # out <stack-name> <output-key>
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

if [ "${RUN_CODEBUILD:-false}" = "true" ]; then
  read -rsp "Enter your GitHub personal access token: " GITHUB_TOKEN
  echo
fi

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
  ./trigger-builds.sh "$ORDERS_PROJECT" "$USERS_PROJECT" "$PRODUCTS_PROJECT"
fi

echo "== Deploying main stack: ${MAIN_TEMPLATE} (${STACK_PREFIX}-main) =="
aws cloudformation deploy --region "$REGION" \
  --stack-name "${STACK_PREFIX}-main" \
  --template-file "$MAIN_TEMPLATE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      OrdersImage="${ORDERS_REPO}:latest" \
      UsersImage="${USERS_REPO}:latest" \
      ProductsImage="${PRODUCTS_REPO}:latest" \
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
  ./trigger-builds.sh "$FRONTEND_PROJECT"
fi

echo "== Done: ${STACK_PREFIX} =="
aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-main" \
  --query "Stacks[0].Outputs" --output table