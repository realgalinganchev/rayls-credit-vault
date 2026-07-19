# 7. Two-step ownership and reentrancy defense-in-depth

Status: Accepted

## Context

Privileged roles (market owner/curator, fee recipient, NAV setter) carry real
power and there is no timelock or multisig in the PoC. Separately, the market
and vault move ERC-20 tokens, and a loan asset with transfer hooks (ERC-777
style) could open cross-function reentrancy.

## Decision

- Use `Ownable2Step` on the market and the mock issuer, so ownership cannot be
  handed to a wrong or unrecoverable address in a single call.
- Apply `nonReentrant` across every state-changing market entrypoint and the
  vault's internal deposit/withdraw funnels (covering all four ERC-4626
  entrypoints).

## Consequences

- Fat-fingered ownership transfer is prevented; reentrancy is blocked even if
  the vault is ever pointed at a hook token (cheap defense-in-depth — USDr today
  is a plain, non-callback ERC-20).
- These do **not** remove the underlying single-key trust. Reducing the owner's
  *power* — timelock, multisig, role separation — is a separate production item
  (see ADR 0004).

## Alternatives rejected

- **Plain `Ownable`** — a one-call transfer to a dead address is unrecoverable.
- **Rely on the loan token being non-callback** — true today, fragile as a
  standing invariant.
