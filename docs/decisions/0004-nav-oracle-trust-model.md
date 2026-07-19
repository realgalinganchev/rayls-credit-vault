# 4. Owner-set NAV oracle with a non-zero invariant

Status: Accepted (PoC) — production hardening required

## Context

Tokenized private credit has no second-by-second market price; its value is a
NAV (principal + accrued interest − defaults) that an issuer or oracle attests.
The market must price collateral to run health checks and liquidations.

## Decision

For the PoC, price collateral from an owner-settable NAV on the mock token
(`setNav`), read through the `INavOracle` interface. The market enforces a
non-zero invariant — `require(nav > 0)` on every pricing read — so a
zero/broken oracle reverts loudly rather than silently treating collateral as
worthless (which would make every borrower maximally unhealthy while
simultaneously bricking liquidation with a divide-by-zero). Collateral must be
18 decimals at construction, pairing with `ORACLE_SCALE = 1e18`.

## Consequences

- Simple and legible for a demo; the vault never reads the oracle, so a broken
  feed cannot brick deposits/withdrawals.
- **This is the single largest production gap.** The owner-set NAV is an
  unconstrained price lever with no staleness, deviation bounds, or timelock —
  and in the demo the same key is market owner, fee recipient, and NAV setter.
  Production **must** replace it with an attested/Chainlink feed behind
  staleness + deviation guards, separate the three roles, and put NAV and fee
  changes behind a timelock. See ADR 0007 for the key-management half.

## Alternatives rejected

- **DEX TWAP** — no pool exists for AmFi tokens.
- **Hardcoded price** — cannot reflect real credit deterioration, defeating the
  purpose of the collateral.
