## Why + research

**What banks/institutions want (brief):**
- Banks want compliant collateral workflows, not another chain
- Proof: JPMorgan runs ~$7B/day through its own permissioned Kinexys rails, not a public chain; DTCC's upcoming Collateral AppChain (Chainlink-powered, targeting Q4 2026) is a permissioned workflow bolted onto existing infrastructure, not a new base layer — even the most sophisticated players build compliant plumbing, they don't migrate to open chains

**Landscape research — flash `LANDSCAPE-REPORT.pdf` p.3 (closed-flows table):**
- Every major institutional flow (repo, interbank, cross-border, CBDC, securities) is owned by an incumbent — **none open to an outside builder**
- Conclusion: *"don't compete with rails, attach to them"* — the value sits on top of a rail, not beside it

**Chainlink — interoperability layer, not a chain:**
- Architecture: a decentralized oracle network (DON) sitting across 60–70+ chains — sells three things: data feeds/Proof of Reserve, CCIP (cross-chain messaging + token transfers), and CRE (orchestration layer, since Nov 2025)
- Verdict: build on top, don't compete — owns neither settlement nor custody; our vault's eventual NAV oracle, not a venue
- SWIFT + CCIP live since Nov 2025 (11,500 member banks), SWIFT's own blockchain ledger went live July 2026 with 17 banks (ANZ, DBS, MUFG, OCBC, UOB); DTCC collaborating on 24/7 collateral management; $33.6B cross-chain value secured Q1 2026

**Canton — best app economics, Daml-native:**
- Architecture: each participant runs a node holding a private ledger with only the data relevant to them, no global broadcast; synchronizers order transactions between participants, and the Global Synchronizer (decentralized "Super Validators") ties the network together — sub-transaction privacy engineered in, not bolted on
- Best builder economics of any chain surveyed: 62% of Canton Coin's reward pool goes to applications, not infrastructure operators — and it's fair-launched (no pre-mine/VC allocation)
- Real production: Broadridge DLR ~$8T/month repo, Goldman GS DAP, JPM Coin migrating
- Two gates: different paradigm (Daml) + validator-sponsorship/"featured app" access — same relationship-gate shape as Rayls
- Zenith (EVM-compat layer): launched March 2026, in permissioned testnet now, mainnet targeted Q2 2026 — real, funded, partnered (JPMorgan, DTCC, Nasdaq, Goldman), not vaporware
- **Expansion story, not a hedge:** the same Solidity vault code could plausibly redeploy on Canton once Zenith's mainnet lands — and we may already have a relationship-based path in

**Polkadot — thin, thinning institutional case:**
- Relay chain + parachains; institutional story rests almost entirely on one parachain, Centrifuge
- Centrifuge fully migrated **off** Polkadot to EVM (April 2026) — the anchor left
- Real developer activity exists (65+ parachains, 450–500 monthly active devs) — but it's gaming/identity/DePIN, not finance
- JAM (their next-gen upgrade, a general-purpose WASM computer): roadmap, not shipped institutional capability — doesn't move the needle
- TVL ~$40M, falling DAU, zero CBDC pilots found
- Verdict: ruled out — weakest institutional case of the majors

**Rest of the field, briefly:**
- XRP Ledger: public payments L1; RLUSD stablecoin ($1.33B) is the real story — a pilot links JPMorgan/Mastercard/Ondo to interbank settlement for tokenized Treasuries. Watch RLUSD, not XRP
- R3 Corda: permissioned DLT, ~$17B legacy tokenized RWA — but R3 just announced a new platform built natively on **Solana**. Even the most bank-native, privacy-first incumbent now believes distribution lives on a public chain
- Hyperledger Fabric: not a chain, an open-source permissioned framework — production but fragmented (we.trade's 16 banks are their own isolated island, no shared liquidity). Closed consortia, dead end for outside builders
- Hedera: public hashgraph, council-governed; ~$10B RWA settlement claimed (Lloyds/Aberdeen FX) — but HBAR captures no fee value, nothing for a builder to own
- Avalanche Evergreen: permissioned EVM subnets with real institutional pilots (T. Rowe Price, WisdomTree, Wellington) — still testnet, no production collateral to serve yet
- Partior / Fnality: bank-owned settlement JVs (DBS/JPMorgan/Temasek; per-currency wholesale rails) — real, regulated, and entirely closed to outside builders
- Verdict across all of them: real production exists everywhere, builder access exists nowhere — the thesis holds before we even get to AmFi

**Why AmFi — the wedge**
- AmFi solved issuance/yield distribution (holders already collect real yield from the underlying receivables) — nobody solved capital efficiency for it. That's the gap: a lending market letting holders borrow against AmFi tokens without selling. We fill it with a Morpho-Blue-inspired market — proven collateral, not speculative
- What is AmFi: Brazil's leading private-credit tokenization platform — regulated by Brazil's Central Bank + CVM, licensed custodians, ~R$3B (~$500M+) issued to date
- Real disclosed yields (AmFi, via Finsiders Brasil press interview — https://finsidersbrasil.com.br/reportagem-exclusiva-fintechs/amfi-recebe-aval-da-cvm-para-levar-token-de-recebivel-ao-varejo/): 17–18%/yr baseline · up to 30%/yr for judicial-asset tranches (highest risk) · ~20%/yr anticipated rate for international/US investors — our demo's ~14% is a conservative illustrative figure, not the real number
- Token = a claim on a pool of Brazilian receivables/credit notes (FIDC-style, senior/junior tranches) — value tracks NAV (principal + accrued interest − defaults)
- Originator-gated access, no open marketplace → buy-and-hold, not a trading instrument — why issuer-redemption, not a DEX sale, is the real exit
- Rayls × AmFi (announced Dec 2025, targets not independently verified live): $100M committed by Jul 2026 → $500M TVT by Jan 2027 → $1B+ by Jun 2027 — lending layer unclaimed regardless — the wedge
- Proof the slot is open, not just unclaimed on paper: Lagoon Finance was announced as a Rayls launch partner for institutional-grade **vaults** (rayls.com/blog/rayls-and-lagoon-finance-institutional-grade-vaults-for-the-rayls-public-chain), first vaults slated for the June 2026 partner cohort — but as of this research, Lagoon's Rayls vaults **aren't live yet (zero TVL on DefiLlama)**. Vault infra ≠ lending market, but if even the adjacent, already-announced piece hasn't shipped, the lending layer underneath is wide open
- Incentive loop (one breath): lender 0%→yield · borrower keeps ~14% spread, no market to sell into · liquidator: 5% bonus · curator: 15% fee · collateral + 70% LLTV = the real backstop

## Live demo

**Pre-flight:**
```sh
anvil                              # terminal 1
./script/setup-manual-demo.sh      # terminal 2 — deploy + fund, off-stage
./script/manual-demo.sh            # live menu
```
**Golden rule:** re-run `setup-manual-demo.sh` after any redeploy.

**The 9 steps:**

| # | Beat                           | Expect              |
|---|--------------------------------|---------------------|
| 1 | Lender deposits 100k           | totalAssets 100,000 |
| 2 | Allocate 80k (80% cap)         | idle 20,000         |
| 3 | Post 50k mAMFI                 | posted 50,000       |
| 4 | **[revert]** 40k borrow        | reverts             |
| 5 | Borrow 30k                     | healthy, 5.75%/yr   |
| 6 | **[revert]** liquidate healthy | reverts             |
| 7 | NAV $1.00 → $0.70              | unhealthy           |
| 8 | Liquidate                      | seize 45,000 mAMFI  |
| 9 | Redeem                         | 51,500 (+1,500)     |


## ADR cram — one line each

- **0001 Share accounting:** virtual shares/offset both layers → kills donation/inflation attack (~10⁶× cost to pull off)
- **0002 Bad-debt socialization:** once a liquidation exhausts a position's collateral, write off whatever debt remains pro-rata across lenders — triggered on collateral *value* hitting zero, not raw token balance
- **0003 Issuer redemption:** no secondary market → redeem through issuer pool, matches AmFi's real mechanic
- **0004 NAV oracle trust:** owner-set NAV, `require(nav>0)` — **biggest production gap**, needs feed + bounds + timelock
- **0005 ERC-4626 vault:** `maxWithdraw`/`maxRedeem` clamp to real liquidity — `withdraw(maxWithdraw)` never reverts
- **0006 Single market/LLTV:** one market, one threshold — small audit surface, zero-buffer at the limit (like Morpho Blue)
- **0007 Key mgmt/reentrancy:** `Ownable2Step` + `nonReentrant` — cheap hardening, doesn't remove single-key trust
- **0008 Simple interest:** linear, non-compounding, sub-unit interest not forfeited — legible, marginally gameable

## What's mocked/hardcoded

- **USDr:** plain ERC20 stand-in, no Rayls bridge dependency — swap = constructor address, no code change
- **AmFi token (mAMFI):** mock ERC20 standing in for the real bridged AmFi token
- **Interest curve:** illustrative demo rates (2% base + 10% slope, 12% max) — not calibrated to real credit risk or T-bills
- **LLTV/bonus/fee (70% / 5% / 15%):** defensible illustrative constructor params, not empirically tuned
- **Deployment target:** local Anvil — real Rayls testnet blocked on gated credentials

