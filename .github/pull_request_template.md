## What changes and why

<!-- Describe the problem, resulting behavior and relevant issue or decision. -->

## Validation

<!-- List commands run and their results. Explain anything not exercised. -->

- [ ] Relevant regression tests and documentation are updated
- [ ] `make check` passes
- [ ] `make release-check` passes for a release or security-sensitive change
- [ ] `make gas` was run and the generated report reviewed if benchmarks changed

## Security and contract impact

<!-- State whether source, ABI, dependencies, compiler settings,
     deployment tooling or on-chain behavior change. -->

For changes affecting the contract:

- [ ] New powers and changed assumptions are reflected in `docs/TRUST-MODEL.md`
- [ ] ABI changes were reviewed; expected changes are explicit
- [ ] Audit applicability and deployment verification requirements were reassessed

## Reviewer notes

<!-- Call out risks, follow-up work, evidence limits or decisions needing review. -->
