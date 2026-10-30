#!/usr/bin/env node
// Finalize a deployment record before the treasury distributes any tokens. Uses
// reviewed expectations, the approved local build, a successful creation receipt
// and a canonical finalized block.
// No private keys, transaction submission, third-party packages or latest-state defaults.
import { readFile, writeFile, mkdir, link, unlink, realpath } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { resolve, join, relative, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';

const MASK = (1n << 64n) - 1n;
const ROT = [0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14];
const RC = [0x1n,0x8082n,0x800000000000808an,0x8000000080008000n,0x808bn,0x80000001n,
  0x8000000080008081n,0x8000000000008009n,0x8an,0x88n,0x80008009n,0x8000000an,
  0x8000808bn,0x800000000000008bn,0x8000000000008089n,0x8000000000008003n,
  0x8000000000008002n,0x8000000000000080n,0x800an,0x800000008000000an,
  0x8000000080008081n,0x8000000000008080n,0x80000001n,0x8000000080008008n];
const rot = (v, n) => n === 0 ? v : ((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK;
function permutation(a) {
  for (const rc of RC) {
    const c = Array.from({length: 5}, (_, x) => a[x]^a[x+5]^a[x+10]^a[x+15]^a[x+20]);
    const d = c.map((_, x) => c[(x+4)%5] ^ rot(c[(x+1)%5], 1));
    const b = new Array(25);
    for (let y=0;y<5;y++) for (let x=0;x<5;x++) b[y+5*((2*x+3*y)%5)] = rot(a[x+5*y]^d[x], ROT[x+5*y]);
    for (let y=0;y<5;y++) for (let x=0;x<5;x++) a[x+5*y] = b[x+5*y] ^ ((~b[(x+1)%5+5*y]) & b[(x+2)%5+5*y]);
    a[0] ^= rc;
  }
}
export function keccak(input) {
  const data = Buffer.isBuffer(input) ? input : Buffer.from(input);
  const padded = Buffer.alloc(Math.ceil((data.length + 1) / 136) * 136);
  data.copy(padded); padded[data.length] = 1; padded[padded.length-1] |= 128;
  const a = Array(25).fill(0n);
  for (let offset=0;offset<padded.length;offset+=136) {
    for (let i=0;i<17;i++) a[i] ^= padded.readBigUInt64LE(offset+i*8);
    permutation(a);
  }
  const result = Buffer.alloc(32);
  for (let i=0;i<4;i++) result.writeBigUInt64LE(a[i], i*8);
  return `0x${result.toString('hex')}`;
}
const ensure = (condition, message) => { if (!condition) throw new Error(message); };
const strip = value => value.replace(/^0x/, '');
const bytes = value => { ensure(typeof value === 'string' && /^0x(?:[\da-f]{2})*$/i.test(value), 'Invalid hex bytecode'); return Buffer.from(strip(value), 'hex'); };
export const word = value => BigInt(value).toString(16).padStart(64, '0');
const address = value => { ensure(typeof value === 'string' && /^0x[\da-f]{40}$/i.test(value) && BigInt(value) !== 0n, 'Invalid or zero address'); return value.toLowerCase(); };
const hash = value => { ensure(typeof value === 'string' && /^0x[\da-f]{64}$/i.test(value), 'Invalid transaction hash'); return value.toLowerCase(); };
const selector = signature => keccak(signature).slice(0,10);
export const SUPPLY = 1_000_000_000n * 10n ** 18n;
const NAME = 'NVNM Token';
const VERSION = '1';
const EIP712_SOURCE = 'lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol';
const EXPECTED_FIELDS = ['chainId','token','deployer','treasury'];
const ARTIFACT_PATHS = {token: 'out/NVNMToken.sol/NVNMToken.json', eip712: 'out/EIP712.sol/EIP712.json'};

export function validateExpected(input) {
  ensure(Object.keys(input).every(field => EXPECTED_FIELDS.includes(field)), 'Unexpected expectation field');
  ensure(Number.isSafeInteger(input.chainId) && input.chainId > 0, 'Expected chainId must be a positive integer');
  const result = {...input};
  for (const field of ['token','deployer','treasury']) result[field] = address(input[field]);
  return result;
}

/** OpenZeppelin ShortString encoding: bytes left-aligned, length in the last byte. */
export function shortString(value) {
  const raw = Buffer.from(value);
  ensure(raw.length < 32, 'String too long for a ShortString');
  return raw.toString('hex').padEnd(62, '0') + raw.length.toString(16).padStart(2, '0');
}

/** The word the approved constructor writes for each EIP712 immutable, by declaration. */
export function immutableValues(expected) {
  return {
    _cachedDomainSeparator: {type: 'bytes32', word: strip(domainSeparator(expected))},
    _cachedChainId: {type: 'uint256', word: word(expected.chainId)},
    _cachedThis: {type: 'address', word: word(expected.token)},
    _hashedName: {type: 'bytes32', word: strip(keccak(NAME))},
    _hashedVersion: {type: 'bytes32', word: strip(keccak(VERSION))},
    _name: {type: 'ShortString', word: shortString(NAME)},
    _version: {type: 'ShortString', word: shortString(VERSION)},
  };
}

/**
 * The approved runtime as it must appear at the expected token address and chain.
 * Every immutable in this release is one of the seven EIP712 declares, identified
 * by its compiler-assigned declaration rather than by position.
 */
export function tokenRuntime(token, eip712, expected) {
  const runtime = bytes(token.deployedBytecode.object);
  ensure(eip712.ast.absolutePath === EIP712_SOURCE, 'Unexpected EIP712 source');
  const values = immutableValues(expected);
  const declarations = new Map(eip712.ast.nodes.flatMap(n => n.nodes ?? [])
    .filter(n => n.nodeType === 'VariableDeclaration' && n.mutability === 'immutable')
    .map(n => [String(n.id), n]));
  ensure(declarations.size === Object.keys(values).length, 'Unexpected EIP712 immutables');
  const entries = Object.entries(token.deployedBytecode.immutableReferences ?? {});
  ensure(entries.length === declarations.size, 'Unexpected immutable declarations');
  const covered = Buffer.alloc(runtime.length);
  for (const [id, refs] of entries) {
    const declaration = declarations.get(id);
    ensure(declaration, 'Immutable outside EIP712');
    const value = values[declaration.name];
    ensure(value && value.type === declaration.typeDescriptions?.typeString, `Unexpected immutable ${declaration.name}`);
    ensure(Array.isArray(refs) && refs.length > 0, 'Missing immutable references');
    for (const ref of refs) {
      ensure(Number.isSafeInteger(ref.start) && ref.start >= 0 && ref.length === 32 && ref.start + 32 <= runtime.length,
        'Invalid immutable reference');
      ensure(covered.subarray(ref.start, ref.start+32).equals(Buffer.alloc(32)), 'Overlapping immutable reference');
      ensure(runtime.subarray(ref.start, ref.start+32).equals(Buffer.alloc(32)), 'Nonzero immutable template');
      covered.fill(1, ref.start, ref.start+32);
      Buffer.from(value.word, 'hex').copy(runtime, ref.start);
    }
  }
  return `0x${runtime.toString('hex')}`;
}

export function expectedCreationInput(build, expected) {
  return `${build.token.bytecode.object}${word(expected.treasury)}`.toLowerCase();
}

export function domainSeparator(expected) {
  return keccak(Buffer.from([
    strip(keccak('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
    strip(keccak(NAME)), strip(keccak(VERSION)), word(expected.chainId), word(expected.token)
  ].join(''), 'hex'));
}

export function makeRpc(url) {
  const parsed = new URL(url);
  ensure(['http:','https:'].includes(parsed.protocol), 'RPC URL must use HTTP(S)');
  let id = 0;
  return async (method, params) => {
    const response = await fetch(url, {method:'POST', headers:{'content-type':'application/json'},
      body:JSON.stringify({jsonrpc:'2.0',id:++id,method,params}), signal:AbortSignal.timeout(30_000)});
    ensure(response.ok, `RPC HTTP ${response.status}`);
    const body = await response.json();
    ensure(!body.error && body.result !== undefined, `RPC ${method} failed`);
    return body.result;
  };
}

export async function checkLiveState(rpc, build, expected, block) {
  const tag = block.number;
  ensure(BigInt(await rpc('eth_chainId', [])) === BigInt(expected.chainId), 'RPC chain does not match expected chain');
  const code = await rpc('eth_getCode', [expected.token, tag]);
  ensure(code.toLowerCase() === tokenRuntime(build.token, build.eip712, expected), 'Token bytecode mismatch');
  const call = async (signature, args='') => rpc('eth_call', [{to:expected.token,data:selector(signature)+args}, tag]);
  const number = async (signature, args='') => BigInt(await call(signature,args));
  for (const [signature, value] of [['decimals()',18n],['totalSupply()',SUPPLY],['INITIAL_SUPPLY()',SUPPLY]]) {
    ensure(await number(signature) === value, `${signature} mismatch`);
  }
  ensure(await number('balanceOf(address)', word(expected.treasury)) === SUPPLY, 'Treasury does not hold initial supply');
  ensure((await call('DOMAIN_SEPARATOR()')).toLowerCase() === domainSeparator(expected), 'Permit domain mismatch');
  // Name and symbol live in storage written by the constructor, so the code
  // match alone does not fix them. The complete EIP-5267 response is also
  // compared, including salt/extensions.
  for (const [signature, value] of [['name()',NAME],['symbol()','NVNM']]) {
    ensure((await call(signature)).toLowerCase() === encodeString(value), `${signature} mismatch`);
  }
  ensure((await call('eip712Domain()')).toLowerCase() === encodeDomain(expected), 'Permit domain fields mismatch');
  return keccak(bytes(code));
}
export function encodeString(value) {
  const raw = Buffer.from(value).toString('hex');
  return `0x${word(32)}${word(raw.length/2)}${raw.padEnd(Math.ceil(raw.length/64)*64,'0')}`;
}
export function encodeDomain(expected) {
  const name = strip(encodeString(NAME)).slice(64);
  const version = strip(encodeString(VERSION)).slice(64);
  return `0x${'0f'.padEnd(64,'0')}${word(224)}${word(224+name.length/2)}${word(expected.chainId)}${word(expected.token)}${word(0)}${word(224+(name.length+version.length)/2)}${name}${version}${word(0)}`;
}

export async function confirmDeployment({rpc, build, expected: input, tokenTx, provenance}) {
  const expected = validateExpected(input);
  const txHash = hash(tokenTx);
  const finalized = await rpc('eth_getBlockByNumber', ['finalized',false]);
  ensure(finalized?.number && finalized?.hash, 'RPC must support finalized blocks');
  const receipt = await rpc('eth_getTransactionReceipt', [txHash]);
  ensure(receipt && BigInt(receipt.status ?? 0) === 1n, 'Creation receipt missing or failed');
  ensure(receipt.transactionHash?.toLowerCase() === txHash && receipt.to === null, 'Not the expected creation receipt');
  ensure(address(receipt.contractAddress) === expected.token && address(receipt.from) === expected.deployer, 'Creation address or signer mismatch');
  ensure(BigInt(receipt.blockNumber) <= BigInt(finalized.number), 'Creation receipt is not finalized');
  const canonical = await rpc('eth_getBlockByNumber', [receipt.blockNumber,false]);
  ensure(canonical?.hash?.toLowerCase() === receipt.blockHash?.toLowerCase(), 'Creation receipt is not canonical');
  const tx = await rpc('eth_getTransactionByHash', [txHash]);
  ensure(tx && tx.to === null && address(tx.from) === expected.deployer && tx.hash?.toLowerCase() === txHash
    && tx.blockHash?.toLowerCase() === receipt.blockHash?.toLowerCase(), 'Creation transaction mismatch');
  // The creation input fixes the constructor that ran, which code and state
  // checks cannot: it is the approved creation code with the treasury argument.
  ensure((tx.input ?? tx.data)?.toLowerCase() === expectedCreationInput(build, expected), 'Creation input mismatch');
  const codeHash = await checkLiveState(rpc, build, expected, finalized);
  const recheck = await rpc('eth_getBlockByNumber', [finalized.number,false]);
  ensure(recheck?.hash?.toLowerCase() === finalized.hash.toLowerCase(), 'Observation block changed while verifying');
  return {
    schemaVersion:1,status:'confirmed',chainId:expected.chainId,token:expected.token,
    deployer:expected.deployer,treasury:expected.treasury,initialSupply:SUPPLY.toString(),
    observation:{blockNumber:BigInt(finalized.number).toString(),blockHash:finalized.hash,finality:'finalized'},
    transaction:{hash:txHash,blockNumber:BigInt(receipt.blockNumber).toString(),blockHash:receipt.blockHash},
    codeHash,provenance
  };
}

export function sourceProvenance(root) {
  const git = (...args) => execFileSync('git',args,{cwd:root,encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
  const generated = /^\?\? deployments\/(?:\d+-0x[\da-f]{40}\.json|simulations\/\d+-[a-z]+\.json)$/;
  const status = git('status','--porcelain','--untracked-files=all','--ignore-submodules=none');
  ensure(status.split('\n').filter(Boolean).every(line => generated.test(line)), 'Checkout must be clean, including submodules and untracked source');
  const submodules = git('submodule','status','--recursive');
  ensure(!submodules.split('\n').some(line => /^[+\-U]/.test(line)), 'Submodule revisions must match the source commit');
  return {sourceCommit:git('rev-parse','HEAD'),sourceTree:git('rev-parse','HEAD^{tree}'),submodules:submodules.split('\n').filter(Boolean)};
}

/** Reject sources that do not belong to the recorded checkout or pinned submodules. */
export async function assertTrackedSource(root, source, approvedSubmodules = []) {
  const checkout = await realpath(root);
  const candidate = resolve(checkout, source);
  ensure(!relative(checkout, candidate).startsWith('..') && !source.startsWith('/'), 'Invalid source path');
  const actual = await realpath(candidate);
  ensure(!relative(checkout, actual).startsWith('..'), 'Source resolves outside checkout');
  const git = (cwd, ...args) => execFileSync('git', args, {cwd, encoding:'utf8', stdio:['ignore','pipe','pipe']}).trim();
  const owner = await realpath(git(dirname(actual), 'rev-parse', '--show-toplevel'));
  const ownerPath = relative(checkout, owner);
  ensure(ownerPath === '' || approvedSubmodules.includes(ownerPath), 'Source belongs to an unrecorded nested repository');
  try { git(owner, 'ls-files', '--error-unmatch', '--', relative(owner, actual)); }
  catch { throw new Error(`Build source is not tracked in its source commit: ${source}`); }
  return actual;
}

/** Regenerate ignored artifacts; metadata alone cannot attest to preexisting bytecode. */
export function rebuildApprovedRelease(root, execute = execFileSync) {
  // Out/cache/compiler/config overrides could rebuild elsewhere and leave stale
  // out/ artifacts in place. Only the reviewed default-profile config applies.
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !/^(FOUNDRY_|DAPP_)/.test(name)));
  env.FOUNDRY_PROFILE = 'default';
  env.FOUNDRY_CONFIG = join(root, 'foundry.toml');
  env.FOUNDRY_OUT = join(root, 'out');
  env.FOUNDRY_CACHE_PATH = join(root, 'cache');
  // Forge loads ignored .env files itself. RPC-only dotenv files are fine, but
  // build/config overrides must not be reintroduced after environment cleanup.
  let dotenv = '';
  try { dotenv = readFileSync(join(root, '.env'), 'utf8'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  ensure(!/^\s*(?:export\s+)?["']?(?:FOUNDRY_|DAPP_)[\w]+["']?\s*=/m.test(dotenv),
    '.env must not contain Foundry/Dapp build overrides');
  execute('forge', ['clean'], {cwd:root, env, stdio:'inherit'});
  execute('forge', ['build', '--offline', '--force'], {cwd:root, env, stdio:'inherit'});
}

export async function loadApprovedBuild(root, approvedSubmodules = []) {
  const build = {}, artifacts = {}, sources = {};
  for (const [key,path] of Object.entries(ARTIFACT_PATHS)) {
    const raw = await readFile(join(root,path));
    build[key] = JSON.parse(raw);
    artifacts[path] = createHash('sha256').update(raw).digest('hex');
    const metadata = build[key].metadata ?? JSON.parse(build[key].rawMetadata);
    for (const [source, details] of Object.entries(metadata.sources)) {
      const tracked = await assertTrackedSource(root, source, approvedSubmodules);
      const actual = keccak(await readFile(tracked));
      ensure(actual === details.keccak256, `Build source differs from checkout: ${source}`);
      sources[source] = actual;
    }
    bytes(build[key].bytecode.object);
    bytes(build[key].deployedBytecode.object);
  }
  const metadata = build.token.metadata ?? JSON.parse(build.token.rawMetadata);
  return {build,provenance:{compiler:metadata.compiler,settings:metadata.settings,artifacts,sources}};
}

/** Atomic publication without replacement; an interrupted write cannot publish a partial JSON record. */
export async function writeConfirmedManifest(directory, manifest) {
  ensure(manifest.status === 'confirmed' && manifest.observation?.finality === 'finalized', 'Only confirmed finalized records can be published');
  const name = `${manifest.chainId}-${address(manifest.token)}.json`;
  await mkdir(directory,{recursive:true});
  const temp = join(directory,`.manifest-${randomUUID()}.tmp`);
  const destination = join(directory,name);
  try {
    await writeFile(temp,`${JSON.stringify(manifest,null,2)}\n`,{flag:'wx'});
    await link(temp,destination); // link, unlike rename, never replaces an existing manifest
  } finally { await unlink(temp).catch(() => {}); }
  return destination;
}

async function main(args) {
  ensure(args.shift() === 'finalize', 'Usage: node script/deployment-manifest.mjs finalize --rpc-url URL --expected FILE --token-tx HASH');
  const options = {};
  while (args.length) {
    const key = args.shift(), value = args.shift();
    ensure(['--rpc-url','--expected','--token-tx'].includes(key) && value && !options[key], 'Invalid or duplicate option');
    options[key] = value;
  }
  for (const key of ['--rpc-url','--expected','--token-tx']) ensure(options[key], `Missing ${key}`);
  const root = process.cwd();
  const source = sourceProvenance(root);
  rebuildApprovedRelease(root);
  const submodulePaths = source.submodules.map(entry => {
    const match = entry.match(/^[ \t]*[0-9a-f]{40} (.*?)(?: \(.*\))?$/);
    ensure(match, 'Cannot identify pinned submodule path');
    return match[1];
  });
  const {build,provenance} = await loadApprovedBuild(root, submodulePaths);
  const expected = JSON.parse(await readFile(options['--expected'],'utf8'));
  const manifest = await confirmDeployment({rpc:makeRpc(options['--rpc-url']),build,expected,
    tokenTx:options['--token-tx'],provenance:{...source,...provenance}});
  // Recheck the source after RPC work to catch edits while finalization was running.
  ensure(JSON.stringify(sourceProvenance(root)) === JSON.stringify(source), 'Source checkout changed during verification');
  console.log(await writeConfirmedManifest(join(root,'deployments'),manifest));
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => { console.error(`Finalization refused: ${error.message}`); process.exitCode = 1; });
}
