# 1. Share accounting with a virtual shares/assets offset

Status: Accepted

## Context

Both the lending market (supply/borrow shares) and the ERC-4626 vault convert
between "shares" (a claim) and "assets" (the underlying token). An empty or
near-empty pool is vulnerable to the classic first-depositor *donation /
share-inflation* attack: an attacker deposits 1 wei to mint 1 share, transfers
a large amount directly to the contract to inflate the share price, and the
next depositor's deposit rounds down to zero shares — their funds accrue to the
attacker.

## Decision

Use Morpho Blue's virtual-offset accounting in the market: every conversion
adds `VIRTUAL_SHARES = 1e6` and `VIRTUAL_ASSETS = 1` to the totals, so the
first real depositor is always priced against a non-empty virtual pool. At the
vault layer, use OpenZeppelin v5's built-in virtual shares plus
`_decimalsOffset() = 6`. Both constants are `public` so integrators and tests
replicate the conversion math exactly rather than re-deriving it.

## Consequences

- The donation attack is neutralized: rounding a victim to zero shares would
  require a donation on the order of `10^6 ×` their deposit — economically
  absurd for a 6-decimal stablecoin.
- Every conversion carries at most 1 wei of rounding, always directed in the
  protocol's favor (shares up on borrow/repay, assets down on withdraw).
- Round-trips are exact for realistic amounts (covered by unit tests and the
  invariant suite).

## Alternatives rejected

- **Minimum first deposit / dead shares burned to `address(0)`** — reduces but
  does not eliminate the attack at small scale, and wastes the burned amount.
- **Require the deployer to seed the pool** — operational fragility; a
  misconfigured deploy reopens the hole.
