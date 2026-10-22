"""fx-rates: static FX table, onboarded in demo scenario 1.

No OpenTelemetry SDK in the image: EDOT Python is injected by the OTel Operator.
"""

from decimal import Decimal

from fastapi import FastAPI, HTTPException, Query

from logging_setup import configure

log = configure("fx-rates")

# Units of quote currency per 1 unit of base currency, via EUR.
EUR_RATES = {
    "EUR": Decimal("1.0"),
    "GBP": Decimal("0.86"),
    "USD": Decimal("1.08"),
    "SEK": Decimal("11.45"),
    "NOK": Decimal("11.70"),
    "DKK": Decimal("7.46"),
    "CHF": Decimal("0.95"),
}

app = FastAPI(title="fx-rates")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/rate")
def rate(
    from_: str = Query(alias="from", min_length=3, max_length=3),
    to: str = Query(min_length=3, max_length=3),
):
    base, quote = from_.upper(), to.upper()
    if base not in EUR_RATES or quote not in EUR_RATES:
        log.warning("Unsupported currency pair %s/%s", base, quote)
        raise HTTPException(status_code=404, detail=f"unsupported currency pair {base}/{quote}")
    value = (EUR_RATES[quote] / EUR_RATES[base]).quantize(Decimal("0.000001"))
    log.info("Quoted %s/%s = %s", base, quote, value, extra={"fields": {"fx.pair": f"{base}/{quote}"}})
    return {"from": base, "to": quote, "rate": float(value)}
