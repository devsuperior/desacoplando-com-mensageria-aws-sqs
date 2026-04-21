package com.devsuperior.ingestor.config;

import io.awspring.cloud.sqs.operations.SqsTemplate;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;

/**
 * Sobrescreve o {@link SqsTemplate} default apenas para desligar o envio do header
 * {@code JavaType} nas Message Attributes. Esse header carrega o FQCN do payload
 * (ex.: {@code com.devsuperior.ingestor.dto.PaymentEventDTO}) e polui a inspeção da
 * fila, além de acoplar emissor e consumidor pelo nome da classe. Como não há property
 * equivalente em {@code application.properties}, mantemos o bean explícito.
 *
 * <p>O {@link SqsAsyncClient} vem injetado pelo auto-config (o starter usa sempre o
 * cliente não-bloqueante do AWS SDK v2).</p>
 */
@Configuration
public class SqsConfig {

    @Bean
    public SqsTemplate sqsTemplate(SqsAsyncClient sqsAsyncClient) {
        return SqsTemplate.builder()
                .sqsAsyncClient(sqsAsyncClient)
                .configureDefaultConverter(c -> c.doNotSendPayloadTypeHeader())
                .build();
    }
}
