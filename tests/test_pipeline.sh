#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
./scripts/bootstrap.sh
./scripts/demo.sh
echo "PASS: end-to-end serverless pipeline"
