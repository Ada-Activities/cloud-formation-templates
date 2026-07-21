#!/usr/bin/env bash
set -euo pipefail

REGION="us-east-1"
STACK_PREFIX="e-commerce-demo"

echo "== Emptying S3 bucket (RDS/DynamoDB/ECR clean up on their own) =="
BUCKET=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "${STACK_PREFIX}-main" \
  --query "Stacks[0].Outputs[?OutputKey=='ImagesBucketName'].OutputValue" --output text 2>/dev/null || echo "")

if [ -n "$BUCKET" ]; then
  aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION" || true
fi

echo "== Deleting main stack (ECS, ALB, RDS, DynamoDB, Lambda, API GW, Amplify) =="
aws cloudformation delete-stack --region "$REGION" --stack-name "${STACK_PREFIX}-main"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${STACK_PREFIX}-main"

echo "== Deleting frontend CodeBuild stack (if it exists) =="
aws cloudformation delete-stack --region "$REGION" --stack-name "${STACK_PREFIX}-frontend-codebuild" 2>/dev/null || true
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${STACK_PREFIX}-frontend-codebuild" 2>/dev/null || true

echo "== Deleting ECR bootstrap stack (images auto-emptied via EmptyOnDelete) =="
aws cloudformation delete-stack --region "$REGION" --stack-name "${STACK_PREFIX}-ecr"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${STACK_PREFIX}-ecr"

echo "== Deleting CodeBuild projects stack (if it exists) =="
aws cloudformation delete-stack --region "$REGION" --stack-name "${STACK_PREFIX}-codebuild" 2>/dev/null || true
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${STACK_PREFIX}-codebuild" 2>/dev/null || true

echo "== Done. Everything torn down. =="