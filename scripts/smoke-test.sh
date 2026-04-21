#!/usr/bin/env bash
# smoke-test.sh — valida o fluxo ingestor -> SQS -> billing em AWS real.
# Le os outputs das stacks, envia 1 pagamento com correlation-id unico, espera a fila zerar
# e confirma o log correspondente no billing.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"

ALB_URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name sqs-poc-ecs \
  --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerUrl'].OutputValue" --output text)

QUEUE_URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name sqs-poc-sqs \
  --query "Stacks[0].Outputs[?OutputKey=='BillingQueueUrl'].OutputValue" --output text)

BILLING_LOG_GROUP=$(aws cloudformation describe-stacks --region "$REGION" --stack-name sqs-poc-ecs \
  --query "Stacks[0].Outputs[?OutputKey=='BillingLogGroupName'].OutputValue" --output text)

CID="smoke-$(date +%s)"
PAYMENT_ID="pay_smoke_$(date +%s)"

echo "==> Health check em $ALB_URL/actuator/health"
curl -sf "$ALB_URL/actuator/health" >/dev/null && echo "    OK" || { echo "    FALHOU"; exit 1; }

echo "==> Enviando pagamento de teste (correlationId=$CID)"
curl -s -X POST "$ALB_URL/api/payments/webhook" \
  -H "Content-Type: application/json" \
  -H "X-Correlation-ID: $CID" \
  -d "{\"paymentId\":\"$PAYMENT_ID\",\"amount\":299.90,\"currency\":\"BRL\",\"status\":\"succeeded\",\"createdAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
  | head -c 200
echo ""

echo "==> Aguardando fila zerar (timeout 60s)"
for i in $(seq 1 30); do
  COUNT=$(aws sqs get-queue-attributes --region "$REGION" \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' --output text)
  echo "    tentativa $i: mensagens na fila = $COUNT"
  if [[ "$COUNT" == "0" ]]; then break; fi
  sleep 2
done

echo "==> Buscando correlation-id nos logs do billing (ultimos 5 min)"
MSYS_NO_PATHCONV=1 aws logs filter-log-events --region "$REGION" \
  --log-group-name "$BILLING_LOG_GROUP" \
  --start-time $(( ($(date +%s) - 300) * 1000 )) \
  --filter-pattern "$CID" \
  --query 'events[].message' --output text | head -20

echo ""
echo "==> Smoke-test concluido."
