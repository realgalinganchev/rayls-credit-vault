# 3. Issuer-redemption exit for seized collateral

Status: Accepted

## Context

Permissionless liquidation works on Ethereum because a liquidator can instantly
sell seized collateral (e.g. ETH) on a DEX. AmFi tokenized-credit tokens have
no such exit: AmFi's own secondary marketplace is still "coming soon," no
AmFi/USDr pool exists on Rayls' Algebra DEX, and the originator-mediated model
makes the tokens buy-and-hold by construction. A liquidator who cannot exit
seized collateral will not liquidate — and the market becomes insolvent.

## Decision

Model AmFi's real exit mechanic: the liquidator seizes collateral to their own
wallet, then redeems it for the settlement asset through an issuer-funded
redemption pool (`MockAmFiCredit.redeem()` / `fundRedemptionPool`) rather than
an open-market sale.

## Consequences

- Liquidation is economically viable without a secondary market — this matches
  how AmFi actually works today, not a shortcut.
- Introduces a dependency on redemption-pool liquidity: a liquidator holding
  seized tokens is exposed to the issuer honoring redemptions.
- Surfaces a second product opportunity — the redemption-gap tooling is itself
  what makes RWA collateral usable as collateral at all.

## Alternatives rejected

- **Assume a DEX sale** — no pool exists; it would be fiction.
- **On-chain auction of seized collateral** — no bidders without liquidity.
