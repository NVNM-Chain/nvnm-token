# Trust model

This document states what the NVNM token contract does and how each claim can
be verified independently on chain.

## The contract

`NVNMToken` is an ERC-20 with EIP-2612 permits, composed from two OpenZeppelin
v5 modules: `ERC20` and `ERC20Permit`. It declares no state of its own, uses no
assembly and adds no logic beyond a constructor that mints the entire supply
once.

Total supply is 1,000,000,000 NVNM at 18 decimals, minted to the treasury in the
transaction that deploys the token.

## Every account is treated alike

Every function behaves identically for every caller. The deployer, the treasury
and NVNM Foundation Limited hold no special authority over the token. From
deployment onwards:

| Property | Behaviour |
| -------- | --------- |
| Code and parameters | Fixed at deployment. |
| Supply | Constant at 1,000,000,000 NVNM. |
| Movement of tokens | Only a holder, or a spender it has approved, can move its tokens. |
| Availability | Any holder can transfer its tokens at any time; no account can be singled out or restricted. |
| Transfer amounts | Transfers deliver the exact amount sent. |
| Balances | Change only through transfers. |
| Limits | Holdings and transfer sizes are unlimited. |
| Metadata | Name, symbol, decimals and the permit domain's name and version are fixed. |
| Tokens or ether sent to the token contract | Stay there permanently. |

These are properties of the deployed code rather than commitments by an
operator, so no later action can withdraw them. The same permanence applies to
defects: the contract cannot be patched in place, and a correction would need a
new token at a new address.

Transfers make no recipient callback, so the token introduces no reentrancy
surface into integrating contracts.

## The treasury

The constructor mints the entire supply to one treasury address. The treasury is
an ordinary holder: it has no power over the contract or over any other
account's tokens. It does hold the entire supply until it distributes tokens, so
how the treasury is controlled matters to every holder. On Ethereum mainnet and
Base mainnet the treasury is the approved Safe recorded as a reviewed constant
in `script/config/Config.sol`; testnet deployments may use a single key. The
treasury of each deployment is published with its record in
[deployments/](../deployments/README.md).

## Notes for integrators

- Standard ERC-20 allowance replacement carries transaction-ordering risk, and
  an infinite allowance is not decremented by `transferFrom` in OpenZeppelin v5.
- The EIP-2612 domain uses the token address, the current chain ID, name
  `NVNM Token` and version `1`. Nonces prevent replay within that domain. The
  domain separator is cached at deployment and rebuilt whenever the chain ID
  differs, so signatures do not carry across a chain split that changes the
  chain ID; a split that preserves the chain ID does not produce separate
  domains.
- Permit signatures are ECDSA only; the token does not add ERC-1271
  contract-wallet signature support. Offer a standard `approve` path alongside
  permit, and handle a nonce already consumed by a competing submission.
- Tokens or ether sent to the token contract cannot be recovered. Ether can
  arrive without a payable entrypoint; an ether balance does not affect token
  balances or supply.

## Verification

Every claim in this document is independently checkable. `script/check-abi.py`
fixes the callable interface: ERC-20, EIP-2612 `permit`, `nonces` and
`DOMAIN_SEPARATOR`, EIP-5267 `eip712Domain`, `INITIAL_SUPPLY` and a constructor
taking the treasury address, and nothing else. `script/VerifyDeployment.s.sol`
compares the deployed runtime bytecode with an approved local build, resolving
the compiler's EIP-712 immutables, which embed the token's own address and chain
ID, and checks chain ID, metadata, supply and the EIP-712 domain. Finalizing a
deployment record with `script/deployment-manifest.mjs` also checks that the
creation transaction ran the approved creation code with the expected treasury,
and that the treasury held the entire supply at a finalized block.

Expected values must come from an independently reviewed record rather than
being copied from the observed deployment. A verification run establishes the
checked build and state at the time of the check; it does not establish RPC
honesty or custody arrangements.

Unit tests, fuzzing, handler-based invariants, ABI checks and static analysis
provide complementary evidence, applying to the checked commit, tool versions
and explored states. Independent audit reports are published in
[audits/](../audits/README.md) as they are completed.

## Compiler policy

`foundry.toml` pins Solidity 0.8.37, the Prague EVM, optimizer runs of 1,000,000
and `via_ir = false`. `foundry.lock` and the Git submodule entries pin Solidity
dependencies; tool versions and package locks pin the validation environment.
A pinned compiler is reproducible, which is not the same as being free of known
compiler defects — advisories are still reviewed for applicability.

Any source, compiler, dependency or configuration change requires a fresh build,
review of the affected assumptions and repeated validation. The reviewed source
commit, dependency revisions, compiler identity and build artifacts are
preserved for each deployment.
