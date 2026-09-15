# Isogate Robinhood Chain mainnet contracts

This directory contains isolated infrastructure source only. It does **not**
contain an ERC-20 token contract, a token address, deployment scripts, private
keys, or application/frontend code. The ERC-20 used by escrow and bonds must be
an externally deployed token address supplied explicitly to each constructor.
No ISOC token address is assumed or hardcoded.

## Contracts

- `JobEscrowSettlement.sol` holds each requester's exact quoted amount under a
  globally unique `bytes32 jobId`. Funding uses
  `createJob(bytes32 jobId, uint256 quotedAmount, uint64 refundAfter)`, where
  `refundAfter` must be a future Unix timestamp and is immutable for that job.
  A requester can refund only at or after that timestamp. A holder of
  `SETTLEMENT_ROLE` can perform an authorized cancellation refund earlier when
  needed. A settlement operator can otherwise finalize the job once with
  provider/verifier/treasury splits. Settlements and refunds are accounted as
  pull payments; recipients call `withdraw()`.
- `ProviderBond.sol` accepts provider deposits of the configured token. Bond
  operators can reserve each unique dispute ID once, then release or slash the
  lock once. Slash beneficiaries withdraw their credited amount with
  `withdrawSlashedFunds()`.
- `ReceiptRegistry.sol` stores only a job ID mapping to a result digest, the
  registry-derived receipt hash, provider, accepted timestamp, and schema
  version. It stores no trace or other large result payload. Issuers call
  `issueReceipt(jobId, resultDigest, receiptHash, provider, version)`; the
  supplied hash must equal the contract-derived canonical hash and is never
  trusted without that check.
- `ContractPrimitives.sol` contains the self-contained ERC-20 call checks,
  two-step administrator transfer, role controls, pause primitive, and
  reentrancy guard shared by the contracts. It has no third-party imports.

All contracts use Solidity `>=0.8.24`, custom errors, checks-effects-
interactions, strict ERC-20 return-value checks, and exact-balance checks that
reject fee-on-transfer behavior. Token withdrawals remain callable while
paused so already-accounted-for user funds can be pulled.

## Constructor parameters and deployment order

1. Deploy or otherwise identify the **independently governed** ERC-20 token
   contract. Its address is an explicit deployment input, not an address
   supplied by this repository.
2. Deploy `JobEscrowSettlement(address token_, address initialAdmin)`.
   `token_` is the ERC-20 contract and `initialAdmin` is the initial
   administrator.
3. Deploy `ProviderBond(address token_, address initialAdmin)` with the same
   externally supplied token address and an initial administrator.
4. Deploy `ReceiptRegistry(address initialAdmin)`. It does not need a token.

Use a multisig or timelock as `initialAdmin` where appropriate. Verify the
constructor arguments and deployed bytecode before enabling any production
flow. Deployment order can be adjusted for operational needs, but the token
must exist and be an ERC-20 contract before the escrow and bond constructors
are called.

## Required post-deployment role setup

Each constructor grants its initial administrator:

- `JobEscrowSettlement`: `SETTLEMENT_ROLE` and `PAUSER_ROLE`.
- `ProviderBond`: `BOND_OPERATOR_ROLE` and `PAUSER_ROLE`.
- `ReceiptRegistry`: `ISSUER_ROLE` and `PAUSER_ROLE`.

Before accepting mainnet funds, the administrator should:

1. Grant each operational role only to the reviewed settlement service,
   dispute committee, receipt issuer, and emergency-pauser accounts that need
   it.
2. Exercise and review a role-restricted call on the intended account.
3. Revoke the initial administrator's operational roles if they are not
   needed, and revoke any temporary setup accounts.
4. Transfer administration with `transferAdmin(newAdmin)`, then have the new
   administrator call `acceptAdmin()` from the intended multisig/timelock.
   Role revocation is separate from administrator transfer; review both.
5. Keep a tested pause/unpause runbook and monitor all emitted events.

Role identifiers are exposed as the public constants
`SETTLEMENT_ROLE`, `BOND_OPERATOR_ROLE`, `ISSUER_ROLE`, and `PAUSER_ROLE`.
No role is an authorization substitute for independent off-chain policy,
dispute review, or multisig controls.

## Integration notes

When funding an escrow job, choose and persist a future `refundAfter`
timestamp, then pass it to `createJob` with the quoted amount. The timestamp
cannot be changed after funding. A requester transaction submitted before the
deadline is rejected even if it is reordered ahead of settlement; the
settlement role remains able to issue an explicit cancellation refund. Watch
`JobCreated` and `JobRefunded` for the deadline and whether a settlement-role
account initiated a refund. All resulting balances remain pull payments.

Receipt hashes are canonical and deployment-specific. For a receipt accepted
at timestamp `acceptedAt`, derive the expected value by calling
`computeReceiptHash(jobId, resultDigest, provider, acceptedAt, version)` on the
deployed registry, then pass that result as `receiptHash` to
`issueReceipt`. Equivalently, it is
`keccak256(abi.encode(RECEIPT_HASH_DOMAIN, block.chainid, address(registry),
jobId, resultDigest, provider, acceptedAt, version))`, where the domain is the
versioned `IsogateReceiptRegistry:Receipt:v1` constant exposed by the
registry. The contract records this derived value in `ReceiptIssued`; clients
should compare that event and `getReceipt` output rather than accept a
caller-provided hash.

## Robinhood Chain mainnet

- Chain ID: `4663`
- RPC: `https://rpc.mainnet.chain.robinhood.com/`
- Explorer: `https://robinhoodchain.blockscout.com`

Confirm these endpoints and the token address independently at deployment
time. This repository does not deploy anything and does not request or store
private keys.

## Review and audit warning

This source is **unaudited**. It has not been approved for production or
mainnet funds. An independent professional security audit, focused tests,
compiler-version pinning, deployment rehearsal, token-behavior review, and
multisig operational review are required before any mainnet deployment.
Compilation and tests remain a deployment prerequisite; no compiler/toolchain
is bundled in this isolated directory.

## Genesis v2 launch invariants

Future Genesis launches use `contracts/genesis/IsogateGenesisToken.sol` and the
v2 coordinator configuration. The constructor mints `1,000,000,000e18` once
and calls ERC-20 `_burn` for `1,000,000e18`, leaving a final
`999,000,000e18` supply and a `Transfer` event to the zero address. No genesis
amount is minted to the dead address; only post-liquidity dust is sent there.
Ownership emits the standard Ownable lifecycle and is renounced in the
constructor, with no privileged token functions.

The fixed pool ratio is `sqrtPriceX96 = 34,500 * Q96`, or
`1,190,250,000` token units per native unit. This is a fixed protocol
parameter, not a statement about market value or future returns.

To prepare local verification inputs without submitting anything, set the
explicit `GENESIS_VERIFY_*` values and run `pnpm run prepare-verification`.
The helper writes a small input record under `verification/local/`; it has no
network submission path and does not read deployment credentials.

Runtime bytecode checks should be performed independently for each deployed
instance with reviewed constructor values and compiler output. This repository
does not include production reconciliation state or deployment automation.
