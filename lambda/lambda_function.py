"""Process EventBridge events delivered through an SQS Lambda event source mapping."""
import json
import os
from datetime import datetime, timezone
from urllib.parse import unquote_plus

import boto3

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ.get("AWS_ENDPOINT_URL", "http://floci:4566"),
    region_name=os.environ.get("AWS_REGION", "us-east-1"),
)
OUTPUT_BUCKET = os.environ["OUTPUT_BUCKET"]


def handler(event, context):
    failures = []
    for record in event.get("Records", []):
        message_id = record.get("messageId", "unknown")
        try:
            envelope = json.loads(record["body"])
            detail = envelope["detail"]
            bucket = detail["bucket"]["name"]
            key = unquote_plus(detail["object"]["key"])
            source = s3.get_object(Bucket=bucket, Key=key)
            payload = json.loads(source["Body"].read())
            result = {
                "status": "processed",
                "source": {"bucket": bucket, "key": key},
                "processedAt": datetime.now(timezone.utc).isoformat(),
                "payload": payload,
            }
            output_key = f"processed/{key.rsplit('/', 1)[-1]}.result.json"
            s3.put_object(
                Bucket=OUTPUT_BUCKET,
                Key=output_key,
                Body=json.dumps(result, indent=2).encode(),
                ContentType="application/json",
            )
            print(json.dumps({"status": "processed", "key": key, "output": output_key}))
        except Exception as exc:
            print(json.dumps({"status": "failed", "messageId": message_id, "error": str(exc)}))
            failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}
