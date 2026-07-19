# 6. Single market, single LLTV

Status: Accepted (PoC)

## Context

Morpho Blue is a permissionless factory of isolated markets, each with its own
loan asset, collateral, oracle, and LLTV. A proof of concept needs one clear,
auditable market, not a factory.

## Decision

Deploy one hardcoded market — one loan asset (USDr), one collateral (AmFi), one
oracle — with a single liquidation LTV used both as the borrow limit and the
liquidation threshold.

## Consequences

- Small, legible, fully auditable surface; the invariant suite can reason about
  the entire market.
- No market isolation or routing; a second collateral means a second
  deployment.
- A single LLTV means a position at exactly the borrow limit has zero buffer
  and becomes liquidatable on the next block's interest — identical to Morpho
  Blue, and a borrower-UX expectation to document, not a bug.

## Alternatives rejected

- **Full permissionless factory** — scope; not needed to prove the mechanic.
- **Separate origination vs. liquidation LTV** — adds a safety buffer but also
  complexity; deferred to production.
