# Rayls Credit Vault (PoC)

Curated RWA-collateral lending vault for the Rayls Public Chain — USDr depositors earn yield lent against AmFi tokenized-credit collateral. Morpho-Blue-inspired lending market + ERC-4626 curated vault. **Proof of concept, not production.**

The full research report behind this build — market landscape, venue selection, product design, risk analysis, and roadmap — is in [RESEARCH.pdf](RESEARCH.pdf).

## Architecture

| Contract | Role |
|---|---|
| `src/MockUSDr.sol` | Stand-in for Rayls' USDr gas stablecoin (6 decimals, owner-mintable) |
| `src/MockAmFiCredit.sol` | Stand-in AmFi tokenized-credit token (18 decimals): owner-set NAV (oracle stand-in) + issuer redemption pool — AmFi tokens have no live secondary market today, so issuer-mediated exit is the real-world mechanic, not a shortcut |
| `src/LendingMarket.sol` | Single lending market: overcollateralized borrowing (70% LLTV), utilization-based rates, curator fee (capped at 25%), permissionless liquidation (5% bonus), Morpho-style virtual shares, **bad-debt socialization** on collateral-exhausting liquidations |
| `src/CuratedCreditVault.sol` | ERC-4626 vault: curator allocates deposits into the market under a cap; auto-pulls liquidity on withdrawals; EIP-4626-compliant `maxWithdraw`/`maxRedeem` under market illiquidity |

Flow: depositors → vault (ERC-4626 shares) → curator allocates → lending market ← borrowers post AmFi collateral, draw USDr → interest (net of curator fee) flows back → liquidators keep the market solvent, exiting seized collateral via issuer redemption.

## Quickstart

```sh
npm install          # REQUIRED before forge build — OZ + Rayls SDK resolve via node_modules remappings
forge build
forge test           # 77 tests / 5 suites

# Narrated end-to-end demo (deploy → deposit → allocate → borrow → NAV writedown → liquidation → issuer redemption):
anvil                # terminal 1
forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vv

# Bare deployment (set DEPLOYER_PRIVATE_KEY in .env first — see .env.example):
forge script script/DeployCreditVault.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

The demo uses Anvil's public default keys. **Never fund those addresses on a real network.**

## Deployment status

- **Local Anvil:** verified end-to-end (deployment + full demo scenario, real broadcast, state cross-checked via `cast`).
- **Rayls testnet/mainnet:** pending gated access — Rayls Public Chain deployment requires operator approval plus RPC/chain-ID/registry credentials (being obtained via partnership). Same bytecode, different `--rpc-url`; to target the real USDr and AmFi mirror tokens, edit `DeployCreditVault.s.sol` to skip the mocks and pass real addresses.

## Known limitations (deliberate PoC scope — read before auditing)

- **Oracle:** owner-set NAV on the mock token, not an attested/Chainlink feed. The market enforces `nav > 0` (zero/reverting oracle reverts pricing operations loudly) and requires 18-decimal collateral at construction, but NAV freshness/manipulation is out of scope.
- **Single market, no factory** — one loan asset, one collateral, one oracle, vs. Morpho's permissionless multi-market design.
- **Owner-curator centralization:** market owner sets fee (≤ 25% cap) and fee recipient; vault owner controls allocation. No timelock/multisig, though ownership transfers on the market and mock issuer are two-step (`Ownable2Step`).
- **Interest is simple (non-compounding)** within each accrual window, at the rate prevailing when accrual materializes — diverges from Morpho's Taylor-compounded accrual.
- **Liquidator exit is issuer-redemption**, not market sale (matches AmFi's real exit mechanics today).
- **Vault allocation cap** is enforced at allocate-time only; the deployed ratio drifts passively as interest accrues.

## Testing & coverage

77 tests across 5 suites, including regression tests for every finding of both security passes (bad-debt socialization incl. the dust-value bypass and the rounding-overshoot clamp, fee-dilution-exact `supplyBalance` projection, sub-unit interest non-forfeiture, EIP-4626 `max*` under illiquidity, zero-NAV oracle guard, donation-attack resistance at both market and vault level), a branch-coverage completion sweep, and a stateful **invariant (fitness-function) suite** (`test/invariant/`) that drives the vault and market *together* — with fee changes and NAV crashes in the mix — and holds the solvency and value-conservation properties (`S ≥ D`, cash ≥ advertised liquidity, collateral fully backed, share-sum consistency, and no rounding-minted value on either layer) across 128k randomized operation sequences.

Coverage (canonical command: `forge coverage --no-match-coverage "(script/|HackathonToken|test/)"`):
**100% branch and statement coverage on all four contracts** (lines 99.4–100%).

## Design & decisions

The *why* behind the load-bearing choices — virtual-share accounting, bad-debt socialization, the issuer-redemption exit, the NAV trust model, ERC-4626 illiquidity handling, key management — is recorded as Architecture Decision Records in [`docs/decisions/`](docs/decisions). Domain terms (share, asset, NAV, LLTV, socialization, curator, …) are defined once in [`docs/GLOSSARY.md`](docs/GLOSSARY.md).

## Rayls bridge reference (kept from the official starter)

`src/HackathonToken.sol`, `script/{Deploy,Mint,Transfer,CheckBalance}.s.sol`, and `docs/architecture.md` + `docs/api-reference.md` are Rayls' official Privacy-Node→Public-Chain bridging reference, kept unmodified for the testnet deployment path (assets reach the Rayls Public Chain as bridged mirror tokens). **Not part of the audit surface.** This repo was scaffolded from [raylsnetwork/rayls-hackathon-starter](https://github.com/raylsnetwork/rayls-hackathon-starter) (`upstream` remote).
