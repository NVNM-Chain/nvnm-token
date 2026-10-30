// Parse a complete benchmark result; missing/duplicated rows must never become a
// plausible generated report after someone regenerates a damaged measurement.
export const PAIR_KEYS = [
  'transfer_toExistingHolder', 'transfer_toFreshAccount', 'transfer_entireBalance',
  'transfer_zeroAmount', 'approve_zeroToNonZero', 'approve_overwrite',
  'approve_revoke', 'transferFrom_finiteAllowance', 'transferFrom_infiniteAllowance',
]
export const SINGLE_KEYS = [
  'deploy_Baseline', 'deploy_NVNM', 'size_Baseline_runtime', 'size_NVNM_runtime',
  'transfer_first', 'transfer_repeat', 'first_vs_repeat_delta',
  'view_balanceOf', 'view_totalSupply', 'view_allowance', 'permit',
]
export function parseGasOutput(output) {
  const pairs = new Map(), singles = new Map()
  const integer = value => {
    const number = Number(value)
    if (!/^\d+$/.test(value) || !Number.isSafeInteger(number) || number <= 0) throw new Error('Invalid gas measurement')
    return number
  }
  for (const line of output.split('\n')) {
    const marker = line.match(/GAS(ROW|ONE)\|(.+)$/)
    if (!marker) continue
    const fields = marker[2].trim().split('|')
    const key = fields[0]
    if (marker[1] === 'ROW') {
      if (fields.length !== 3 || !PAIR_KEYS.includes(key) || pairs.has(key)) throw new Error(`Unexpected/duplicate gas row: ${key}`)
      pairs.set(key, {baseline: integer(fields[1]), nvnm: integer(fields[2])})
    } else {
      if (fields.length !== 2 || !SINGLE_KEYS.includes(key) || singles.has(key)) throw new Error(`Unexpected/duplicate gas measurement: ${key}`)
      singles.set(key, integer(fields[1]))
    }
  }
  if (pairs.size !== PAIR_KEYS.length || singles.size !== SINGLE_KEYS.length) throw new Error('Incomplete gas benchmark output')
  return {pairs, singles}
}

// `forge --version` prints `<bin> Version: <semver>[-<channel>]` then `Commit SHA:`.
// The channel suffix records how the binary was PACKAGED, not what it does: Foundry
// publishes one release both as a channel build (`1.5.0-stable`) and as a version-
// tagged build (`1.5.0-v1.5.0`) from the identical commit, and newer releases carry
// no suffix at all. Record the semver core plus the commit SHA: both are invariant
// across packagings, and both move when the toolchain actually moves. Never record
// the build timestamp — it differs between builds of the same release.
export function parseForgeVersion(output) {
  const semver = output.match(/^\S+ Version:\s*(\d+\.\d+\.\d+)(?:[-+]\S*)?\s*$/m)
  const commit = output.match(/^Commit SHA:\s*([0-9a-f]{40})\s*$/m)
  if (!semver || !commit) throw new Error(`Unrecognised 'forge --version' output:\n${output}`)
  return {semver: semver[1], commit: commit[1]}
}
