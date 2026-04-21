#!/usr/bin/env bash
# cleanup.sh — destroi toda a infraestrutura provisionada pelo projeto desacoplando-com-mensageria-aws-sqs.
# As 3 stacks (ECS, ECR, SQS) sao independentes no CloudFormation, entao o delete roda em PARALELO.
# ECR exige limpar imagens antes do delete-stack (CloudFormation recusa repos com imagens).

set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
ECR_STACK="sqs-poc-ecr"
SQS_STACK="sqs-poc-sqs"
ECS_STACK="sqs-poc-ecs"

delete_stack_if_exists() {
  local name="$1"
  if aws cloudformation describe-stacks --region "$REGION" --stack-name "$name" >/dev/null 2>&1; then
    echo "==> Disparando delete-stack $name"
    aws cloudformation delete-stack --region "$REGION" --stack-name "$name"
  else
    echo "==> Stack $name nao existe, pulando"
  fi
}

wait_stack_deleted() {
  local name="$1"
  if aws cloudformation describe-stacks --region "$REGION" --stack-name "$name" >/dev/null 2>&1; then
    echo "==> Aguardando $name finalizar delete..."
    aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$name" \
      && echo "    $name removida" \
      || echo "    $name: wait falhou (verifique no console)"
  fi
}

delete_repo_if_exists() {
  local name="$1"
  if aws ecr describe-repositories --region "$REGION" --repository-names "$name" >/dev/null 2>&1; then
    echo "==> Limpando repositorio ECR $name (force)"
    aws ecr delete-repository --region "$REGION" --repository-name "$name" --force >/dev/null
  fi
}

delete_log_group_if_exists() {
  local name="$1"
  # MSYS_NO_PATHCONV=1 evita que o GitBash converta /ecs/... para C:/Program Files/Git/ecs/...
  if MSYS_NO_PATHCONV=1 aws logs describe-log-groups --region "$REGION" \
       --log-group-name-prefix "$name" --query "logGroups[?logGroupName=='$name']" \
       --output text 2>/dev/null | grep -q "$name"; then
    echo "==> Deletando log group $name"
    MSYS_NO_PATHCONV=1 aws logs delete-log-group --region "$REGION" --log-group-name "$name"
  fi
}

echo "==> Disparando deletes em paralelo (ECS + ECR + SQS sao independentes)"

# 1. Pre-condicao do ECR: limpar imagens antes do delete-stack
delete_repo_if_exists "sqs-poc-ingestor"
delete_repo_if_exists "sqs-poc-billing"

# 2. Dispara os 3 deletes em paralelo
delete_stack_if_exists "$ECS_STACK"
delete_stack_if_exists "$ECR_STACK"
delete_stack_if_exists "$SQS_STACK"

# 3. Aguarda os 3 em paralelo (cada wait roda em background)
wait_stack_deleted "$ECS_STACK" &
PID_ECS=$!
wait_stack_deleted "$ECR_STACK" &
PID_ECR=$!
wait_stack_deleted "$SQS_STACK" &
PID_SQS=$!

wait $PID_ECS
wait $PID_ECR
wait $PID_SQS

# 4. Log groups (sobrevivem a stack delete se nao forem associados via CloudFormation LogGroup retention)
delete_log_group_if_exists "/ecs/sqs-poc-ingestor"
delete_log_group_if_exists "/ecs/sqs-poc-billing"

echo ""
echo "==> Cleanup concluido."
