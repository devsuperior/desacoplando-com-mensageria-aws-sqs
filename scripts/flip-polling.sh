#!/usr/bin/env bash
# flip-polling.sh alterna o billing entre long (20s) e short (0s) polling.
# Registra uma nova task definition revision com SQS_WAIT_TIME_SECONDS ajustado
# e dispara rolling deployment. Sem dependência de jq (o JSON da task def é
# reconstruído inline).
#
# Uso: ./scripts/flip-polling.sh short|long

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  short) WAIT_VALUE="0"  ;;
  long)  WAIT_VALUE="20" ;;
  *) echo "Uso: $0 short|long" >&2; exit 1 ;;
esac

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/sqs-poc-billing:latest"
TD_FILE="./billing-td.tmp.json"

cat > "$TD_FILE" <<EOF
{
    "family": "sqs-poc-billing",
    "taskRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/sqs-poc-billing-task-role",
    "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/sqs-poc-ecs-execution-role",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512",
    "memory": "1024",
    "containerDefinitions": [
        {
            "name": "billing",
            "image": "${IMAGE_URI}",
            "essential": true,
            "portMappings": [{"containerPort": 8082, "protocol": "tcp"}],
            "environment": [
                {"name": "AWS_REGION", "value": "${REGION}"},
                {"name": "BILLING_QUEUE_NAME", "value": "sqs-poc-billing-queue"},
                {"name": "SQS_MAX_MESSAGES_PER_POLL", "value": "10"},
                {"name": "SQS_WAIT_TIME_SECONDS", "value": "${WAIT_VALUE}"}
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/sqs-poc-billing",
                    "awslogs-region": "${REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ]
}
EOF

echo "==> Registrando nova task definition com SQS_WAIT_TIME_SECONDS=${WAIT_VALUE}"
NEW_TD=$(MSYS_NO_PATHCONV=1 aws ecs register-task-definition \
  --region "$REGION" \
  --cli-input-json "file://$TD_FILE" \
  --query "taskDefinition.taskDefinitionArn" --output text)

rm -f "$TD_FILE"

echo "    $NEW_TD"
echo "==> Disparando rolling deployment no service sqs-poc-billing"
aws ecs update-service \
  --region "$REGION" \
  --cluster sqs-poc-cluster \
  --service sqs-poc-billing \
  --task-definition "$NEW_TD" \
  --force-new-deployment \
  --query "service.{Desired:desiredCount}" --output text >/dev/null

echo "==> Billing agora com ${MODE} polling (SQS_WAIT_TIME_SECONDS=${WAIT_VALUE})."
echo "    Aguarde ~3 min para o rolling deployment terminar."
