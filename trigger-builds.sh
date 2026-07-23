#!/usr/bin/env bash
set -euo pipefail
# Usage: ./trigger-builds.sh <orders-project> <users-project> <products-project>

REGION="us-east-1"
PROJECTS=("$@")

if [ "${#PROJECTS[@]}" -lt 1 ]; then
  echo "Usage: $0 <project-name> [project-name...]"
  exit 1
fi

echo "== Starting builds: ${PROJECTS[*]} =="
BUILD_IDS=()
for p in "${PROJECTS[@]}"; do
  id=$(aws codebuild start-build --region "$REGION" --project-name "$p" --query 'build.id' --output text)
  echo "  $p -> $id"
  BUILD_IDS+=("$id")
done

echo "== Waiting for builds to finish =="
while true; do
  sleep 15
  STATUSES=$(aws codebuild batch-get-builds --region "$REGION" --ids "${BUILD_IDS[@]}" \
    --query 'builds[].{name:projectName,status:buildStatus}' --output text)
  echo "--- $(date -u +%H:%M:%S) ---"
  echo "$STATUSES"

  if ! echo "$STATUSES" | grep -q "IN_PROGRESS"; then
    break
  fi
done

if echo "$STATUSES" | grep -qv "SUCCEEDED"; then
  if echo "$STATUSES" | grep -q "FAILED\|FAULT\|STOPPED\|TIMED_OUT"; then
    echo "One or more builds did not succeed. Check CodeBuild console/logs."
    exit 1
  fi
fi

echo "== All builds succeeded =="