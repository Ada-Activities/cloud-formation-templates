#!/usr/bin/env bash
set -euo pipefail

# ---- Config (Some values will need to be changed)----
REGION="us-east-1"
STACK_PREFIX="e-commerce-demo"
VPC_ID="vpc-0b6968a6b65de8681"
SUBNET_IDS="subnet-0f849532eac05a955,subnet-0ac8b8414fd642158"
GITHUB_BRANCH="deploy-lab-branch"
FRONTEND_BRANCH="main"

ORDERS_REPO_URL="https://github.com/Ada-Activities/Ada-E-Commerce-Orders-Service"
PRODUCTS_REPO_URL="https://github.com/Ada-Activities/Ada-E-Commerce-Product-Service"
USERS_REPO_URL="https://github.com/Ada-Activities/Ada-E-Commerce-User-Service"

FRONTEND_REPO_URL="https://github.com/Ada-Activities/Ada-E-Commerce-FE"
FRONTEND_BUILD_OUTPUT_DIR="dist"
GITHUB_TOKEN= #Add github token here before running. "ghp_xxxxxxxxxx"
# --------------------------------

echo "== 0. Registering GitHub credentials with CodeBuild =="
aws codebuild import-source-credentials \
  --region "$REGION" \
  --server-type GITHUB \
  --auth-type PERSONAL_ACCESS_TOKEN \
  --token "$GITHUB_TOKEN" >/dev/null || echo "  (already registered, continuing)"

echo "== 1. Deploying ECR bootstrap stack =="
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${STACK_PREFIX}-ecr" \
  --template-file ecr-config.yaml \
  --parameter-overrides ServicePrefix="$STACK_PREFIX"

ORDERS_REPO=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-ecr" \
  --query "Stacks[0].Outputs[?OutputKey=='OrdersRepoUri'].OutputValue" --output text)
USERS_REPO=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-ecr" \
  --query "Stacks[0].Outputs[?OutputKey=='UsersRepoUri'].OutputValue" --output text)
PRODUCTS_REPO=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-ecr" \
  --query "Stacks[0].Outputs[?OutputKey=='ProductsRepoUri'].OutputValue" --output text)

echo "== 2. Deploying CodeBuild projects =="
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${STACK_PREFIX}-codebuild" \
  --template-file codebuild-projs.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      OrdersRepoUrl="$ORDERS_REPO_URL" \
      UsersRepoUrl="$USERS_REPO_URL" \
      ProductsRepoUrl="$PRODUCTS_REPO_URL" \
      GitHubBranch="$GITHUB_BRANCH" \
      OrdersEcrRepoUri="$ORDERS_REPO" \
      UsersEcrRepoUri="$USERS_REPO" \
      ProductsEcrRepoUri="$PRODUCTS_REPO"

ORDERS_PROJECT=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-codebuild" \
  --query "Stacks[0].Outputs[?OutputKey=='OrdersProjectName'].OutputValue" --output text)
USERS_PROJECT=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-codebuild" \
  --query "Stacks[0].Outputs[?OutputKey=='UsersProjectName'].OutputValue" --output text)
PRODUCTS_PROJECT=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-codebuild" \
  --query "Stacks[0].Outputs[?OutputKey=='ProductsProjectName'].OutputValue" --output text)

echo "== 3. Triggering builds and waiting for completion =="
./trigger-builds.sh "$ORDERS_PROJECT" "$USERS_PROJECT" "$PRODUCTS_PROJECT"

echo "== 4. Deploying main stack =="
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${STACK_PREFIX}-main" \
  --template-file main-stack.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      VpcId="$VPC_ID" \
      SubnetIds="$SUBNET_IDS" \
      OrdersImage="${ORDERS_REPO}:latest" \
      UsersImage="${USERS_REPO}:latest" \
      ProductsImage="${PRODUCTS_REPO}:latest" \
      DBUsername="dbadmin" \
      GitHubBranch="$FRONTEND_BRANCH" \

echo "== 5. Deploying frontend CodeBuild project =="
AMPLIFY_APP_ID=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-main" \
  --query "Stacks[0].Outputs[?OutputKey=='AmplifyAppId'].OutputValue" --output text)
AMPLIFY_BRANCH_NAME=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-main" \
  --query "Stacks[0].Outputs[?OutputKey=='AmplifyBranchName'].OutputValue" --output text)
API_BASE_URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-main" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiHttpsUrl'].OutputValue" --output text)
PRESIGN_API_URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-main" \
  --query "Stacks[0].Outputs[?OutputKey=='PresignApiUrl'].OutputValue" --output text)

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${STACK_PREFIX}-frontend-codebuild" \
  --template-file frontend-codebuild.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      FrontendRepoUrl="$FRONTEND_REPO_URL" \
      GitHubBranch="$FRONTEND_BRANCH" \
      AmplifyAppId="$AMPLIFY_APP_ID" \
      AmplifyBranchName="$AMPLIFY_BRANCH_NAME" \
      ApiBaseUrl="$API_BASE_URL" \
      PresignApiUrl="$PRESIGN_API_URL" \
      BuildOutputDir="$FRONTEND_BUILD_OUTPUT_DIR"

FRONTEND_PROJECT=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-frontend-codebuild" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendProjectName'].OutputValue" --output text)

echo "== 6. Building and deploying frontend to Amplify =="
./trigger-builds.sh "$FRONTEND_PROJECT"

echo "== Done. Outputs: =="
aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-main" \
  --query "Stacks[0].Outputs" --output table

echo ""
echo "Optional: to auto-delete everything N hours from now, run:"
echo "  ./schedule-teardown.sh ${STACK_PREFIX}-main 2"