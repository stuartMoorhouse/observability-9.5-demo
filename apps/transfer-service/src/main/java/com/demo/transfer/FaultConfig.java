package com.demo.transfer;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * Reads fault toggles from the mounted fault-config ConfigMap (/etc/fault/LATENCY_MS).
 * Values are cached for 5 s so a ConfigMap change takes effect without a restart.
 */
@Component
public class FaultConfig {

    private static final Logger log = LoggerFactory.getLogger(FaultConfig.class);
    private static final long CACHE_MS = 5_000;

    private final Path latencyFile;
    private volatile long cachedLatencyMs = 0;
    private volatile long lastRead = 0;

    public FaultConfig(@Value("${demo.fault-dir}") String faultDir) {
        this.latencyFile = Path.of(faultDir, "LATENCY_MS");
    }

    public long latencyMs() {
        long now = System.currentTimeMillis();
        if (now - lastRead > CACHE_MS) {
            long previous = cachedLatencyMs;
            cachedLatencyMs = readLong(latencyFile);
            lastRead = now;
            if (previous != cachedLatencyMs) {
                log.info("Fault config changed: LATENCY_MS={}", cachedLatencyMs);
            }
        }
        return cachedLatencyMs;
    }

    private static long readLong(Path file) {
        try {
            if (!Files.exists(file)) {
                return 0;
            }
            String raw = Files.readString(file).trim();
            return raw.isEmpty() ? 0 : Math.max(0, Long.parseLong(raw));
        } catch (IOException | NumberFormatException e) {
            log.warn("Cannot read fault file {}: {}", file, e.getMessage());
            return 0;
        }
    }
}
