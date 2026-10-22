package com.demo.transfer;

/** Thrown by the "bad release" (BAD_RELEASE=true) to simulate a ledger API contract regression. */
public class LedgerContractMismatchException extends RuntimeException {
    public LedgerContractMismatchException(String message) {
        super(message);
    }
}
