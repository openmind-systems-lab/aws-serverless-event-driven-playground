#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
awsx() { aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"; }
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '{ invalid json\n' > "$TMP"
KEY="incoming/invalid-$(date +%s).json"
awsx s3 cp "$TMP" "s3://omsl-serverless-input/$KEY" >/dev/null
URL="$(awsx sqs get-queue-url --queue-name omsl-serverless-dlq --query QueueUrl --output text)"
echo "Waiting for the failed event to reach the DLQ..."
for _ in $(seq 1 100); do
  COUNT="$(awsx sqs get-queue-attributes --queue-url "$URL" --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text)"
  if [[ "$COUNT" =~ ^[0-9]+$ ]] && (( COUNT > 0 )); then
    echo "PASS: failed message reached the DLQ"
    awsx sqs receive-message --queue-url "$URL" --max-number-of-messages 1
    exit 0
  fi
  sleep 3
done
echo "FAIL: DLQ did not receive a message in the observation window" >&2
exit 1
