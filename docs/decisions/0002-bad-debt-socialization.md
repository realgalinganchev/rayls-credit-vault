# 2. Socialize bad debt on collateral exhaustion, keyed on collateral value

Status: Accepted

## Context

A liquidation can leave a borrower with debt but effectively no collateral (a
deep NAV writedown). No rational liquidator will repay that rump — seizing zero
collateral for it is a pure donation. Left in place, the rump keeps accruing
interest, inflating `totalBorrowAssets` and locking lender liquidity behind the
`totalBorrowAssets <= totalSupplyAssets` withdrawal check. The result is a
first-out-wins bank run: early lenders exit whole, late lenders are stuck.

## Decision

When a liquidation leaves the position effectively unbacked and debt remains,
write the rump off immediately and pro-rata against all suppliers
(Morpho-style socialization): subtract the bad-debt assets from both
`totalBorrowAssets` and `totalSupplyAssets`, and zero the borrower's shares.
Trigger the write-off on collateral **value**
(`collateralBalance * nav / ORACLE_SCALE == 0`), not raw balance — a liquidator
who seizes all but a dust wei must not be able to skip the branch and leave
phantom debt.

## Consequences

- Losses are taken honestly and immediately, distributed fairly across all
  suppliers (including the fee recipient's accrued shares).
- Lenders can always exit; the phantom-debt bank run is structurally impossible.
- The `S >= D` solvency invariant is preserved — the clamp on rounding overshoot
  keeps the subtraction from underflowing. Continuously checked by
  `test/invariant/SolvencyInvariants.t.sol`.

## Alternatives rejected

- **Leave bad debt on the books** — the exact bank-run failure above.
- **Key the write-off on `collateralBalance == 0`** — bypassable by leaving 1
  wei of (zero-value) dust, which re-introduces the phantom debt.
- **Insurance / backstop fund** — meaningful, but out of scope for a
  single-market PoC.
- **Appointed/designated liquidator** — rejected on two independent grounds:
  (1) a single point of failure — if that party is offline, censored, or
  compromised, *no* liquidation happens at all, not even the easy, obviously
  profitable ones, which is worse than the rare case this would fix; (2) it
  doesn't even solve the incentive problem — an appointed party still faces
  the same pure-donation math on a worthless position, so it would need a
  subsidy to act anyway. The permissionless design already lets anyone,
  including the curator, voluntarily act as a backstop with their own
  capital today, no code change required. A protocol-funded bad-debt
  bounty (reimbursing gas plus a small fee for closing out confirmed-worthless
  positions) would be the cleaner fix if ever built — same spirit as the
  insurance-fund idea above, just permissionless and narrower in scope.

## Rounding-overshoot handling in `repay`

`repay` carries the same clamp as the socialization path above, for the same
reason. Without it, a *contrived* tiny-position state bit: after engineered
share-ratio drift — borrow 3 base units, then repay 1 share, pushing
shares-per-asset above the initial `1e6` — a **sole** borrower's full repay
computed ceil-`assets` that overshot `totalBorrowAssets` and reverted on the
underflow, and chunking made it worse (ceil-rounding drove `totalBorrowAssets`
to 0 while shares remained, stranding ~1 base unit of undischargeable dust
debt). Capping the repaid amount at `totalBorrowAssets` lets such a position
fully close; the borrower never pays more than the booked total, so no value
leaks and `S ≥ D` / value-conservation hold (confirmed by the invariant suite
and the `test_Repay_ClampsCeilOvershoot_FullExit` regression). It is the same
rounding family Morpho Blue accepts — made airtight rather than merely
tolerated.
