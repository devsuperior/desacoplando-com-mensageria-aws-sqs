#!/usr/bin/env bash
# push-image.sh faz build do JAR, build Docker e push para o ECR.
# Uso: ./scripts/push-image.sh <diretorio-do-servico> <repo-uri>
# Exemplo: ./scripts/push-image.sh ms-payment-ingestor 789254323955.dkr.ecr.us-east-1.amazonaws.com/sqs-poc-ingestor

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Uso: $0 <diretorio-do-servico> <repo-uri>" >&2
  exit 1
fi

SERVICE_DIR="$1"
REPO_URI="$2"
IMAGE_NAME=$(basename "$SERVICE_DIR")

echo "==> Compilando $IMAGE_NAME com Maven Wrapper"
(cd "$SERVICE_DIR" && ./mvnw clean package -DskipTests -q)

echo "==> Gerando imagem Docker $IMAGE_NAME"
docker build -t "$IMAGE_NAME" "$SERVICE_DIR"

echo "==> Taggeando e enviando para $REPO_URI:latest"
docker tag "$IMAGE_NAME":latest "$REPO_URI":latest
docker push "$REPO_URI":latest

echo "==> $IMAGE_NAME publicada em $REPO_URI:latest"
