
#!/usr/bin/env bash
set -euo pipefail
# Usage: ./schedule-teardown.sh <target-stack-name> <hours-from-now>

REGION="us-east-1"
TARGET_STACK="${1:?Usage: schedule-teardown.sh <target-stack-name> <hours-from-now>}"
HOURS="${2:?Usage: schedule-teardown.sh <target-stack-name> <hours-from-now>}"

DELETE_TIME=$(date -u -d "+${HOURS} hours" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || \
              date -u -v+"${HOURS}"H +"%Y-%m-%dT%H:%M:%S")   # macOS fallback

echo "Scheduling deletion of '${TARGET_STACK}' at ${DELETE_TIME} UTC"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${TARGET_STACK}-auto-teardown" \
  --template-file auto-teardown.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      TargetStackName="$TARGET_STACK" \
      ScheduledDeleteTime="$DELETE_TIME"

echo "Scheduled. To cancel, delete stack '${TARGET_STACK}-auto-teardown' before it fires."
