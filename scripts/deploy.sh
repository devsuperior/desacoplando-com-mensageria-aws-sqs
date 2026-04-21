#!/usr/bin/env bash
# deploy.sh — orquestra o provisionamento completo do projeto desacoplando-com-mensageria-aws-sqs na AWS.
# Etapas: ECR -> build/push -> SQS -> ECS.
# Pre-requisitos: aws cli v2 logado, docker rodando, Maven Wrapper presente em cada servico.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ECR_STACK="sqs-poc-ecr"
SQS_STACK="sqs-poc-sqs"
ECS_STACK="sqs-poc-ecs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Validando pre-requisitos"
command -v aws >/dev/null || { echo "aws cli nao encontrado"; exit 1; }
command -v docker >/dev/null || { echo "docker nao encontrado"; exit 1; }
aws sts get-caller-identity --region "$REGION" >/dev/null || { echo "aws cli nao autenticado"; exit 1; }

cd "$ROOT_DIR"

# ========== 1. ECR ==========
echo ""
echo "==> [1/3] Criando stack de ECR ($ECR_STACK)"
aws cloudformation create-stack \
  --region "$REGION" \
  --stack-name "$ECR_STACK" \
  --template-body file://infra/1-ecr.yml

aws cloudformation wait stack-create-complete --region "$REGION" --stack-name "$ECR_STACK"

OUTPUTS_ECR=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$ECR_STACK" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output text)

ACCOUNT_ID=$(echo "$OUTPUTS_ECR" | awk '$1 == "AccountId" {print $2}')
INGESTOR_REPO_URI=$(echo "$OUTPUTS_ECR" | awk '$1 == "IngestorRepositoryUri" {print $2}')
BILLING_REPO_URI=$(echo "$OUTPUTS_ECR" | awk '$1 == "BillingRepositoryUri" {print $2}')

echo "    AccountId: $ACCOUNT_ID"
echo "    Ingestor Repo: $INGESTOR_REPO_URI"
echo "    Billing Repo:  $BILLING_REPO_URI"

# ========== 2. Build & Push ==========
echo ""
echo "==> [2/3] Autenticando Docker no ECR e enviando imagens"
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

./scripts/push-image.sh ms-payment-ingestor "$INGESTOR_REPO_URI"
./scripts/push-image.sh ms-billing "$BILLING_REPO_URI"

# ========== 3. SQS ==========
echo ""
echo "==> [3a/3] Criando stack de SQS ($SQS_STACK)"
aws cloudformation create-stack \
  --region "$REGION" \
  --stack-name "$SQS_STACK" \
  --template-body file://infra/2-sqs.yml

aws cloudformation wait stack-create-complete --region "$REGION" --stack-name "$SQS_STACK"

OUTPUTS_SQS=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$SQS_STACK" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output text)

QUEUE_NAME=$(echo "$OUTPUTS_SQS" | awk '$1 == "BillingQueueName" {print $2}')
QUEUE_ARN=$(echo "$OUTPUTS_SQS" | awk '$1 == "BillingQueueArn" {print $2}')
QUEUE_URL=$(echo "$OUTPUTS_SQS" | awk '$1 == "BillingQueueUrl" {print $2}')

echo "    Queue:     $QUEUE_NAME"
echo "    Queue URL: $QUEUE_URL"

# ========== 4. ECS ==========
echo ""
echo "==> [3b/3] Criando stack de ECS ($ECS_STACK) com 2 services, ALB e Auto Scaling"
aws cloudformation create-stack \
  --region "$REGION" \
  --stack-name "$ECS_STACK" \
  --template-body file://infra/3-ecs.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=IngestorImageUri,ParameterValue="${INGESTOR_REPO_URI}:latest" \
    ParameterKey=BillingImageUri,ParameterValue="${BILLING_REPO_URI}:latest" \
    ParameterKey=BillingQueueName,ParameterValue="$QUEUE_NAME" \
    ParameterKey=BillingQueueArn,ParameterValue="$QUEUE_ARN"

aws cloudformation wait stack-create-complete --region "$REGION" --stack-name "$ECS_STACK"

ALB_URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$ECS_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerUrl'].OutputValue" --output text)

echo ""
echo "============================================================"
echo "Deploy concluido!"
echo "  ALB: $ALB_URL"
echo "  Queue URL: $QUEUE_URL"
echo "  Cluster: sqs-poc-cluster"
echo "============================================================"
echo ""
echo "Proximos passos:"
echo "  ./scripts/smoke-test.sh   # envia um pagamento e valida o fluxo"
echo "  ./scripts/run_k6.sh       # dispara o teste de carga"
echo "  ./scripts/cleanup.sh      # destroi tudo ao final"
