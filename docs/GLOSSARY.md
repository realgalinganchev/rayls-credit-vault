# Glossary — ubiquitous language

The canonical vocabulary of the Rayls Credit Vault. One definition per term,
used consistently across code, tests, comments, and docs (the *ubiquitous
language* of Domain-Driven Design). If a term here and the code ever disagree,
treat it as a bug in one of them.

## Core accounting

- **Asset** — a unit of the underlying ERC-20 (USDr for supply/borrow, AmFi for
  collateral). Base units, respecting the token's decimals (USDr = 6).
- **Share** — a claim on a pool of assets, not a token amount. Supply shares
  claim a fraction of `totalSupplyAssets`; borrow shares owe a fraction of
  `totalBorrowAssets`. Shares exist so interest can accrue to the pool without
  touching every account.
- **Virtual shares / virtual assets** — the constant offset (`1e6` / `1`) added
  to totals in every conversion to defuse the first-depositor inflation attack
  (ADR 0001).
- **`totalSupplyAssets` / `totalSupplyShares`** — the market's booked supply
  side; `totalBorrowAssets` / `totalBorrowShares` — the borrow side.
- **Available liquidity** — `totalSupplyAssets − totalBorrowAssets`: cash on
  hand, i.e. supply not currently lent out. Never exceeds the market's actual
  token balance (an invariant).

## Collateral & risk

- **NAV (Net Asset Value)** — the attested value of one whole (`1e18`)
  collateral token, expressed in loan-token base units. `1_000_000` = $1.00 for
  6-decimal USDr. Set by the oracle (ADR 0004).
- **LLTV (Liquidation Loan-To-Value)** — the ratio, in bps, of debt to
  collateral value at which a position becomes liquidatable; also the borrow
  limit (single-LLTV design, ADR 0006). `7000` = 70%.
- **Healthy** — `debt ≤ collateralValue × LLTV`: a position at or below its
  borrow limit.
- **Utilization** — `totalBorrowAssets / totalSupplyAssets`, in WAD; drives the
  borrow rate.
- **Liquidation bonus** — the discount (5%) a liquidator receives on seized
  collateral; the entire liquidation incentive (there is no separate reward).

## Bad debt & liquidation

- **Bad debt** — debt with no, or effectively zero-value, collateral backing it.
- **Socialization** — writing bad debt off pro-rata against all suppliers
  immediately, rather than leaving it to accrue phantom interest (ADR 0002).
- **Issuer redemption** — the exit path for seized collateral: burn the AmFi
  token back to the issuer's funded pool for the settlement asset, in lieu of a
  (non-existent) open-market sale (ADR 0003).

## Vault

- **Curator** — the vault owner; decides how much of the vault's assets are
  deployed into the market (allocation) versus kept idle for withdrawals.
- **Allocation cap** — the maximum fraction (bps) of vault assets the curator
  may deploy into the market; enforced at allocate-time.
- **Idle** — vault assets held directly (not deployed into the market),
  available for immediate withdrawal.
- **Performance / curator fee** — the cut of accrued interest (15%, capped at
  25%) minted as supply shares to the fee recipient.
