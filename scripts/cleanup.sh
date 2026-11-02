#!/usr/bin/env bash
set -Eeuo pipefail
: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
awsx() { aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"; }
FUNCTION=omsl-s3-object-processor
RULE=omsl-s3-object-created
ROLE=omsl-serverless-lambda-role

for UUID in $(awsx lambda list-event-source-mappings --function-name "$FUNCTION" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null || true); do
  awsx lambda delete-event-source-mapping --uuid "$UUID" >/dev/null || true
done
awsx lambda delete-function --function-name "$FUNCTION" >/dev/null 2>&1 || true
awsx events remove-targets --rule "$RULE" --ids processing-queue >/dev/null 2>&1 || true
awsx events delete-rule --name "$RULE" >/dev/null 2>&1 || true
for Q in omsl-serverless-events omsl-serverless-dlq; do
  URL="$(awsx sqs get-queue-url --queue-name "$Q" --query QueueUrl --output text 2>/dev/null || true)"
  [[ -n "$URL" && "$URL" != "None" ]] && awsx sqs delete-queue --queue-url "$URL" >/dev/null || true
done
for B in omsl-serverless-input omsl-serverless-output; do
  awsx s3 rm "s3://$B" --recursive >/dev/null 2>&1 || true
  awsx s3api delete-bucket --bucket "$B" >/dev/null 2>&1 || true
done
awsx iam delete-role-policy --role-name "$ROLE" --policy-name omsl-processing >/dev/null 2>&1 || true
awsx iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
echo "Resources removed. Stop Floci with: docker compose down -v"
