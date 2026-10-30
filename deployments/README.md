# Deployment records

A confirmed record identifies the token, its creation transaction and the
evidence used to verify them. The recorded token address is the integration
address.

## Current deployments

| Network           | Chain ID | Token                                        | Treasury                                     | Confirmed record                                                                     |
| ----------------- | -------- | -------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------ |
| Sepolia (testnet) | 11155111 | `0x51307001c9AC37D35fB9BD3b39e216eeC6e01bC7` | `0x40E511F03DF69f35C778411c9BDd2E2cbfC6b445` | [11155111-0x5130…bc7.json](11155111-0x51307001c9ac37d35fb9bd3b39e216eec6e01bc7.json) |

The Sepolia token is source-verified on Etherscan and Sourcify, and its record
was finalized as described below. It exercises the deployment and verification
pipeline: its deployer and treasury are a single test key, which testnets take
from the `TREASURY` environment variable, and its tokens have no value. No
Ethereum mainnet or Base mainnet deployment exists; their treasuries are
reviewed constants in `script/config/Config.sol`.

## Simulation versus confirmation

`script/Deploy.s.sol` writes `simulations/<chainId>-<network>.json` with
`status: "simulation"`. This is local simulation output, including when the
script is invoked with `--broadcast`; it is not a mined transaction record.
Simulation files are excluded from published deployment records.

After broadcast, `script/deployment-manifest.mjs finalize` verifies the
receipt, the creation input and the approved build against finalized chain
state. It writes `<chainId>-<token-lowercase>.json` with `status: "confirmed"`,
atomically and without overwriting an existing record. Keep these files in
version control. Finalize before the treasury distributes any tokens: the
record attests that the treasury holds the entire supply at the observed block.

## Reviewed expectations input

Supply a JSON file containing every field below, and no others. Addresses are
symbolic in this example; replace them with reviewed values before use.

```json
{
  "chainId": 11155111,
  "token": "0xTOKEN_ADDRESS",
  "deployer": "0xDEPLOYER_ADDRESS",
  "treasury": "0xTREASURY_ADDRESS"
}
```

The file must describe the approved plan independently of the state being
checked. Review it before finalization. Keep it outside the source checkout or
commit it before selecting the source commit; untracked source files make the
checkout dirty and prevent finalization.

```bash
node script/deployment-manifest.mjs finalize \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --expected /absolute/path/to/reviewed-expectations.json \
  --token-tx 0xTOKEN_CREATION_TRANSACTION_HASH
```

The CLI requires a clean source checkout and regenerates its local build offline
before reading artifacts. `FOUNDRY_*` and `DAPP_*` environment overrides are
ignored for this build; the reviewed default profile controls it. Foundry/Dapp
overrides in `.env` are rejected; RPC-only environment files remain supported.
Install the pinned compiler/dependencies first and
archive any needed build information before the clean rebuild. Build sources
must belong to the tracked checkout or its recorded submodules.
A successful receipt alone is insufficient: chain, creation transaction,
bytecode and selected token state must also agree with the reviewed build and
expectations. It checks canonical block hashes and finalized inclusion; it does
not make an untrusted RPC honest.

## Confirmed schema

| Field                                              | Meaning                                                         |
| -------------------------------------------------- | --------------------------------------------------------------- |
| `schemaVersion`, `status`                          | Record format version (`1`) and `confirmed` classification      |
| `chainId`                                          | Network identity checked against the RPC                        |
| `token`                                            | Token address                                                   |
| `deployer`, `treasury`                             | Creation signer and initial supply recipient                    |
| `initialSupply`                                    | Checked supply, held entirely by the treasury when observed     |
| `observation`                                      | State observation block number/hash and `finality: "finalized"` |
| `transaction`                                      | Creation transaction hash and canonical block reference         |
| `codeHash`                                         | Token runtime code hash                                         |
| `provenance.sourceCommit`, `provenance.sourceTree` | Exact clean Git source identity                                 |
| `provenance.submodules`                            | Dependency revisions used by the source checkout                |
| `provenance.compiler`, `provenance.settings`       | Compiler identity and actual build settings                     |
| `provenance.artifacts`, `provenance.sources`       | Build artifact and source hashes for independent reproduction   |

Use `provenance.sourceCommit` to rebuild. Do not assume the later commit that
adds the record is the source revision compiled for deployment. The token's
EIP-712 immutables contain its own address and chain ID, so the runtime code
differs between deployments; comparisons must resolve those compiler-identified
bytes before hashing the code.
