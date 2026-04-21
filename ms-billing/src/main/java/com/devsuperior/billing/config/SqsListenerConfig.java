package com.devsuperior.billing.config;

import io.awspring.cloud.sqs.config.SqsMessageListenerContainerFactory;
import io.awspring.cloud.sqs.listener.acknowledgement.handler.AcknowledgementMode;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;

import java.time.Duration;

@Configuration
public class SqsListenerConfig {

    @Bean
    public SqsMessageListenerContainerFactory<Object> defaultSqsListenerContainerFactory(
            SqsAsyncClient sqsAsyncClient,
            @Value("${app.sqs.max-messages-per-poll:10}") int maxMessagesPerPoll,
            @Value("${app.sqs.wait-time-seconds:20}") int waitTimeSeconds) {
        return SqsMessageListenerContainerFactory
                .<Object>builder()
                .sqsAsyncClient(sqsAsyncClient)
                .configure(opts -> opts
                        .maxMessagesPerPoll(maxMessagesPerPoll)
                        .pollTimeout(Duration.ofSeconds(waitTimeSeconds))
                        .acknowledgementMode(AcknowledgementMode.ON_SUCCESS))
                .build();
    }
}
