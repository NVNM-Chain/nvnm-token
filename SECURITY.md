# Security policy

## Report a vulnerability

Email [security@nvnmchain.io](mailto:security@nvnmchain.io) privately. Include the
affected file or contract address, chain, impact, reproduction steps and, where
possible, a minimal test. Do not include wallet private keys or credentials.

Please avoid public exploit details while a report is being assessed and a
mitigation is coordinated. If you do not receive a response, follow up through
the same inbox. Response targets are acknowledgement within 48 hours, initial
assessment within five business days, and weekly updates while a report is open.

## Scope

Reports concerning these areas are welcome:

- The token contract, including its constructor and permit signature handling.
- Deployment and verification tooling, including misleading verification results.
- Dependency integrity, build tooling and CI security.
- Tests or documentation that conceal or materially misstate a security risk.

The token treats every caller alike, and its code and parameters are fixed at
deployment, so a defect cannot be patched in place. These properties are
explained in [the trust model](docs/TRUST-MODEL.md). Behavior outside them remains in scope, and known
design choices do not excuse an implementation defect.

Report upstream library vulnerabilities to the relevant maintainer as well if
they affect this project.

## Research expectations

Use local forks, testnets or assets you control. Avoid accessing private data,
disrupting services or exploiting beyond what is necessary to demonstrate the
issue. Report findings promptly and allow time to coordinate disclosure.
There is no active reward guarantee or published bounty program.

## Supported status

When deployments are published, their token addresses and source/build records
will appear in [deployments/](deployments/README.md). Verify a deployment
against a reviewed release record before relying on it.
