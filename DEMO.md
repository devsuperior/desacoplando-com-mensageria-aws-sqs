# Demo: Desacoplando com Mensageria no AWS SQS

## 1. Introdução

Esta demo valida o projeto completo em **AWS real**. Dois microsserviços Spring Boot (ingestor e billing) conversam via SQS Standard, orquestrados pelo ECS Fargate atrás de um Application Load Balancer.

Inclui IAM granular por serviço, consumo em batch, polling configurável, correlation-id rastreável de ponta a ponta e Step Scaling do ingestor reagindo à CPU.

**O que vamos fazer:**

- Provisionar a infraestrutura completa via CloudFormation (ECR, SQS, ECS Fargate + ALB).
- Inspecionar a fila no console AWS e pelo CLI.
- Verificar que o correlation-id viaja do HTTP até o log, passando pelo SQS como Message Attribute.
- Derrubar o billing de propósito e confirmar que nenhuma mensagem se perde.
- Disparar carga com Grafana k6 e acompanhar o Step Scaling do ingestor subir as tasks.
- Comparar short polling e long polling pela métrica `NumberOfEmptyReceives`.

**Ambiente:**

- **Região:** `us-east-1`
- **Cluster ECS:** `sqs-poc-cluster`
- **Services ECS:** `sqs-poc-ingestor`, `sqs-poc-billing`
- **Fila SQS:** `sqs-poc-billing-queue`
- **Log groups:** `/ecs/sqs-poc-ingestor`, `/ecs/sqs-poc-billing`

---

## 2. Provisionamento da Infraestrutura

### 2.1 Autenticar a AWS CLI

Obtenha credenciais temporárias e confirme que está na região correta:

```bash
aws login
```

*Se solicitada uma região, digite `us-east-1`.*

Verifique o acesso:

```bash
aws ec2 describe-regions --region-names us-east-1 --output table
```

Se a tabela com a região aparecer, o CLI está autenticado.

### 2.2 Criar Repositório ECR

O **Amazon ECR** armazena as imagens Docker da aplicação. É o primeiro a subir porque o ECS depende das imagens para iniciar as tasks.

📁 [`infra/1-ecr.yml`](infra/1-ecr.yml)

```bash
aws cloudformation create-stack \
  --stack-name sqs-poc-ecr \
  --template-body file://infra/1-ecr.yml

aws cloudformation wait stack-create-complete \
  --stack-name sqs-poc-ecr
```

Exporte os outputs da stack em variáveis locais:

```bash
OUTPUTS_ECR=$(aws cloudformation describe-stacks --stack-name sqs-poc-ecr \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output text)

export ACCOUNT_ID=$(echo "$OUTPUTS_ECR" | awk '$1 == "AccountId" {print $2}')
export INGESTOR_REPO_URI=$(echo "$OUTPUTS_ECR" | awk '$1 == "IngestorRepositoryUri" {print $2}')
export BILLING_REPO_URI=$(echo "$OUTPUTS_ECR" | awk '$1 == "BillingRepositoryUri" {print $2}')

echo "Account: $ACCOUNT_ID"
echo "Ingestor repo: $INGESTOR_REPO_URI"
echo "Billing repo:  $BILLING_REPO_URI"
```

**Saída:**

```
Account: ****************
Ingestor repo: ****************.dkr.ecr.us-east-1.amazonaws.com/sqs-poc-ingestor
Billing repo:  ****************.dkr.ecr.us-east-1.amazonaws.com/sqs-poc-billing
```

### 2.3 Build e Push das Imagens Docker

O login via `aws ecr get-login-password` gera um token temporário para o Docker autenticar no ECR.

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com

# ms-payment-ingestor
(cd ms-payment-ingestor && ./mvnw clean package -DskipTests)
docker build -t ms-payment-ingestor ms-payment-ingestor
docker tag ms-payment-ingestor:latest ${INGESTOR_REPO_URI}:latest
docker push ${INGESTOR_REPO_URI}:latest

# ms-billing
(cd ms-billing && ./mvnw clean package -DskipTests)
docker build -t ms-billing ms-billing
docker tag ms-billing:latest ${BILLING_REPO_URI}:latest
docker push ${BILLING_REPO_URI}:latest
```

### 2.4 Criar a Fila SQS

A fila Standard fica em stack separada para manter o ciclo de vida da mensageria independente do backend. No template você ajusta atributos de negócio: `VisibilityTimeout` (60s aqui), `MessageRetentionPeriod` (4 dias), `ReceiveMessageWaitTimeSeconds` para long polling (20s), `DelaySeconds` e `RedrivePolicy` para DLQ.

📁 [`infra/2-sqs.yml`](infra/2-sqs.yml)

```bash
aws cloudformation create-stack \
  --stack-name sqs-poc-sqs \
  --template-body file://infra/2-sqs.yml

aws cloudformation wait stack-create-complete \
  --stack-name sqs-poc-sqs

OUTPUTS_SQS=$(aws cloudformation describe-stacks --stack-name sqs-poc-sqs \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output text)

export QUEUE_NAME=$(echo "$OUTPUTS_SQS" | awk '$1 == "BillingQueueName" {print $2}')
export QUEUE_ARN=$(echo "$OUTPUTS_SQS"  | awk '$1 == "BillingQueueArn" {print $2}')
export QUEUE_URL=$(echo "$OUTPUTS_SQS"  | awk '$1 == "BillingQueueUrl" {print $2}')
```

### 2.5 Criar a Infraestrutura ECS

Esta stack cria o cluster ECS, VPC, subnets Multi-AZ, ALB, Security Groups, IAM Roles separadas por serviço e a política de Step Scaling do ingestor com alarmes CloudWatch.

A flag `CAPABILITY_NAMED_IAM` é obrigatória: criamos roles com nomes fixos para facilitar auditoria. Para entender cada componente em detalhe, o artigo [Deploy de aplicações na AWS com ECS Fargate](https://devsuperior.com.br/blog/deploy-de-aplicacoes-na-aws-com-ecs-fargate) cobre o padrão que seguimos aqui.

📁 [`infra/3-ecs.yml`](infra/3-ecs.yml) — principais recursos:

```yaml
# Multi-AZ: duas subnets públicas em us-east-1a e us-east-1b
PublicSubnetA:
PublicSubnetB:

# IAM granular por serviço
IngestorTaskRole:    # sqs:SendMessage + sqs:GetQueueUrl
BillingTaskRole:     # sqs:ReceiveMessage + sqs:DeleteMessage + sqs:GetQueueAttributes

# Auto Scaling do ingestor
IngestorScalableTarget:      # Min 2, Max 6
IngestorStepScaleOutPolicy:  # CPU > 25% → +1 / +2 tasks
IngestorStepScaleInPolicy:   # CPU < 10% → -1 task
```

```bash
aws cloudformation create-stack \
  --stack-name sqs-poc-ecs \
  --template-body file://infra/3-ecs.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=IngestorImageUri,ParameterValue=${INGESTOR_REPO_URI}:latest \
    ParameterKey=BillingImageUri,ParameterValue=${BILLING_REPO_URI}:latest \
    ParameterKey=BillingQueueName,ParameterValue=${QUEUE_NAME} \
    ParameterKey=BillingQueueArn,ParameterValue=${QUEUE_ARN}

aws cloudformation wait stack-create-complete --stack-name sqs-poc-ecs

export ALB_URL=$(aws cloudformation describe-stacks --stack-name sqs-poc-ecs \
  --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerUrl'].OutputValue" --output text)

echo "ALB URL: $ALB_URL"
```

**Saída:**

```
ALB URL: http://sqs-poc-alb-**********.us-east-1.elb.amazonaws.com
```

Este é o endpoint público do ingestor. O ALB distribui as requisições entre as tasks ECS e faz health checks automáticos em `/actuator/health`.

> 💡 O script [`scripts/deploy.sh`](scripts/deploy.sh) encadeia todos os comandos acima em uma única execução.

### 2.6 Verificar os Services Rodando

```bash
aws ecs describe-services \
  --cluster sqs-poc-cluster \
  --services sqs-poc-ingestor sqs-poc-billing \
  --query "services[*].{Name:serviceName,Desired:desiredCount,Running:runningCount,Pending:pendingCount}" \
  --output table
```

**Saída:**

```
+---------+-------------------+---------+---------+
| Desired |       Name        | Pending | Running |
+---------+-------------------+---------+---------+
|  2      |  sqs-poc-ingestor |  0      |  2      |
|  1      |  sqs-poc-billing  |  0      |  1      |
+---------+-------------------+---------+---------+
```

Teste o health check do ALB:

```bash
curl -s $ALB_URL/actuator/health
```

**Saída:**

```json
{"status":"UP"}
```

---

## 3. Overview do SQS no Console AWS

Abra **Console AWS > SQS > Filas > sqs-poc-billing-queue**. As métricas principais:

- **Messages available** (`ApproximateNumberOfMessagesVisible`): prontas para serem consumidas.
- **Messages in flight** (`ApproximateNumberOfMessagesNotVisible`): entregues a um consumidor, dentro do Visibility Timeout (60s).
- **Default visibility timeout:** 60s (conforme `infra/2-sqs.yml`).
- **Receive message wait time:** 20s (long polling ativo).

Peek sem consumir (debug clássico):

```bash
aws sqs receive-message --queue-url $QUEUE_URL \
  --max-number-of-messages 1 \
  --visibility-timeout 0 \
  --message-attribute-names All
```

O `--visibility-timeout 0` devolve a mensagem imediatamente, permitindo inspecionar sem afetar o consumidor.

Atributos completos da fila via CLI:

```bash
aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names All \
  --query "Attributes.{VisibilityTimeout:VisibilityTimeout,LongPollingSeconds:ReceiveMessageWaitTimeSeconds,Available:ApproximateNumberOfMessages,InFlight:ApproximateNumberOfMessagesNotVisible}" \
  --output table
```

**Saída:**

```
+---------------------+------+
|  Available          |  0   |
|  InFlight           |  0   |
|  LongPollingSeconds |  20  |
|  VisibilityTimeout  |  60  |
+---------------------+------+
```

---

## 4. Headers SQS: Correlation-ID de Ponta a Ponta

O filter `CorrelationIdFilter` gera ou propaga o header `X-Correlation-ID` em toda requisição HTTP. O `PaymentQueueService` envia esse valor como SQS Message Attribute nativo, junto de `X-Source`. O listener do billing recebe os dois via `@Header` e os joga no MDC do logback, deixando cada linha rastreável.

Envie um pagamento com correlation-id explícito:

```bash
curl -X POST $ALB_URL/api/payments/webhook \
  -H "Content-Type: application/json" \
  -H "X-Correlation-ID: demo-headers-001" \
  -d '{"paymentId":"pay_headers_01","amount":299.90,"currency":"BRL","status":"succeeded","createdAt":"2026-04-20T10:00:00Z"}'
```

**Saída:**

```json
{"correlationId":"demo-headers-001","status":"accepted"}
```

Espie o Message Attribute diretamente na fila (antes do billing consumir). Se o billing estiver rápido demais, derrube-o temporariamente (seção 5.1):

```bash
aws sqs receive-message --queue-url $QUEUE_URL \
  --visibility-timeout 0 \
  --message-attribute-names All \
  --query "Messages[0].{Body:Body,Attributes:MessageAttributes}"
```

**Saída:**

```json
{
    "Body": "{\"paymentId\":\"pay_headers_01\",\"amount\":299.90,\"currency\":\"BRL\",\"status\":\"succeeded\",\"createdAt\":\"2026-04-20T10:00:00Z\"}",
    "Attributes": {
        "X-Correlation-ID": { "StringValue": "demo-headers-001",     "DataType": "String" },
        "X-Source":         { "StringValue": "ms-payment-ingestor",   "DataType": "String" },
        "contentType":      { "StringValue": "application/json",      "DataType": "String" }
    }
}
```

No **CloudWatch Logs Insights**, selecione o log group `/ecs/sqs-poc-billing` e rode:

```
fields @timestamp, @message
| filter @message like /demo-headers-001/
| sort @timestamp asc
| limit 50
```

**Saída esperada** (padrão `[cid=... src=...]` do `logback-spring.xml`):

```
23:42:41 INFO [sqsListenerEndpointContainer#0-1] [cid=demo-headers-001 src=ms-payment-ingestor] BillingQueueListener - Pagamento recebido da fila: pay_headers_01
23:42:50 INFO [sqsListenerEndpointContainer#0-1] [cid=demo-headers-001 src=ms-payment-ingestor] BillingProcessorService - Fatura persistida para pagamento pay_headers_01 — líquido: 57.98 USD
```

O mesmo correlation-id aparece do controller até a persistência. Rastreabilidade ponta a ponta, sem tabela de correlação extra.

---

## 5. Resiliência: Parar o Billing e Não Perder Pagamentos

A principal promessa do desacoplamento: se o consumidor cair, o produtor continua aceitando requisições e a fila segura tudo até o consumidor voltar. Vamos validar isso na prática.

### 5.1 Derruba o billing

```bash
aws ecs update-service \
  --cluster sqs-poc-cluster \
  --service sqs-poc-billing \
  --desired-count 0
```

Aguarde alguns segundos e confirme que `Running` está em 0:

```bash
aws ecs describe-services --cluster sqs-poc-cluster --services sqs-poc-billing \
  --query "services[0].{Desired:desiredCount,Running:runningCount}" --output table
```

**Saída:**

```
+---------+---------+
| Desired | Running |
+---------+---------+
|   0     |   0     |
+---------+---------+
```

### 5.2 Envia 3 pagamentos com o consumidor fora do ar

```bash
for i in 01 02 03; do
  curl -s -X POST $ALB_URL/api/payments/webhook \
    -H "Content-Type: application/json" \
    -H "X-Correlation-ID: demo-resilience-$i" \
    -d "{\"paymentId\":\"pay_res_$i\",\"amount\":$((100 + RANDOM % 500)).90,\"currency\":\"BRL\",\"status\":\"succeeded\",\"createdAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
  echo ""
done
```

Cada um responde `202 Accepted` imediatamente. Aguarde ~10 segundos para a métrica do SQS consolidar (são *approximate*) e verifique a fila:

```bash
sleep 10
aws sqs get-queue-attributes --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --query "Attributes" --output table
```

**Saída:**

```
+-------------------------------+----------------------------------+
| ApproximateNumberOfMessages   | ApproximateNumberOfMessagesNotVisible |
+-------------------------------+----------------------------------+
|              3                |                0                 |
+-------------------------------+----------------------------------+
```

### 5.3 Restaura o billing e observa a drenagem

```bash
aws ecs update-service \
  --cluster sqs-poc-cluster \
  --service sqs-poc-billing \
  --desired-count 1
```

Acompanhe os logs em tempo real:

```bash
aws logs tail /ecs/sqs-poc-billing --since 10m --follow
```

Os três correlation-ids aparecem nos logs, processados em paralelo por threads `sqsListenerEndpointContainer#0-1`, `#0-2`, `#0-3`. Essa paralelização é o consumo em batch em ação: `maxMessagesPerPoll=10` puxa até dez mensagens por `ReceiveMessage` e o container as processa concorrentemente.

Nenhum pagamento se perdeu. O SQS segurou as três mensagens dentro do `MessageRetentionPeriod` (4 dias) e o billing consumiu tudo quando voltou.

---

## 6. Teste de Carga com k6 e Auto Scaling

Dispare o script (stages `0 → 80 → 150 → 200 → 0` VUs em cerca de 3m30s):

```bash
./scripts/run_k6.sh
```

Em terminais paralelos, observe o Step Scaling do ingestor reagir:

```bash
# Task count do ingestor
watch -n 5 'aws ecs describe-services --cluster sqs-poc-cluster \
  --services sqs-poc-ingestor \
  --query "services[0].{Desired:desiredCount,Running:runningCount}" \
  --output table'

# Fila enchendo e drenando em tempo real
watch -n 5 'aws sqs get-queue-attributes --queue-url '"$QUEUE_URL"' \
  --attribute-names ApproximateNumberOfMessages --output text'

# Estado do alarme
aws cloudwatch describe-alarms \
  --alarm-names sqs-poc-ingestor-high-cpu \
  --query "MetricAlarms[].{Name:AlarmName,State:StateValue,Threshold:Threshold}" \
  --output table
```

**Saída capturada em uma execução:**

```
█ TOTAL RESULTS
  checks_total.......: 37440   178.24/s
  checks_succeeded...: 100.00% 37440 out of 37440
  http_req_failed....: 0.00%   0 out of 18720
  http_reqs..........: 18720   89.12/s
  http_req_duration..: p(95)=4.03s
```

O ingestor escalou de 2 para 4 tasks durante o pico respondendo ao alarme `sqs-poc-ingestor-high-cpu` (CPU > 25% por 60s). Zero pagamento perdido mesmo com p95 de 4s.

Para listar as atividades de scaling registradas:

```bash
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id service/sqs-poc-cluster/sqs-poc-ingestor \
  --max-items 5 \
  --query "ScalingActivities[].{Time:StartTime,Desc:Description,Cause:Cause,Status:StatusCode}" \
  --output table
```

---

## 7. Tuning do Consumo SQS

Para ir além do default — alternar short vs long polling em runtime, ajustar batch size, escolher acknowledgement modes e explorar single vs batch listener — siga o guia dedicado em [TUNNING-SQS.md](TUNNING-SQS.md). Ele tem os diagramas e um experimento prático com métrica `NumberOfEmptyReceives` mostrando ao vivo o custo do short polling.

---

## 8. Cleanup

O projeto mantém dois Services ECS rodando 24/7 enquanto estiver provisionado. Mesmo com Fargate elegível para free-tier, ALB e VPC continuam gerando custo. Sempre limpe o ambiente ao final.

Tudo de uma vez:

```bash
./scripts/cleanup.sh
```

Ou manualmente. As três stacks são independentes no CloudFormation, então as deletes podem rodar em paralelo. Só lembre de limpar as imagens do ECR antes, pois o CloudFormation se recusa a deletar repositório com imagens dentro:

```bash
# 1. Limpa imagens do ECR (força delete)
aws ecr delete-repository --repository-name sqs-poc-ingestor --force
aws ecr delete-repository --repository-name sqs-poc-billing  --force

# 2. Dispara as 3 deletes em paralelo
aws cloudformation delete-stack --stack-name sqs-poc-ecs &
aws cloudformation delete-stack --stack-name sqs-poc-ecr &
aws cloudformation delete-stack --stack-name sqs-poc-sqs &
wait

# 3. Aguarda cada uma completar
aws cloudformation wait stack-delete-complete --stack-name sqs-poc-ecs
aws cloudformation wait stack-delete-complete --stack-name sqs-poc-ecr
aws cloudformation wait stack-delete-complete --stack-name sqs-poc-sqs

# 4. Log groups remanescentes
MSYS_NO_PATHCONV=1 aws logs delete-log-group --log-group-name /ecs/sqs-poc-ingestor 2>/dev/null || true
MSYS_NO_PATHCONV=1 aws logs delete-log-group --log-group-name /ecs/sqs-poc-billing  2>/dev/null || true
```

Confirme que nada sobrou:

```bash
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?contains(StackName, 'sqs-poc')].StackName" --output text
```

A saída deve ser vazia. Ambiente zerado.

---

## 9. Resumo da Configuração

Para referência rápida, a configuração efetiva aplicada pelos templates:

| Componente | Parâmetro | Valor |
|---|---|---|
| **ECS Ingestor** | CPU / Memory | 256 / 512 |
| | Desired / Min / Max | 2 / 2 / 6 |
| | Scale-out | CPU > 25% (1 período de 60s) → `+1` / `+2` tasks |
| | Scale-in | CPU < 10% (2 períodos de 60s) → `-1` task |
| **ECS Billing** | CPU / Memory | 512 / 1024 |
| | Desired | 1 (fixo; sem Auto Scaling neste episódio) |
| **SQS billing-queue** | VisibilityTimeout | 60s |
| | MessageRetentionPeriod | 4 dias |
| | ReceiveMessageWaitTimeSeconds | 20s (long polling) |
| **Container Insights** | Cluster `sqs-poc-cluster` | `enhanced` |
| **Log Groups** | Retenção | 7 dias |
| **Listener SQS (billing)** | max-messages-per-poll | 10 |
| | poll-timeout | 20s |
| | max-concurrent-messages | 10 |
| | acknowledgement-mode | `ON_SUCCESS` |
