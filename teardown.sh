#!/usr/bin/env bash
set -euo pipefail
# Usage: ./teardown.sh <stack-prefix> [region]
# Example: ./teardown.sh microservice-demo
#          ./teardown.sh microservice-demo-networked us-west-2

STACK_PREFIX="${1:?Usage: $0 <stack-prefix> [region]}"
REGION="${2:-us-east-1}"

echo "== Tearing down everything under prefix: ${STACK_PREFIX} (region: ${REGION}) =="

echo "== Emptying S3 bucket (RDS/DynamoDB/ECR clean up on their own) =="
BUCKET=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-main" \
  --query "Stacks[0].Outputs[?OutputKey=='ImagesBucketName'].OutputValue" --output text 2>/dev/null || echo "")

if [ -n "$BUCKET" ]; then
  aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION" || true
fi

echo "== Deleting main stack (ECS, ALB, RDS, DynamoDB, Lambda, API GW, Amplify) =="
aws cloudformation delete-stack --region "$REGION" --stack-name "${STACK_PREFIX}-main" 2>/dev/null || true
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${STACK_PREFIX}-main" 2>/dev/null || true

echo "== Deleting frontend CodeBuild stack (if it exists) =="
aws cloudformation delete-stack --region "$REGION" --stack-name "${STACK_PREFIX}-frontend-codebuild" 2>/dev/null || true
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${STACK_PREFIX}-frontend-codebuild" 2>/dev/null || true

echo "== Deleting CodeBuild projects stack (if it exists) =="
aws cloudformation delete-stack --region "$REGION" --stack-name "${STACK_PREFIX}-codebuild" 2>/dev/null || true
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${STACK_PREFIX}-codebuild" 2>/dev/null || true

echo "== Deleting ECR bootstrap stack (images auto-emptied via EmptyOnDelete) =="
aws cloudformation delete-stack --region "$REGION" --stack-name "${STACK_PREFIX}-ecr" 2>/dev/null || true
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${STACK_PREFIX}-ecr" 2>/dev/null || true

echo "== Also checking for an auto-teardown schedule stack =="
aws cloudformation delete-stack --region "$REGION" --stack-name "${STACK_PREFIX}-main-auto-teardown" 2>/dev/null || true

echo "== Done tearing down: ${STACK_PREFIX} =="