#!/usr/bin/env bash
# run_k6.sh — dispara teste de carga contra o ALB usando grafana/k6 em Docker.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ALB_URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name sqs-poc-ecs \
  --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerUrl'].OutputValue" --output text)

echo "==> Teste de carga contra $ALB_URL"
echo "    Stages: 30s ramp-up 80 VUs -> 120s 150 VUs -> 30s pico 200 VUs -> 30s ramp-down"
echo ""

cd "$ROOT_DIR"
# pwd -W retorna o path Windows nativo (C:/...) no GitBash; em Linux/macOS, cai no fallback.
ROOT_MOUNT=$(pwd -W 2>/dev/null || pwd)
MSYS_NO_PATHCONV=1 docker run --rm -i \
  -v "$ROOT_MOUNT:/workspace" \
  -w /workspace \
  -e BASE_URL="$ALB_URL" \
  grafana/k6:latest run k6/load-test.js

echo ""
echo "==> Monitore em paralelo:"
echo "  aws ecs describe-services --cluster sqs-poc-cluster --services sqs-poc-billing \\"
echo "    --query 'services[0].{Desired:desiredCount,Running:runningCount}'"
echo "  aws cloudwatch get-metric-statistics --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible \\"
echo "    --dimensions Name=QueueName,Value=sqs-poc-billing-queue --statistics Average \\"
echo "    --start-time \$(date -u -d '5 min ago' +%Y-%m-%dT%H:%M:%SZ) \\"
echo "    --end-time \$(date -u +%Y-%m-%dT%H:%M:%SZ) --period 60"
