> **Note:** This document describes the Rayls hackathon starter (Privacy-Node bridge + backend), kept as **reference material only**. It is NOT the architecture of this repo's credit-vault PoC — see the root README.

# Rayls Architecture Overview

## What Is Rayls?

A **Privacy Node** is a sovereign, gasless EVM blockchain where only authorized participants can see transactions and balances. A **Public Chain** is a standard blockchain where anyone can view activity. Rayls lets you issue and manage assets privately, then selectively bridge them to a public chain when you're ready to disclose.

## The Five-Phase Flow

This is the full hackathon journey — from invisible to tradeable:

```
Design Privately → AI Attestation → Governance & Approval → Bridge & Simplify → List & Trade
   (Privacy Node)    (AI agent)       (AI + human review)    (Rayls bridge)      (Public L1)
```

| Phase | What Happens | Where |
|-------|-------------|-------|
| 1. Design Privately | Deploy tokens with rich metadata and access rules | Privacy Node |
| 2. AI Attestation | AI agent inspects the asset and posts a signed proof of existence | Public Chain |
| 3. Governance | AI compliance agent reviews; human approves disclosure | Privacy Node |
| 4. Bridge | `teleportToPublicChain()` locks privately, mints publicly | Both chains |
| 5. List & Trade | Deploy a marketplace; bridged asset becomes tradeable | Public Chain |

This starter repo covers **phases 1 and 4** — deploying a token and bridging it. You'll build the AI, governance, and marketplace layers on top.

## System Components

The Rayls bridge connects a **Privacy Node** (where your token lives) to a **Public Chain** (where tokens become publicly visible). An off-chain **relayer** watches for events and shuttles messages between the two chains.

```
┌───────────────────────┐                          ┌───────────────────────┐
│     PRIVACY NODE      │                          │     PUBLIC CHAIN      │
│                       │                          │                       │
│  Your Token           │    ┌──────────────┐      │  Mirror Token         │
│  (RaylsErc20Handler)  │◄──►│   RELAYER    │◄────►│  (PublicChainERC20)   │
│                       │    │   (Go svc)   │      │  [auto-deployed]      │
│  RNEndpointV1         │    └──────────────┘      │  PublicRNEndpointV1   │
│  RNTokenGovernanceV1  │                          │  RNMessageExecutorV1  │
│  RNUserGovernanceV1   │                          │                       │
└───────────────────────┘                          └───────────────────────┘
```

## How Bridging Works

### Private → Public (Lock & Mint)

When you call `teleportToPublicChain()`:

1. Tokens are **locked** on the Privacy Node (transferred to the contract owner)
2. A cross-chain message is dispatched (via `RNEndpointV1`)
3. The relayer picks up the `MessageDispatched` event
4. The relayer submits the message to the public chain
5. The mirror contract **mints** new tokens for the recipient

```
Privacy Node                      Relayer                    Public Chain
     │                              │                            │
     │  teleportToPublicChain()     │                            │
     │  ── lock tokens ──►          │                            │
     │  ── dispatch message ──►     │                            │
     │                              │  picks up event            │
     │                              │  ── submits message ──────►│
     │                              │                            │  mint tokens
     │                              │                            │  ──► recipient
```

### Public → Private (Burn & Unlock)

When someone calls `teleportToPrivacyNode()` on the public chain mirror:

1. Tokens are **burned** on the public chain
2. Message dispatched → relayer picks up → submits to Privacy Node
3. Previously locked tokens are **unlocked** and transferred to the recipient

### Failure Safety

Every cross-chain message includes a pre-generated **revert payload**. If the destination execution fails:
- The relayer detects the failure
- Submits the revert payload back to the source chain
- Locked tokens are unlocked (or burned tokens are minted back)

**Tokens are never lost.**

## Token Lifecycle

```
   Write Contract ──► Deploy ──► Register ──► Approve ──► Mirror Deployed ──► Bridgeable
   (you)              (you)      (you/API)    (you/API)   (relayer, auto)     (ready!)
```

1. **Write**: Inherit from `RaylsErc20Handler`
2. **Deploy**: Deploy to the Privacy Node with Foundry
3. **Register**: Call the backend API to add your token to `RNTokenGovernanceV1` (status: INACTIVE)
4. **Approve**: Call the backend API to activate it (status: ACTIVE, emits `TokenActivated`)
5. **Mirror Deployed**: The relayer detects `TokenActivated`, deploys a `PublicChainERC20` on the public chain, and maps the addresses
6. **Bridgeable**: `teleportToPublicChain()` now works end-to-end

## Why the Constructor Uses `_mint()` Instead of `mint()`

You'll notice `HackathonToken`'s constructor calls the internal `_mint()` rather than the public `mint()`:

```solidity
constructor(...) RaylsErc20Handler(...) {
    _mint(msg.sender, 1_000_000 * 10 ** 18);
}
```

This is intentional. The public `mint()` inherited from `RaylsErc20Handler` does two things:
1. Mints tokens to the recipient
2. Calls `_submitTokenUpdate()`, which sends a cross-chain message to the commit chain's `TokenRegistry` to report the supply change

At construction time, the token **does not have a `resourceId` yet** — that is assigned later when the token is registered and approved via the governance API. Without a `resourceId`, the cross-chain message would fail.

By using the internal `_mint()`, we skip the cross-chain notification and just update the local balance. Once the token is registered and has a `resourceId`, subsequent calls to `mint()` (the public function) will correctly notify the `TokenRegistry`.

**Rule of thumb:** Use `_mint()` in the constructor, use `mint()` everywhere else.

## Key Contracts

| Contract | Purpose |
|---|---|
| `RaylsErc20Handler` | Base class for your token. Provides teleport, mint, burn, lock/unlock. |
| `RNEndpointV1` | Message gateway on the Privacy Node. Routes cross-chain messages. |
| `RNUserGovernanceV1` | User registry. Controls who can call `teleportToPublicChain`. |
| `RNTokenGovernanceV1` | Token registry. Maps private token addresses to public mirrors. |
| `PublicChainERC20` | Auto-deployed mirror on the public chain. Burn/mint model. |
| `DeploymentProxyRegistryV1` | On-chain registry to discover all infrastructure contract addresses. |

## Access Control

- **`onlyRegisteredUsers`**: Only approved users in `RNUserGovernanceV1` can call `teleportToPublicChain()`. Pass `address(0)` as userGovernance to disable this check.
- **`onlyOwner`**: Only the token owner (deployer) can call `mint()` and `burn()`.
- **`receiveMethod`**: Only the trusted message executor can call receive functions (prevents unauthorized minting).

## Inherited API Reference

Your token inherits from `RaylsErc20Handler`. Here are the key functions you can call or override — no need to dig through the source:

### Bridging (Privacy Node ↔ Public Chain)

| Function | Access | Description |
|----------|--------|-------------|
| `teleportToPublicChain(address to, uint256 value, uint256 chainId)` | `onlyRegisteredUsers` | Lock tokens on Privacy Node, mint on Public Chain |
| `receiveTeleportFromPublicChain(address to, uint256 value)` | `receiveMethod` | Unlock tokens when returning from Public Chain. **Override this** to add custom validation on incoming transfers. |
| `revertTeleportToPublicChain(address to, uint256 value)` | `receiveMethod` | Called automatically by the relayer if the public-side mint fails. Unlocks tokens. |

### Bridging (Privacy Node ↔ Privacy Node)

| Function | Access | Description |
|----------|--------|-------------|
| `teleport(address to, uint256 value, uint256 chainId)` | public | Send tokens to another Privacy Node via the commit chain |
| `teleportAtomic(address to, uint256 value, uint256 chainId)` | public | Atomic cross-chain transfer with 240-second timeout. All-or-nothing. |
| `receiveTeleport(address to, uint256 value)` | `receiveMethod` | Receive tokens from another Privacy Node. **Override this** for custom logic. |

### Token Management

| Function | Access | Description |
|----------|--------|-------------|
| `mint(address to, uint256 value)` | `onlyOwner` | Mint tokens and notify the commit chain's TokenRegistry |
| `burn(address from, uint256 value)` | `onlyOwner` | Burn tokens and notify the commit chain's TokenRegistry |
| `getLockedAmount(address account)` | view | Check how many tokens are currently locked (bridged to public chain) |
| `GetERCStandard()` | view | Returns the token standard enum (ERC20) |

---

## ERC721 API Reference (`RaylsErc721Handler`)

For NFT-based projects (e.g., Confidential NFT Reveal challenge). Inherit from `RaylsErc721Handler`.

### Bridging

| Function | Access | Description |
|----------|--------|-------------|
| `teleportToPublicChain(address to, uint256 tokenId, uint256 chainId)` | `onlyRegisteredUsers` | Lock NFT on Privacy Node, mint on Public Chain |
| `receiveTeleportFromPublicChain(address to, uint256 tokenId)` | `receiveMethod` | Unlock NFT returning from Public Chain. **Overridable.** |
| `teleport(address to, uint256 tokenId, uint256 chainId)` | public | Send NFT to another Privacy Node |
| `teleportAtomic(address to, uint256 tokenId, uint256 chainId)` | public | Atomic cross-chain NFT transfer with timeout |

### Token Management

| Function | Access | Description |
|----------|--------|-------------|
| `mint(address to, uint256 tokenId)` | `onlyOwner` | Mint NFT with specific token ID |
| `burn(uint256 tokenId)` | `onlyOwner` | Burn NFT by token ID |
| `isTokenLocked(address owner, uint256 tokenId)` | view | Check if a specific NFT is locked (bridged) |

---

## ERC1155 API Reference (`RaylsErc1155Handler`)

For multi-token projects. Inherit from `RaylsErc1155Handler`.

### Bridging

| Function | Access | Description |
|----------|--------|-------------|
| `teleportToPublicChain(address to, uint256 id, uint256 amount, uint256 chainId, bytes data)` | `onlyRegisteredUsers` | Lock tokens on Privacy Node, mint on Public Chain |
| `receiveTeleportFromPublicChain(address to, uint256 id, uint256 amount)` | `receiveMethod` | Unlock tokens returning from Public Chain. **Overridable.** |
| `teleport(address to, uint256 id, uint256 amount, uint256 chainId, bytes data)` | public | Send tokens to another Privacy Node |
| `teleportAtomic(address to, uint256 id, uint256 amount, uint256 chainId, bytes data)` | public | Atomic cross-chain transfer with timeout |

### Token Management

| Function | Access | Description |
|----------|--------|-------------|
| `mint(address to, uint256 id, uint256 amount, bytes data)` | `onlyOwner` | Mint tokens with specific ID and amount |
| `burn(address from, uint256 id, uint256 amount)` | `onlyOwner` | Burn tokens by ID and amount |
| `getLockedAmount(address account, uint256 id)` | view | Check locked amount for a specific token ID |
