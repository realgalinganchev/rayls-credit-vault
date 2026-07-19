# 8. Simple, non-compounding interest at spot utilization

Status: Accepted (PoC)

## Context

Morpho Blue accrues interest with a Taylor-series compounding approximation. A
proof of concept benefits from interest math a reader can verify by hand.

## Decision

Use a linear utilization-based rate (`base + slope * utilization`) and simple
(non-compounding) interest within each accrual window, applied at the rate
prevailing when accrual materializes. Sub-unit interest is not forfeited: when
the accrued amount truncates to zero, the accrual clock is *not* advanced, so
small markets accumulate the fraction instead of earning zero forever.

## Consequences

- Interest is legible and gas-cheap; every figure in the tests is exact, not an
  approximation.
- Marginally gameable: a borrower can nudge utilization down (a small repay)
  immediately before triggering accrual so the window bills at a lower rate. The
  gain is marginal versus gas; documented and accepted for the PoC.
- Diverges from Morpho's compounding — revisit for production.

## Alternatives rejected

- **Taylor-compounded accrual** — matches Morpho but adds complexity a PoC does
  not need.
- **Per-second rate snapshots** — most accurate, most gas and code.
