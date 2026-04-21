package com.devsuperior.ingestor.controller;

import com.devsuperior.ingestor.dto.PaymentEventDTO;
import com.devsuperior.ingestor.filter.CorrelationIdFilter;
import com.devsuperior.ingestor.service.PaymentQueueService;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api/payments")
public class PaymentWebhookController {

    private static final Logger log = LoggerFactory.getLogger(PaymentWebhookController.class);

    private final PaymentQueueService queueService;

    public PaymentWebhookController(PaymentQueueService queueService) {
        this.queueService = queueService;
    }

    @PostMapping("/webhook")
    public ResponseEntity<Map<String, String>> receivePayment(
            @RequestBody PaymentEventDTO event,
            HttpServletRequest request) {
        String correlationId = (String) request.getAttribute(CorrelationIdFilter.REQUEST_ATTR);
        log.info("Webhook recebido para pagamento: {}", event.paymentId());
        queueService.enqueue(event, correlationId);
        return ResponseEntity.accepted().body(Map.of(
                "status", "accepted",
                "correlationId", correlationId));
    }
}
