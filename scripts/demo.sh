#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
: "${AWS_DEFAULT_REGION:=us-east-1}"
: "${AWS_ACCESS_KEY_ID:=test}"
: "${AWS_SECRET_ACCESS_KEY:=test}"
export AWS_ENDPOINT_URL AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

awsx() { aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"; }

INPUT=omsl-serverless-input
OUTPUT=omsl-serverless-output
QUEUE=omsl-serverless-events
DLQ=omsl-serverless-dlq
RULE=omsl-s3-object-created
FUNCTION=omsl-s3-object-processor
ROLE=omsl-serverless-lambda-role

PAUSE=3

echo "============================================================"
echo "  AWS Serverless Event-Driven Playground - Demo"
echo "  Endpoint: $AWS_ENDPOINT_URL"
echo "============================================================"
sleep "$PAUSE"

# 1. S3 Buckets
echo ""
echo "------------------------------------------------------------"
echo "  S3 Buckets"
echo "------------------------------------------------------------"
awsx s3api list-buckets --query 'Buckets[].Name' --output table
sleep "$PAUSE"
echo ""
echo "  Input bucket objects:"
awsx s3 ls "s3://$INPUT/" --recursive 2>/dev/null || echo "  (empty)"
sleep "$PAUSE"
echo ""
echo "  Output bucket objects:"
awsx s3 ls "s3://$OUTPUT/" --recursive 2>/dev/null || echo "  (empty)"
sleep "$PAUSE"

# 2. SQS Queues
echo ""
echo "------------------------------------------------------------"
echo "  SQS Queues"
echo "------------------------------------------------------------"
awsx sqs list-queues --query 'QueueUrls[]' --output table
sleep "$PAUSE"
for Q in "$QUEUE" "$DLQ"; do
  URL="$(awsx sqs get-queue-url --queue-name "$Q" --query QueueUrl --output text 2>/dev/null || true)"
  if [[ -n "$URL" && "$URL" != "None" ]]; then
    echo ""
    echo "  Queue: $Q"
    echo "  URL: $URL"
    awsx sqs get-queue-attributes --queue-url "$URL" --attribute-names All \
      --query 'Attributes.{Arn:QueueArn,Created:CreatedTimestamp,ApproximateNumberOfMessages:ApproximateNumberOfMessages,VisibilityTimeout:VisibilityTimeout,RedrivePolicy:RedrivePolicy}' \
      --output table
  fi
  sleep "$PAUSE"
done

# 3. EventBridge Rules
echo ""
echo "------------------------------------------------------------"
echo "  EventBridge Rules"
echo "------------------------------------------------------------"
awsx events list-rules --query 'Rules[].{Name:Name,State:State,EventBusName:EventBusName}' --output table
sleep "$PAUSE"
echo ""
echo "  Rule targets for '$RULE':"
awsx events list-targets-by-rule --rule "$RULE" --query 'Targets[].{Id:Id,Arn:Arn}' --output table
sleep "$PAUSE"

# 4. Lambda Functions
echo ""
echo "------------------------------------------------------------"
echo "  Lambda Functions"
echo "------------------------------------------------------------"
awsx lambda list-functions --query 'Functions[].{FunctionName:FunctionName,Runtime:Runtime,State:State,Handler:Handler,Timeout:Timeout}' --output table
sleep "$PAUSE"
echo ""
echo "  Function configuration: $FUNCTION"
awsx lambda get-function-configuration --function-name "$FUNCTION" \
  --query '{State:State,Runtime:Runtime,Handler:Handler,Timeout:Timeout,MemorySize:MemorySize,Environment:Environment.Variables}' \
  --output table
sleep "$PAUSE"
echo ""
echo "  Event source mappings:"
awsx lambda list-event-source-mappings --function-name "$FUNCTION" \
  --query 'EventSourceMappings[].{UUID:UUID,EventSourceArn:EventSourceArn,State:State,BatchSize:BatchSize}' \
  --output table
sleep "$PAUSE"

# 5. IAM Roles
echo ""
echo "------------------------------------------------------------"
echo "  IAM Roles"
echo "------------------------------------------------------------"
awsx iam list-roles --query 'Roles[].{RoleName:RoleName,Arn:Arn}' --output table
sleep "$PAUSE"
echo ""
echo "  Role policies for '$ROLE':"
awsx iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output table
sleep "$PAUSE"

# 6. End-to-End Test
echo ""
echo "============================================================"
echo "  End-to-End Test: S3 -> EventBridge -> SQS -> Lambda -> S3"
echo "============================================================"
sleep "$PAUSE"
KEY="incoming/order-$(date +%s).json"
OUT_KEY="processed/$(basename "$KEY").result.json"
echo ""
echo "  Uploading example order to s3://$INPUT/$KEY"
awsx s3 cp examples/order.json "s3://$INPUT/$KEY"
sleep "$PAUSE"
echo "  Object created in input bucket - EventBridge rule should fire..."
sleep "$PAUSE"
echo "  Polling output bucket for s3://$OUTPUT/$OUT_KEY ..."
for i in $(seq 1 30); do
  if awsx s3api head-object --bucket "$OUTPUT" --key "$OUT_KEY" >/dev/null 2>&1; then
    echo ""
    echo "  ✓ Result found! Downloading..."
    echo ""
    awsx s3 cp "s3://$OUTPUT/$OUT_KEY" -
    echo ""
    echo "============================================================"
    echo "  Demo complete - flow verified!"
    echo "============================================================"
    exit 0
  fi
  echo "    ... waiting ($i/30)"
  sleep 2
done
echo ""
echo "  Timed out waiting for result."
echo "  Inspect with: docker compose logs --tail=200 floci"
exit 1
