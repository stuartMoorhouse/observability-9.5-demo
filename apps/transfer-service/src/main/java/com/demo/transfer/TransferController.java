package com.demo.transfer;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

@RestController
public class TransferController {

    private static final Logger log = LoggerFactory.getLogger(TransferController.class);

    public record TransferRequest(String fromAccount, String toAccount, BigDecimal amount,
                                  String currency, String targetCurrency) {}

    public record FraudScore(String decision, double score, java.util.List<String> reasons) {}

    public record FxRate(String from, String to, BigDecimal rate) {}

    private final RestClient http;
    private final FaultConfig faults;
    private final String fraudUrl;
    private final String ledgerUrl;
    private final String fxUrl;
    private final boolean badRelease;

    public TransferController(RestClient http, FaultConfig faults,
                              @Value("${demo.fraud-check-url}") String fraudUrl,
                              @Value("${demo.accounts-ledger-url}") String ledgerUrl,
                              @Value("${demo.fx-rates-url}") String fxUrl,
                              @Value("${demo.bad-release}") boolean badRelease) {
        this.http = http;
        this.faults = faults;
        this.fraudUrl = fraudUrl;
        this.ledgerUrl = ledgerUrl;
        this.fxUrl = fxUrl;
        this.badRelease = badRelease;
        if (badRelease) {
            // Reads like a normal release note: the triage agent quotes startup logs as evidence.
            log.info("Ledger client using contract v2 (postingId required)");
        }
    }

    @PostMapping(path = "/transfer", consumes = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<Map<String, Object>> transfer(@RequestBody TransferRequest req) throws InterruptedException {
        if (req.fromAccount() == null || req.toAccount() == null || req.amount() == null
                || req.amount().signum() <= 0) {
            return ResponseEntity.badRequest().body(Map.of("error", "invalid transfer request"));
        }
        String currency = req.currency() == null ? "EUR" : req.currency();
        String targetCurrency = req.targetCurrency() == null ? currency : req.targetCurrency();
        String transferId = UUID.randomUUID().toString();

        long latency = faults.latencyMs();
        if (latency > 0) {
            Thread.sleep(latency);
        }

        if (badRelease) {
            Thread.sleep(350 + ThreadLocalRandom.current().nextInt(100));
            // 25% failures: an availability burn rate of ~23 against the 99% SLO, clearly above the
            // 14.4 fast-burn threshold even with health-check transactions diluting the rate.
            if (ThreadLocalRandom.current().nextInt(100) < 25) {
                log.error("Ledger contract mismatch for transfer {}: expected ledger schema v2, got v1",
                        transferId);
                throw new LedgerContractMismatchException(
                        "Ledger response missing field 'postingId' (contract v2) for transfer " + transferId);
            }
        }

        FraudScore score = http.post().uri(fraudUrl + "/score")
                .contentType(MediaType.APPLICATION_JSON)
                .body(Map.of("fromAccount", req.fromAccount(), "toAccount", req.toAccount(),
                        "amount", req.amount(), "currency", currency))
                .retrieve()
                .body(FraudScore.class);

        if (score == null || !"allow".equals(score.decision())) {
            log.info("Transfer {} rejected by fraud-check: {}", transferId,
                    score == null ? "no response" : score.reasons());
            return ResponseEntity.status(HttpStatus.FORBIDDEN).body(Map.of(
                    "transferId", transferId, "status", "rejected",
                    "reasons", score == null ? java.util.List.of() : score.reasons()));
        }

        BigDecimal rate = BigDecimal.ONE;
        if (!currency.equalsIgnoreCase(targetCurrency)) {
            rate = fxRate(currency, targetCurrency);
        }
        BigDecimal credited = req.amount().multiply(rate).setScale(2, RoundingMode.HALF_UP);

        http.post().uri(ledgerUrl + "/ledger/debit")
                .contentType(MediaType.APPLICATION_JSON)
                .body(Map.of("accountId", req.fromAccount(), "amount", req.amount(), "reference", transferId))
                .retrieve()
                .toBodilessEntity();

        http.post().uri(ledgerUrl + "/ledger/credit")
                .contentType(MediaType.APPLICATION_JSON)
                .body(Map.of("accountId", req.toAccount(), "amount", credited, "reference", transferId))
                .retrieve()
                .toBodilessEntity();

        log.info("Transfer {} completed: {} {} -> {} {} (rate {})", transferId, req.amount(), currency,
                credited, targetCurrency, rate);
        return ResponseEntity.ok(Map.of(
                "transferId", transferId, "status", "completed",
                "debited", req.amount(), "credited", credited, "rate", rate));
    }

    /** fx-rates is onboarded in scenario 1; until then fall back to 1.0. */
    private BigDecimal fxRate(String from, String to) {
        try {
            FxRate fx = http.get().uri(fxUrl + "/rate?from={from}&to={to}", from, to)
                    .retrieve()
                    .body(FxRate.class);
            if (fx != null && fx.rate() != null) {
                return fx.rate();
            }
            log.warn("fx-rates returned no rate for {}->{}, falling back to 1.0", from, to);
        } catch (ResourceAccessException e) {
            log.warn("fx-rates unavailable ({}), falling back to rate 1.0 for {}->{}", e.getMessage(), from, to);
        } catch (RestClientResponseException e) {
            log.warn("fx-rates returned HTTP {}, falling back to rate 1.0 for {}->{}",
                    e.getStatusCode().value(), from, to);
        }
        return BigDecimal.ONE;
    }
}
