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

echo "Waiting for Floci..."
for _ in $(seq 1 60); do
  curl -fsS "$AWS_ENDPOINT_URL/" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$AWS_ENDPOINT_URL/" >/dev/null || { echo "Floci is unavailable" >&2; exit 1; }

ACCOUNT=000000000000
INPUT=omsl-serverless-input
OUTPUT=omsl-serverless-output
QUEUE=omsl-serverless-events
DLQ=omsl-serverless-dlq
RULE=omsl-s3-object-created
FUNCTION=omsl-s3-object-processor
ROLE=omsl-serverless-lambda-role

awsx s3api create-bucket --bucket "$INPUT" >/dev/null 2>&1 || true
awsx s3api create-bucket --bucket "$OUTPUT" >/dev/null 2>&1 || true

DLQ_URL="$(awsx sqs create-queue --queue-name "$DLQ" --query QueueUrl --output text)"
DLQ_ARN="$(awsx sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"

QUEUE_URL="$(awsx sqs create-queue --queue-name "$QUEUE" --attributes VisibilityTimeout=60 --query QueueUrl --output text)"

cat >/tmp/omsl-redrive.json <<EOF
{"QueueUrl": "$QUEUE_URL", "Attributes": {"RedrivePolicy": "{\"deadLetterTargetArn\": \"$DLQ_ARN\", \"maxReceiveCount\": \"2\"}"}}
EOF
awsx sqs set-queue-attributes --cli-input-json file:///tmp/omsl-redrive.json >/dev/null

QUEUE_ARN="$(awsx sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"

cat >/tmp/omsl-queue-policy.json <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"AllowEventBridge","Effect":"Allow","Principal":{"Service":"events.amazonaws.com"},"Action":"sqs:SendMessage","Resource":"$QUEUE_ARN"}]}
EOF

python3 -c "
import json
policy = json.load(open('/tmp/omsl-queue-policy.json'))
with open('/tmp/omsl-set-policy.json', 'w') as f:
    json.dump({'QueueUrl': '$QUEUE_URL', 'Attributes': {'Policy': json.dumps(policy, separators=(',', ':'))}}, f)
"
awsx sqs set-queue-attributes --cli-input-json file:///tmp/omsl-set-policy.json >/dev/null

# S3 emits object-created events to EventBridge.
awsx s3api put-bucket-notification-configuration --bucket "$INPUT" --notification-configuration '{"EventBridgeConfiguration":{}}'

cat >/tmp/omsl-event-pattern.json <<EOF
{"source":["aws.s3"],"detail-type":["Object Created"],"detail":{"bucket":{"name":["$INPUT"]}}}
EOF
awsx events put-rule --name "$RULE" --event-pattern file:///tmp/omsl-event-pattern.json --state ENABLED >/dev/null
RULE_ARN="$(awsx events describe-rule --name "$RULE" --query Arn --output text)"
awsx events put-targets --rule "$RULE" --targets "Id=processing-queue,Arn=$QUEUE_ARN" >/dev/null

cat >/tmp/omsl-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
awsx iam create-role --role-name "$ROLE" --assume-role-policy-document file:///tmp/omsl-trust.json >/dev/null 2>&1 || true
cat >/tmp/omsl-lambda-policy.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject"],"Resource":"arn:aws:s3:::$INPUT/*"},{"Effect":"Allow","Action":["s3:PutObject"],"Resource":"arn:aws:s3:::$OUTPUT/*"},{"Effect":"Allow","Action":["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],"Resource":"$QUEUE_ARN"}]}
EOF
awsx iam put-role-policy --role-name "$ROLE" --policy-name omsl-processing --policy-document file:///tmp/omsl-lambda-policy.json

(cd lambda && rm -f function.zip && zip -q function.zip lambda_function.py)
ROLE_ARN="arn:aws:iam::$ACCOUNT:role/$ROLE"
if awsx lambda get-function --function-name "$FUNCTION" >/dev/null 2>&1; then
  awsx lambda update-function-code --function-name "$FUNCTION" --zip-file fileb://lambda/function.zip >/dev/null
else
  awsx lambda create-function --function-name "$FUNCTION" --runtime python3.12 \
    --handler lambda_function.handler --role "$ROLE_ARN" --timeout 20 --memory-size 128 \
    --environment "Variables={OUTPUT_BUCKET=$OUTPUT}" --zip-file fileb://lambda/function.zip >/dev/null
fi

echo "Waiting for Lambda to become Active..."
for _ in $(seq 1 60); do
  STATE="$(awsx lambda get-function-configuration --function-name "$FUNCTION" --query State --output text 2>/dev/null || true)"
  [[ "$STATE" == "Active" ]] && break
  sleep 2
done
MAPPING="$(awsx lambda list-event-source-mappings --function-name "$FUNCTION" --event-source-arn "$QUEUE_ARN" --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || true)"
if [[ -z "$MAPPING" || "$MAPPING" == "None" ]]; then
  awsx lambda create-event-source-mapping --function-name "$FUNCTION" --event-source-arn "$QUEUE_ARN" --batch-size 5 --function-response-types ReportBatchItemFailures >/dev/null
fi

echo "Ready: S3 -> EventBridge -> SQS -> Lambda -> S3"
echo "Input: $INPUT | Output: $OUTPUT | Queue: $QUEUE_URL | DLQ: $DLQ_URL"
echo "EventBridge rule ARN: $RULE_ARN"
