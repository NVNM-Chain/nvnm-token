#!/usr/bin/env node
/**
 * NVNM gas report generator.
 *
 * Runs the benchmark suite, parses its structured output and regenerates
 * docs/GAS.md.
 *
 * Usage:
 *   node script/gas-report.mjs             regenerate docs/GAS.md
 *   node script/gas-report.mjs --check     verify committed output is current
 *   node script/gas-report.mjs --help
 *
 * --check is what CI runs: it regenerates in memory and diffs against what is
 * committed, so a change in gas cost cannot land unnoticed.
 *
 * No dependencies. Node 18+.
 */

import {execFileSync} from 'node:child_process'
import {readFileSync, writeFileSync, existsSync, mkdirSync} from 'node:fs'
import {dirname, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
import {parseGasOutput, parseForgeVersion} from './gas-data.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const GAS_MD = resolve(ROOT, 'docs/GAS.md')
const LOCK = resolve(ROOT, 'foundry.lock')

const args = process.argv.slice(2)
if (args.includes('--help') || args.includes('-h')) {
  console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('*/')[0].replace(/^\/\*\*|^ \* ?/gm, ''))
  process.exit(0)
}
const CHECK = args.includes('--check')
if (args.some(arg => arg !== '--check')) throw new Error('Supported option: --check')

/* ------------------------------------------------------------------ helpers */

function run(cmd, cmdArgs, env = {}) {
  try {
    return execFileSync(cmd, cmdArgs, {
      cwd: ROOT,
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      env: {...process.env, ...env},
    })
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.error(`error: '${cmd}' not found on PATH. Install Foundry: https://getfoundry.sh`)
      process.exit(1)
    }
    // forge exits non-zero on test failure; surface its output rather than a stack trace.
    console.error(err.stdout || '')
    console.error(err.stderr || '')
    console.error(`error: '${cmd} ${cmdArgs.join(' ')}' failed with exit code ${err.status}`)
    process.exit(1)
  }
}

const num = n => Number(n).toLocaleString('en-US')

// NVNM can cost the same as, or less than, the baseline in a row, so the sign
// is computed rather than assumed.
function delta(nvnm, baseline) {
  const d = nvnm - baseline
  const sign = d > 0 ? '+' : d < 0 ? '-' : ''
  return `${sign}${num(Math.abs(d))} (${sign}${Math.abs((d / baseline) * 100).toFixed(1)}%)`
}

/* --------------------------------------------------------------- collection */

// Isolated build dir so this never races a concurrent forge invocation.
const ISOLATED = {
  FOUNDRY_PROFILE: 'default',
  FOUNDRY_OUT: resolve(ROOT, 'cache/gasreport/out'),
  FOUNDRY_CACHE_PATH: resolve(ROOT, 'cache/gasreport/cache'),
}

console.error('running gas benchmarks...')
const output = run('forge', ['test', '--match-path', 'test/gas/*', '-vv'], ISOLATED)

const {pairs, singles} = parseGasOutput(output)

console.error('collecting toolchain versions...')
const forge = parseForgeVersion(run('forge', ['--version']))
const solc = run('forge', ['config', '--json'], ISOLATED)
const cfg = JSON.parse(solc)

// No literal fallback: a silently wrong compiler version in generated evidence is
// worse than a loud failure.
if (!cfg.solc && !cfg.solc_version) throw new Error("'forge config --json' reported no solc version")

const meta = {
  solc: cfg.solc || cfg.solc_version,
  evm: cfg.evm_version,
  runs: cfg.optimizer_runs,
  viaIr: cfg.via_ir,
  forge: forge.semver,
  forgeCommit: forge.commit,
  // Read from foundry.lock, never hardcoded: a submodule bump must not leave this
  // report claiming a version it was not built against.
  oz: JSON.parse(readFileSync(LOCK, 'utf8'))['lib/openzeppelin-contracts'].tag.name,
}

const LABELS = {
  transfer_toExistingHolder: 'transfer — recipient already holds a balance (the common case)',
  transfer_toFreshAccount: 'transfer — recipient’s first ever tokens (0 → non-zero slot)',
  transfer_entireBalance: 'transfer — entire balance, zeroing the sender’s slot',
  transfer_zeroAmount: 'transfer — zero amount (entrypoint floor)',
  approve_zeroToNonZero: 'approve — first approval (0 → non-zero)',
  approve_overwrite: 'approve — overwrite an existing allowance',
  approve_revoke: 'approve — revoke (non-zero → 0)',
  transferFrom_finiteAllowance: 'transferFrom — finite allowance (decremented)',
  transferFrom_infiniteAllowance: 'transferFrom — infinite allowance (not decremented)',
}
const ORDER = Object.keys(LABELS)

/* ----------------------------------------------------------------- rendering */

function summaryBlock() {
  const l = []
  l.push('| Operation | `NVNMToken` | Plain OpenZeppelin ERC-20 | Difference |')
  l.push('|---|---:|---:|---:|')
  for (const key of ORDER) {
    const p = pairs.get(key)
    l.push(`| ${LABELS[key]} | ${num(p.nvnm)} | ${num(p.baseline)} | ${delta(p.nvnm, p.baseline)} |`)
  }
  l.push('')
  l.push('| Deployment | Gas | Runtime size |')
  l.push('|---|---:|---:|')
  l.push(`| \`NVNMToken\` | ${num(singles.get('deploy_NVNM'))} | ${num(singles.get('size_NVNM_runtime'))} B |`)
  l.push(`| Plain OpenZeppelin ERC-20 (benchmark only) | ${num(singles.get('deploy_Baseline'))} | ${num(singles.get('size_Baseline_runtime'))} B |`)
  l.push('')
  l.push(
    `These are call-frame execution measurements, excluding intrinsic transaction gas, calldata, the caller's cost of making the call, and transaction-end refunds. Transfer scenarios warm the relevant balance slots first. They do not establish total wallet-transaction gas or a fixed percentage overhead.`,
  )
  return l.join('\n')
}

function gasDoc() {
  const eip170 = 24576
  const l = []
  l.push('# Gas report')
  l.push('')
  l.push('> Generated by `node script/gas-report.mjs`. Do not edit by hand —')
  l.push('> CI runs `--check` and fails if this file drifts from the code.')
  l.push('')
  l.push('## Build')
  l.push('')
  l.push('| Setting | Value |')
  l.push('|---|---|')
  l.push(`| Solidity | \`${meta.solc}\` |`)
  l.push(`| EVM version | \`${meta.evm}\` |`)
  l.push(`| Optimizer runs | \`${num(meta.runs)}\` |`)
  l.push(`| \`via_ir\` | \`${meta.viaIr}\` |`)
  l.push(`| Foundry | \`${meta.forge}\` |`)
  l.push(`| Foundry commit | \`${meta.forgeCommit}\` |`)
  l.push(`| OpenZeppelin Contracts | \`${meta.oz}\` |`)
  l.push('')
  l.push('## Methodology')
  l.push('')
  l.push('Read this before quoting any number.')
  l.push('')
  l.push('Call measurements come from `vm.snapshotGasLastCall`, which records the gas consumed')
  l.push('inside the measured call frame, independent of the test code around it. Deployment')
  l.push('measurements are `vm.startSnapshotGas` / `vm.stopSnapshotGas` windows around contract')
  l.push('creation, each the only window in its test: a later window in the same test would also')
  l.push('count the test’s own gas since the previous window closed.')
  l.push('')
  l.push('**Included:** execution and storage costs of the call.')
  l.push('')
  l.push('**Excluded:** the 21,000 gas intrinsic transaction cost; calldata cost (16 gas per')
  l.push('non-zero byte, 4 per zero byte — roughly 400–600 gas for a `transfer`); the caller’s')
  l.push('cost of making the call, including its access to the token account; and refunds,')
  l.push('which settle at the end of a real transaction and are capped at a fifth of gas used.')
  l.push('')
  l.push('**Transfer warm-up.** Transfer scenarios perform a zero-value transfer between the')
  l.push('same parties before measuring. This touches both balance slots without changing')
  l.push('balances.')
  l.push('Approval and transferFrom cases have their own allowance access/transition setup;')
  l.push('they should not be treated as uniformly warm storage benchmarks.')
  l.push('')
  l.push('Adding 21,000 and calldata to these rows does not reproduce a wallet transaction.')
  l.push('Use receipt-based benchmarks before publishing standalone wallet-transaction costs.')
  l.push('')
  l.push('**Gas schedule.** Every figure is measured under the gas rules of the EVM version')
  l.push('above. A network that has activated a later fork charges what its own rules say, and')
  l.push('the difference can be large: after the fork Sepolia activated on 6 October 2026,')
  l.push('deploying the token there takes about seven times the gas these rules give. Call')
  l.push('costs can change as well. Take gas limits for real transactions from the target')
  l.push('network’s node (`eth_estimateGas`), as the Makefile’s deploy targets do.')
  l.push('')
  l.push('## Results')
  l.push('')
  l.push(summaryBlock())
  l.push('')
  l.push('## First vs repeat transfer in one transaction')
  l.push('')
  l.push('This delta is **not** a pure EIP-2929 cold-access figure, and should not be quoted as')
  l.push('one. It combines cold storage-slot access')
  l.push('with EIP-2200 dirty-slot pricing: the repeat transfer rewrites slots already modified')
  l.push('in the same transaction, at 100 gas each instead of 2,900. The common transfer row')
  l.push('uses its own zero-transfer warm-up; approval and allowance rows have different setups.')
  l.push('')
  l.push('| Measurement | Gas |')
  l.push('|---|---:|')
  l.push(`| First \`transfer\` in the transaction | ${num(singles.get('transfer_first'))} |`)
  l.push(`| Identical repeat \`transfer\` | ${num(singles.get('transfer_repeat'))} |`)
  l.push(`| Delta | ${num(singles.get('first_vs_repeat_delta'))} |`)
  l.push('')
  l.push('## View functions')
  l.push('')
  l.push('| Call | Gas |')
  l.push('|---|---:|')
  l.push(`| \`balanceOf\` | ${num(singles.get('view_balanceOf'))} |`)
  l.push(`| \`allowance\` | ${num(singles.get('view_allowance'))} |`)
  l.push(`| \`totalSupply\` | ${num(singles.get('view_totalSupply'))} |`)
  l.push('')
  l.push('## NVNM-only operations')
  l.push('')
  l.push('These have no equivalent in a plain ERC-20, so there is nothing to compare them to.')
  l.push('')
  l.push('| Call | Gas |')
  l.push('|---|---:|')
  l.push(`| \`permit\` — owner’s first permit (nonce and allowance 0 → non-zero) | ${num(singles.get('permit'))} |`)
  l.push('')
  l.push('## Contract size against the EIP-170 limit')
  l.push('')
  l.push('| Contract | Runtime size | Limit | Headroom |')
  l.push('|---|---:|---:|---:|')
  for (const [name, key] of [
    ['`NVNMToken`', 'size_NVNM_runtime'],
    ['Plain OpenZeppelin ERC-20 (benchmark only)', 'size_Baseline_runtime'],
  ]) {
    const size = singles.get(key)
    l.push(`| ${name} | ${num(size)} B | ${num(eip170)} B | ${num(eip170 - size)} B |`)
  }
  l.push('')
  l.push('## Reproducing')
  l.push('')
  l.push('```bash')
  l.push('node script/gas-report.mjs           # regenerate this file')
  l.push('node script/gas-report.mjs --check   # verify it is current (CI)')
  l.push('```')
  l.push('')
  return l.join('\n')
}

/* ------------------------------------------------------------------ outputs */

const doc = gasDoc()

if (CHECK) {
  let failed = false
  const committed = existsSync(GAS_MD) ? readFileSync(GAS_MD, 'utf8') : ''
  if (committed !== doc) {
    failed = true
    console.error('FAIL: docs/GAS.md is out of date.')
    const a = committed.split('\n')
    const b = doc.split('\n')
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
      if (a[i] !== b[i]) {
        console.error(`  line ${i + 1}:`)
        console.error(`    committed: ${a[i] ?? '(missing)'}`)
        console.error(`    expected : ${b[i] ?? '(missing)'}`)
      }
    }
  }
  if (failed) {
    console.error('\nRun: node script/gas-report.mjs')
    process.exit(1)
  }
  console.error('OK: gas report is up to date.')
  process.exit(0)
}

mkdirSync(dirname(GAS_MD), {recursive: true})
writeFileSync(GAS_MD, doc)
console.error(`docs/GAS.md written (${doc.split('\n').length} lines).`)
