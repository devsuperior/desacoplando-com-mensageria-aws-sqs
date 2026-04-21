# Desacoplando com Mensageria no AWS SQS

Projeto prático construído a partir do artigo [**Desacoplando sistemas com mensageria no AWS SQS**](https://devsuperior.com.br/blog/desacoplando-sistemas-com-mensageria-no-aws-sqs) da DevSuperior, **Episódio 1 da série "Dominando Mensageria na AWS"**.

Enquanto o artigo sobe tudo localmente com LocalStack, aqui a solução vai para a **AWS real**: ECS Fargate, SQS Standard e ALB via CloudFormation, IAM granular por serviço, teste de estresse com k6 e Step Scaling reagindo à carga em menos de um minuto.

> 📘 **Guia completo passo a passo:** [DEMO.md](DEMO.md)
> 🔧 **Tuning do consumidor SQS (batch, polling, ack modes):** [TUNNING-SQS.md](TUNNING-SQS.md)

## O que muda em relação ao artigo?

- **IAM granular por serviço:** ingestor só publica (`sqs:SendMessage`), billing só consome (`sqs:ReceiveMessage`/`DeleteMessage`).
- **Correlation-ID trafegando nos headers da fila:** rastreabilidade ponta a ponta do webhook HTTP ao log persistido, via SQS Message Attribute.
- **Consumo em batch e polling configuráveis** no billing (`max-messages-per-poll`, `poll-timeout`) — detalhes em [TUNNING-SQS.md](TUNNING-SQS.md).
- **Auto Scaling por queue-depth** no billing (métrica `ApproximateNumberOfMessagesVisible` do SQS), em vez de CPU — escala pelo que realmente importa no consumer.
- **Teste de estresse com k6** em container disparando até 200 VUs contra o ALB.
- **Infra completa via CloudFormation:** ECR, SQS, ECS Fargate, ALB e CloudWatch.

## Arquitetura

Fluxo principal:

```mermaid
graph LR
    User((k6 / Stripe simulado)) -- "HTTP POST /api/payments/webhook" --> ALB[AWS ALB]
    ALB --> Ingestor[ECS: ms-payment-ingestor]
    Ingestor -- "SendMessage + Message Attributes (X-Correlation-ID, X-Source)" --> SQS[(SQS: sqs-poc-billing-queue)]
    SQS -- "ReceiveMessage batch=10 + Long Polling" --> Billing[ECS: ms-billing]
    Billing -- "RestClient" --> FX[Frankfurter API]
    Billing -- "JPA save" --> H2[(H2 in-memory)]
    Ingestor --> Logs1[CloudWatch Logs]
    Billing --> Logs2[CloudWatch Logs]
```

Auto Scaling de cada serviço (políticas independentes, cada uma reagindo ao sinal mais adequado):

```mermaid
graph TB
    subgraph Ingestor["Ingestor — Step Scaling em CPU"]
        I1[Alarm CPU > 25% / 60s] --> I2[Scale-out +1 / +2 tasks]
        I3[Alarm CPU < 10% / 2 min] --> I4[Scale-in -1 task]
        I5[Min 2 / Max 6]
    end
    subgraph Billing["Billing — Step Scaling em queue-depth"]
        B1[Alarm ApproximateNumberOfMessagesVisible > 10 / 60s] --> B2[Scale-out +1 / +2 tasks]
        B3[Alarm messages &lt; 5 / 2 min] --> B4[Scale-in -1 task]
        B5[Min 1 / Max 5]
    end
```

## Pré-requisitos

- **AWS CLI v2** autenticado na conta destino.
- **Docker Desktop** em execução — necessário para o build/push da imagem ao ECR e para rodar o k6 em container.
- **Java 25** (o Maven Wrapper já está no repositório).
- **GitBash** no Windows (todos os scripts são Bash).
- Região padrão: `us-east-1`.

## Deploy completo

Um único comando orquestra ECR, build e push das imagens, SQS e ECS:

```bash
./scripts/deploy.sh
```

Tempo médio: cerca de 8 minutos. Trecho final da saída:

```
============================================================
Deploy concluido!
  ALB: http://sqs-poc-alb-1742980948.us-east-1.elb.amazonaws.com
  Queue URL: https://sqs.us-east-1.amazonaws.com/<ACCOUNT>/sqs-poc-billing-queue
  Cluster: sqs-poc-cluster
============================================================
```

Para rodar cada etapa manualmente e entender cada comando, siga o guia em [DEMO.md](DEMO.md).

## Smoke test

```bash
./scripts/smoke-test.sh
```

Envia um pagamento com correlation-id único, aguarda a fila zerar e procura o mesmo id nos logs do billing. Saída esperada:

```
==> Health check em http://sqs-poc-alb-*.us-east-1.elb.amazonaws.com/actuator/health
    OK
==> Enviando pagamento de teste (correlationId=smoke-1776728546)
{"correlationId":"smoke-1776728546","status":"accepted"}
==> Aguardando fila zerar (timeout 60s)
    tentativa 1: mensagens na fila = 0
==> Smoke-test concluido.
```

## Teste de carga

```bash
./scripts/run_k6.sh
```

Dispara o k6 em container com stages `0 → 80 → 150 → 200 → 0` VUs em cerca de 3m30s. Trecho final da saída:

```
█ TOTAL RESULTS
  checks_succeeded...: 100.00% 37440 out of 37440
  http_req_failed....: 0.00%   0 out of 18720
  http_reqs..........: 18720   89.12/s
  http_req_duration..: p(95)=4.03s
```

Para acompanhar o Auto Scaling em paralelo:

```bash
aws ecs describe-services --cluster sqs-poc-cluster --services sqs-poc-billing \
  --query "services[0].{Desired:desiredCount,Running:runningCount}"

aws sqs get-queue-attributes --queue-url <URL_DA_FILA> \
  --attribute-names ApproximateNumberOfMessages
```

## Exemplos cURL

Webhook com correlation-id explícito (útil para rastrear uma transação específica nos logs):

```bash
curl -X POST $ALB_URL/api/payments/webhook \
  -H "Content-Type: application/json" \
  -H "X-Correlation-ID: demo-headers-001" \
  -d '{"paymentId":"pay_001","amount":299.90,"currency":"BRL","status":"succeeded","createdAt":"2026-04-20T10:00:00Z"}'
```

Sem o header, o filter gera um UUID automaticamente e o devolve no response:

```bash
curl -X POST $ALB_URL/api/payments/webhook \
  -H "Content-Type: application/json" \
  -d '{"paymentId":"pay_002","amount":500.00,"currency":"USD","status":"succeeded","createdAt":"2026-04-20T10:00:00Z"}'
```

## Onde focar

Arquivos-chave caso você queira mergulhar no código:

- [`infra/3-ecs.yml`](infra/3-ecs.yml): VPC, ALB, 2 Services Fargate, IAM Roles separadas, Step Scaling com alarmes.
- [`ms-payment-ingestor/.../filter/CorrelationIdFilter.java`](ms-payment-ingestor/src/main/java/com/devsuperior/ingestor/filter/CorrelationIdFilter.java): geração e propagação do correlation-id.
- [`ms-payment-ingestor/.../service/PaymentQueueService.java`](ms-payment-ingestor/src/main/java/com/devsuperior/ingestor/service/PaymentQueueService.java): envio ao SQS com Message Attributes.
- [`ms-billing/src/main/resources/application.properties`](ms-billing/src/main/resources/application.properties): tuning do listener SQS via auto-config (ver também [TUNNING-SQS.md](TUNNING-SQS.md)).
- [`ms-billing/.../listener/BillingQueueListener.java`](ms-billing/src/main/java/com/devsuperior/billing/listener/BillingQueueListener.java): `@Header` lendo Message Attributes e populando o MDC.
- [`scripts/deploy.sh`](scripts/deploy.sh): orquestração completa do provisionamento.

## Cleanup

```bash
./scripts/cleanup.sh
```

Destrói tudo em paralelo: ECS, ECR (com force delete das imagens) e SQS, além dos log groups remanescentes. Saída esperada:

```
==> Disparando deletes em paralelo (ECS + ECR + SQS sao independentes)
==> Limpando repositorio ECR sqs-poc-ingestor (force)
==> Limpando repositorio ECR sqs-poc-billing (force)
==> Aguardando sqs-poc-ecs finalizar delete...
    sqs-poc-ecs removida
    sqs-poc-ecr removida
    sqs-poc-sqs removida
==> Cleanup concluido.
```

**Execute ao fim de cada uso para evitar cobranças.**
