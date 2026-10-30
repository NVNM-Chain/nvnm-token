# NVNM ERC-20

ERC-20 implementation for NVNM Token.

## Token behavior

| Parameter     | Value                                                           |
| ------------- | --------------------------------------------------------------- |
| Name / symbol | `NVNM Token` / `NVNM`                                           |
| Decimals      | 18                                                              |
| Supply        | 1,000,000,000 tokens, minted once to the treasury at deployment |
| Standard      | ERC-20 with EIP-2612 `permit`                                   |

Every function behaves identically for every caller: the deployer, the treasury
and NVNM Foundation Limited hold no special authority. The token's code,
parameters and supply are fixed at deployment, and only a holder, or a spender
it has approved, can move its tokens. Read the [trust model](docs/TRUST-MODEL.md)
before integrating the token.

## Deployments

| Network           | Chain ID | Token                                                                                                                           | Record                                                                            |
| ----------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Sepolia (testnet) | 11155111 | [`0x51307001c9AC37D35fB9BD3b39e216eeC6e01bC7`](https://sepolia.etherscan.io/address/0x51307001c9AC37D35fB9BD3b39e216eeC6e01bC7) | [confirmed](deployments/11155111-0x51307001c9ac37d35fb9bd3b39e216eec6e01bc7.json) |

The source is verified on Etherscan and Sourcify. `make verify NETWORK=sepolia`,
with `NVNM_TOKEN_ADDRESS` and `EXPECTED_CHAIN_ID` taken from the record,
re-checks the live token against an approved local build.

**The Sepolia deployment exercises the deployment and verification pipeline.**
Its deployer and treasury are a single test key, and its tokens have no value.

No Ethereum mainnet or Base mainnet deployment exists. The production treasury
constants in [script/config/Config.sol](script/config/Config.sol) are still
`address(0)`, which makes any production run revert until governance approves
the addresses in a reviewed diff.

## Quick start

Install Foundry 1.8.3, Node.js 24.21.0 and Python 3.12.
Dependency revisions are recorded in `foundry.lock` and the Git submodule entries.

```bash
git clone --recurse-submodules https://github.com/NVNM-Chain/nvnm-token.git
cd nvnm-token
make install
make build
make test
```

An RPC endpoint, wallet and `.env` file are only needed for network operations.
Use [CONTRIBUTING.md](CONTRIBUTING.md) for the full development setup, including
`make install-security` before running Slither or `make release-check`.

## Development commands

| Command              | Purpose                                                 |
| -------------------- | ------------------------------------------------------- |
| `make build`         | Compile and report contract sizes                       |
| `make test`          | Unit, fuzz, invariant, deployment and gas tests         |
| `make test-ci`       | CI fuzz and invariant settings                          |
| `make test-lite`     | Faster local feedback; not a release check              |
| `make fmt-check`     | Solidity formatting check                               |
| `make coverage`      | Coverage report                                         |
| `make check-deps`    | Dependency integrity checks                             |
| `make gas`           | Regenerate gas documentation                            |
| `make check`         | Formatting, lint, tests, dependency, ABI and gas checks |
| `make release-check` | All local checks, including Slither                     |

Tests cover construction, ERC-20 behavior, permit signatures, stateful
invariants and deployment checks. Passing tests and high coverage describe the
exercised cases; neither proves the absence of vulnerabilities.

## Repository layout

```text
src/NVNMToken.sol      production contract
script/                deployment, verification and reproducibility tools
test/                  unit, fuzz, invariant and regression tests
docs/TRUST-MODEL.md    properties, verification and integrator notes
docs/GAS.md            generated benchmark report
audits/                independent audit reports and response records
deployments/           confirmed deployment records and schema
```

## Build and gas

The Solidity compiler and build settings are pinned in `foundry.toml`:
Solidity 0.8.37, Prague EVM, optimizer enabled with 1,000,000 runs and
`via_ir = false`. OpenZeppelin Contracts is pinned to its v5.7.0 release
commit. Source, dependency, compiler or setting changes require a new verified
build.

The benchmark compares `NVNMToken` with a plain OpenZeppelin ERC-20 without
permit. Read [the methodology](docs/GAS.md) before using a number: measured
call costs are not necessarily the gas paid by a standalone wallet transaction.

## Security and contributions

Report vulnerabilities privately to [security@nvnmchain.io](mailto:security@nvnmchain.io).
See [SECURITY.md](SECURITY.md) for scope and reporting guidance. Do not include
exploit details in a public issue before coordinated disclosure.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and review expectations,
and [audits/README.md](audits/README.md) for audit status and report requirements.

## License

[MIT](LICENSE). Third-party dependencies retain their respective licenses.
