# 5. ERC-4626 curated vault, EIP-4626-compliant under illiquidity

Status: Accepted

## Context

Depositors want one-click, risk-managed yield without operating a raw lending
market. But a curated vault deploys part of its assets into the market, whose
cash can be borrowed out — so at any moment only some of the vault's assets are
actually withdrawable. OpenZeppelin's ERC-4626 defaults assume all of
`totalAssets` is liquid, which makes `maxWithdraw`/`maxRedeem` overstate what a
withdrawal can deliver and causes reverts.

## Decision

Layer an ERC-4626 vault (MetaMorpho-style) over the market: the curator
allocates idle assets into the market under an allocation cap, and withdrawals
auto-pull any shortfall back from the market. Override `maxWithdraw` /
`maxRedeem` to clamp to *actually liquid* assets — idle balance plus the
smaller of (the vault's market claim, the market's cash on hand) — so the
EIP-4626 guarantee "`withdraw(maxWithdraw)` never reverts" holds even when
market cash is lent out.

## Consequences

- Depositors get a compliant ERC-4626 surface; integrators can trust the `max*`
  views.
- `totalAssets` projects interest accrued-but-not-yet-materialized exactly (via
  the market's `supplyBalance`), so share pricing is correct between accruals.
- Curator centralization: the owner controls allocation and the cap — bounded
  and documented (see ADR 0007).

## Alternatives rejected

- **OZ ERC-4626 defaults** — overstate withdrawable assets, revert under
  illiquidity, violate the EIP guarantee.
- **No vault, raw market only** — worse UX, no curation or risk-management
  layer.
