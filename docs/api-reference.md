> **Note:** Rayls hackathon-starter backend API reference, kept as **reference material only** — not part of the credit-vault PoC. See the root README.

# Backend API Reference

All requests require a Bearer token in the `Authorization` header.

- **User endpoints** (`/api/user/*`): use `USER_AUTH_KEY`
- **Operator endpoints** (`/api/operator/*`): use `OPERATOR_AUTH_KEY`

Replace `$BACKEND_URL`, `$USER_AUTH_KEY`, and `$OPERATOR_AUTH_KEY` with actual values provided by hackathon organizers.

---

## 1. Register User

Creates a user identity and generates wallet addresses for both chains.

```bash
curl -X POST "$BACKEND_URL/api/user/onboarding" \
  -H "Authorization: Bearer $USER_AUTH_KEY" \
  -H "Content-Type: application/json" \
  -d '{"external_user_id": "my-unique-id"}'
```

**Response (201):**
```json
{
  "public_chain_address": "0x1111111111111111111111111111111111111111",
  "private_chain_address": "0x2222222222222222222222222222222222222222",
  "public_chain_private_key": "0xabc...def",
  "private_chain_private_key": "0x123...789",
  "status": 0,
  "created_at": "2026-03-10T12:00:00Z"
}
```

**Save these values!** You'll need:
- `private_chain_address` → `MINT_RECIPIENT` in `.env`
- `private_chain_private_key` → `REGISTERED_PRIVATE_KEY` in `.env`
- `public_chain_address` → `TRANSFER_TO` in `.env`

---

## 2. Approve User

Approves the user's address pair so they can bridge tokens.

```bash
curl -X PATCH "$BACKEND_URL/api/operator/onboarding/status" \
  -H "Authorization: Bearer $OPERATOR_AUTH_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "external_user_id": "my-unique-id",
    "public_address": "0x1111111111111111111111111111111111111111",
    "private_address": "0x2222222222222222222222222222222222222222",
    "new_status": 1
  }'
```

**Status values:** `0` = Pending, `1` = Approved, `2` = Rejected

**Response (200):** Empty on success.

---

## 3. Register Token

Registers your deployed token in the governance system.

```bash
curl -X POST "$BACKEND_URL/api/user/tokens" \
  -H "Authorization: Bearer $USER_AUTH_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Hackathon Token",
    "symbol": "HACK",
    "address": "0xYOUR_DEPLOYED_TOKEN_ADDRESS",
    "uri": "",
    "standard": 1
  }'
```

**Standard values:** `1` = ERC20, `2` = ERC721, `3` = ERC1155

**Response (201):**
```json
{
  "name": "Hackathon Token",
  "symbol": "HACK",
  "address": "0xYOUR_DEPLOYED_TOKEN_ADDRESS",
  "uri": "",
  "standard": 1,
  "status": 0,
  "updated_at": "2026-03-10T12:05:00Z"
}
```

---

## 4. Approve Token

Activates the token, triggering the relayer to deploy a mirror contract on the public chain.

```bash
curl -X PATCH "$BACKEND_URL/api/operator/tokens/status" \
  -H "Authorization: Bearer $OPERATOR_AUTH_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "address": "0xYOUR_DEPLOYED_TOKEN_ADDRESS",
    "status": 1
  }'
```

**Status values:** `0` = Inactive, `1` = Active

**Response (200):** Empty on success.

After approval, the relayer will automatically:
1. Deploy a `PublicChainERC20` mirror contract on the public chain
2. Map the private token address to the public mirror address
3. Authorize the mirror as a sender on the public chain endpoint

This process typically takes 30-60 seconds.

---

## Query Endpoints

### List all address pairs for a user
```bash
curl "$BACKEND_URL/api/user/users/address-pairs?external_user_id=my-unique-id" \
  -H "Authorization: Bearer $USER_AUTH_KEY"
```

### List all registered tokens
```bash
curl "$BACKEND_URL/api/user/tokens" \
  -H "Authorization: Bearer $USER_AUTH_KEY"
```

### List pending tokens (operator view)
```bash
curl "$BACKEND_URL/api/operator/tokens/pending" \
  -H "Authorization: Bearer $OPERATOR_AUTH_KEY"
```
