# Architecture Decision Records

This directory records the load-bearing design decisions behind the Rayls
Credit Vault — the *why* that inline code comments can't carry. Format follows
the standard ADR structure (context → decision → consequences → alternatives
rejected), one decision per file, numbered and append-only: once a decision has
shipped, supersede it with a new record rather than editing it.

| #                                           | Decision                                                    | Status          |
| ------------------------------------------- | ----------------------------------------------------------- | --------------- |
| [0001](0001-share-accounting-virtual-offset.md) | Share accounting with a virtual shares/assets offset    | Accepted        |
| [0002](0002-bad-debt-socialization.md)      | Socialize bad debt on collateral exhaustion, keyed on value | Accepted        |
| [0003](0003-issuer-redemption-exit.md)      | Issuer-redemption exit for seized collateral                | Accepted        |
| [0004](0004-nav-oracle-trust-model.md)      | Owner-set NAV oracle with a non-zero invariant              | Accepted (PoC)  |
| [0005](0005-erc4626-curated-vault.md)       | ERC-4626 curated vault, EIP-4626-compliant under illiquidity | Accepted       |
| [0006](0006-single-market-single-lltv.md)   | Single market, single LLTV                                  | Accepted (PoC)  |
| [0007](0007-key-management-reentrancy.md)   | Two-step ownership + reentrancy defense-in-depth            | Accepted        |
| [0008](0008-simple-interest-accrual.md)     | Simple, non-compounding interest at spot utilization        | Accepted (PoC)  |

Terms used here are defined in [../GLOSSARY.md](../GLOSSARY.md). The solvency
properties several of these decisions rest on are continuously checked by the
fitness-function suite in [`test/invariant/`](../../test/invariant).
