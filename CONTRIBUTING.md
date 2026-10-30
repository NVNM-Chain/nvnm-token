# Contributing

## Development setup

Use Foundry 1.8.3, Node.js 24.21.0 and Python 3.12.
The compiler is selected by `foundry.toml`. JavaScript tool versions are locked
in `package-lock.json`; Solidity dependencies use pinned Git submodules.

```bash
git clone --recurse-submodules https://github.com/NVNM-Chain/nvnm-token.git
cd nvnm-token
make install
make build
make test
```

`make install` initializes submodules and runs `npm ci --ignore-scripts`.
Before `make release-check`, run `make install-security` to create the local
Python environment and install Slither from the hash-locked requirements.
That target needs a Python 3.12 with `ensurepip` — the CI runner and Homebrew's
`python@3.12` both qualify. A uv-managed interpreter does not, so if
`make install-security` fails in `ensurepip`, build the same hash-verified
environment with uv directly:

```bash
uv python install 3.12
uv venv --python 3.12 .venv-security
uv pip install --python .venv-security/bin/python \
  --require-hashes -r requirements-security.txt
make slither
```

A wallet, RPC URL or
`.env` file is not required for local tests. For a network operation, copy
`.env.example` to `.env` and fill in only the necessary values; never commit
private keys, credentials or authenticated RPC URLs.

### Bumping Solidity dependencies

Solidity dependencies are pinned Git submodules, bumped by hand to reviewed
upstream release tags — never to a branch head. `foundry.lock` records the tag
name and revision for each; `make check-deps` (part of `make check`) verifies
every submodule sits at exactly that revision and has no untracked content.

Dependabot does not manage these. Its `gitsubmodule` ecosystem follows the
tracked branch's newest commit and prefers a release tag only when that tag sits
on that branch; OpenZeppelin publishes releases from `release-v5.x` rather than
`master`, so it can only ever propose unreleased code. The `Dependency watch`
workflow opens an issue when an upstream release or security advisory appears —
act on that, not on a bot PR.

```bash
git -C lib/openzeppelin-contracts fetch --tags
git -C lib/openzeppelin-contracts checkout <tag>
git submodule update --init --recursive
# update the tag names and revisions in foundry.lock to match, then:
make check
```

## Development loop

```bash
make test-lite      # fast feedback
make fmt           # format Solidity
make test          # normal unit, fuzz and invariant settings
make check         # full local checks except Slither
make release-check # also run pinned Slither analysis
```

`make check` covers formatting, Solhint, strict tests, tooling tests, dependency
integrity, the ABI allowlist and gas freshness.
Read the Makefile and CI workflows for the commands and profiles actually used.
A green check is evidence for that commit and environment, not a security audit.

When benchmark inputs change, run `make gas` and review the generated
`docs/GAS.md`. Do not edit the report by hand. Tests, coverage and benchmarks
exercise different compiler profiles; use the configured benchmark command
before comparing gas results.

## Changes affecting the contract or deployment

Explain the trigger, intended behavior and trust-model impact in the pull
request. Source comments can affect compiler metadata even when runtime behavior
is unchanged; compiler, dependency and build-setting changes also require a
fresh build and verification.

- Add regression tests for meaningful behavior or security changes. Prefer exact
  custom errors and arguments when the distinction matters.
- Update the ABI allowlist deliberately if a public interface changes.
- Keep [the trust model](docs/TRUST-MODEL.md) and deployment instructions accurate.
- Review any new external call, dependency or deployment path explicitly. The
  token treats every caller alike by design; giving any account special
  authority is a change to the trust model, not an implementation detail.
- Reassess which previous audit findings and conclusions remain applicable;
  do not claim an earlier report covers unreviewed changes.

A deployed token cannot be changed. A contract change only ever affects future
deployments, each at a new address.

## Test conventions

Use Foundry names such as `test_Thing`, `testFuzz_Thing` and
`invariant_Property`. Read external values into local variables before
`vm.prank` so an argument-evaluation call does not consume the prank.

Handler-based invariants cover the actions and actors the handler can reach.
Keep their names and documentation scoped accordingly.

## Review and security reports

Use descriptive commits and focused pull requests. Describe the validation run
and any gaps. Repository administrators should enforce required checks and
reviews on `main`, review CODEOWNERS coverage, and prevent force pushes and
unreviewed administrative bypasses. A CODEOWNERS file alone does not configure
those protections or require approval from every listed owner.

Send vulnerabilities privately to
[security@nvnmchain.io](mailto:security@nvnmchain.io), following
[SECURITY.md](SECURITY.md), before opening a public exploit report.
