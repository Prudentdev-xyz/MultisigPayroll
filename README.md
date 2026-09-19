# EIP-712 Multisig Payroll

M-of-N multisig treasury that pays out ETH and ERC-20 payroll from off-chain,
EIP-712-signed owner approvals — relayed on-chain by anyone once quorum is met.

## Overview

Instead of every owner sending a separate on-chain approval transaction,
each owner signs a structured EIP-712 message off-chain (free, no gas).
Once enough valid signatures exist, anyone can submit them together in a
single `execute()` call. The contract verifies the signers, checks the
quorum, and runs the payment.

- Owners and threshold are fixed at deployment, changeable later only
  through the multisig itself.
- One execution path covers both ETH and ERC-20 payroll — an ERC-20 payout
  is just a call into the token contract's `transfer(...)`.
- Signed payloads are bound to a specific chain ID, contract address, and
  nonce, so a signature can't be replayed on another chain, another
  contract, or twice on this one.

## Stack

- Solidity `^0.8.20`
- Foundry (forge/cast/anvil) — scripts and tests only, no Hardhat/TypeScript
- OpenZeppelin Contracts `v5.0.2` (EIP712, ECDSA, ReentrancyGuard)

## Setup

```bash
# 1. Install Foundry (skip if already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 2. Install dependencies
forge install foundry-rs/forge-std --no-git
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git

# 3. Build
forge build

# 4. Test
forge test -vv
```

OpenZeppelin is pinned to `v5.0.2` — their newer `main` branch requires
Solidity 0.8.24+, which breaks the `^0.8.20` target.

## Contract design

`src/MultisigPayroll.sol`

**Payment struct** — the EIP-712 typed message every owner signs:

| Field | Purpose |
|---|---|
| `to` | destination address |
| `value` | ETH amount to send |
| `data` | calldata — empty for a plain ETH transfer, or an encoded `transfer(...)` call for ERC-20 |
| `nonce` | one-time-use identifier; replay-blocked once consumed |
| `deadline` | signature expires after this timestamp |
| `chainId` | binds the signature to one chain |
| `verifyingContract` | binds the signature to this specific deployment |

**`execute(payment, signatures[])`** — callable by anyone once quorum is met:

1. checks `deadline`, `nonce`, `chainId`, `verifyingContract`
2. recovers each signature (`ECDSA.recover`), requires every signer to be
   a current owner, rejects any repeated signer
3. requires at least `threshold` valid, unique signatures
4. marks the nonce used **before** the external call (checks-effects-interactions)
5. calls `to.call{value: value}(data)`
6. reverts the whole transaction if the call fails; emits `PaymentExecuted` on success

**Reentrancy**: `execute` is `nonReentrant` (OpenZeppelin `ReentrancyGuard`),
so a malicious recipient can't re-enter `execute()` from within the
transfer it receives.

**Owner management** (`addOwner`, `removeOwner`, `changeThreshold`) is
gated by `onlySelf` — callable only by the contract itself, meaning only
through a successfully signed `execute()` call that targets the contract's
own address. Owner/threshold changes go through the same signature quorum
as payroll.

## Tests

`test/MultisigPayroll.t.sol` — 26 tests, all passing:

- Constructor validation (zero threshold, threshold > owner count,
  duplicate owner, zero-address owner, empty owner set)
- Main flow: ETH payment, ERC-20 payment, signatures in any order,
  more-than-threshold signatures
- Unauthorized/invalid flows: non-owner signer, duplicate signer,
  too few signatures, malformed signature
- Replay/expiry/domain binding: reused nonce, expired deadline,
  wrong chain ID, wrong verifying contract
- Failed target call handling
- Reentrancy: a malicious recipient tries to re-enter `execute()`
  mid-transfer — blocked
- Owner management via self-execution, and rejected when called directly
- Fuzz test over arbitrary payment amounts and nonces, with a
  replay-after-fuzz check

```bash
forge test -vvv
```

## Deployment

Configuration is read from environment variables — copy `.env.example` to
`.env`, fill in real values, and never commit `.env`:

```
PRIVATE_KEY=0xyour_deployer_private_key
OWNERS=0xOwner1,0xOwner2,0xOwner3
THRESHOLD=2
SEPOLIA_RPC_URL=https://your-rpc-url
ETHERSCAN_API_KEY=your_etherscan_api_key
```

Dry run first:

```bash
source .env
forge script script/DeployMultisigPayroll.s.sol:DeployMultisigPayroll \
  --rpc-url $SEPOLIA_RPC_URL \
  -vvvv
```

Then broadcast for real:

```bash
forge script script/DeployMultisigPayroll.s.sol:DeployMultisigPayroll \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

The deployer wallet only pays gas — it doesn't need to be one of the
`OWNERS` unless you want it to be.

## Security notes

- No private keys or RPC/API secrets are committed — `.env` is git-ignored.
- All state-changing owner actions require the same M-of-N signature
  quorum as payroll; there is no privileged single-key admin path.
- Signed payloads are single-chain, single-contract, single-use by design
  (chain ID + verifying contract + nonce all checked on-chain).

## License

MIT
```