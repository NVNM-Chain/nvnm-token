import test from 'node:test'
import assert from 'node:assert/strict'
import {PAIR_KEYS, SINGLE_KEYS, parseGasOutput, parseForgeVersion} from '../../script/gas-data.mjs'
const rows = [...PAIR_KEYS.map(key => `GASROW|${key}|100|200`), ...SINGLE_KEYS.map(key => `GASONE|${key}|100`)]
test('complete gas output is accepted', () => {
  const result = parseGasOutput(rows.join('\n'))
  assert.equal(result.pairs.size, PAIR_KEYS.length)
  assert.equal(result.singles.size, SINGLE_KEYS.length)
})
test('missing, duplicate, unknown and malformed gas output fails closed', () => {
  for (const lines of [rows.slice(1), [...rows, rows[0]], [...rows, 'GASONE|unknown|100'],
    rows.map(row => row.replace('|100', '|NaN')), rows.map(row => row.replace('|100', '|0')),
    rows.map(row => row.replace('|100', '|9007199254740992'))]) {
    assert.throws(() => parseGasOutput(lines.join('\n')))
  }
})

const SHA = '1c57854462289b2e71ee7654cd6666217ed86ffd'
const versionOutput = first => `${first}\nCommit SHA: ${SHA}\nBuild Timestamp: 2025-11-24T06:05:14.9Z (1763964314)\nBuild Profile: maxperf\n`
test('forge version is recorded independently of the install channel', () => {
  // One release, two packagings: a channel build and a version-tag build.
  for (const first of ['forge Version: 1.5.0-stable', 'forge Version: 1.5.0-v1.5.0']) {
    assert.deepEqual(parseForgeVersion(versionOutput(first)), {semver: '1.5.0', commit: SHA})
  }
  // Newer releases print no suffix at all.
  assert.deepEqual(parseForgeVersion(versionOutput('forge Version: 1.8.3')), {semver: '1.8.3', commit: SHA})
})
test('unparseable forge version output fails closed', () => {
  for (const bad of ['', 'garbage\n', 'forge Version: 1.5.0-stable\n', `Commit SHA: ${SHA}\n`,
    versionOutput('forge Version: 1.5')]) {
    assert.throws(() => parseForgeVersion(bad))
  }
})
