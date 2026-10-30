import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, readdir, mkdir, symlink, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  keccak, word, tokenRuntime, immutableValues, shortString, expectedCreationInput, domainSeparator,
  encodeString, encodeDomain, confirmDeployment, writeConfirmedManifest,
  validateExpected, sourceProvenance, assertTrackedSource, rebuildApprovedRelease, SUPPLY
} from '../../script/deployment-manifest.mjs';

const addr = n => `0x${n.toString(16).padStart(40,'0')}`;
const txHash = n => `0x${n.toString(16).padStart(64,'0')}`;
const selector = s => keccak(s).slice(0,10);
const uint = n => `0x${word(n)}`;
const IMMUTABLES = [['_cachedDomainSeparator','bytes32'],['_cachedChainId','uint256'],['_cachedThis','address'],
  ['_hashedName','bytes32'],['_hashedVersion','bytes32'],['_name','ShortString'],['_version','ShortString']];
const fixture = () => {
  const expected = {chainId:31337,token:addr(1),deployer:addr(3),treasury:addr(4)};
  const declarations = IMMUTABLES.map(([name,typeString],i) =>
    ({id:10+i,nodeType:'VariableDeclaration',name,mutability:'immutable',typeDescriptions:{typeString}}));
  const build = {
    // One 32-byte placeholder per immutable, between a leading and a trailing opcode.
    token:{bytecode:{object:'0x6000'},deployedBytecode:{object:`0x60${'00'.repeat(32*IMMUTABLES.length)}61`,
      immutableReferences:Object.fromEntries(declarations.map((d,i) => [String(d.id),[{start:1+32*i,length:32}]]))}},
    eip712:{ast:{absolutePath:'lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol',nodes:[{nodes:[
      {id:9,nodeType:'VariableDeclaration',name:'TYPE_HASH',mutability:'constant',typeDescriptions:{typeString:'bytes32'}},
      ...declarations,
      {id:20,nodeType:'VariableDeclaration',name:'_nameFallback',mutability:'mutable',typeDescriptions:{typeString:'string'}}
    ]}]}}
  };
  const state = {
    receipt:{status:'0x1',transactionHash:txHash(1),to:null,contractAddress:expected.token,from:expected.deployer,
      blockNumber:'0x1',blockHash:txHash(101)},
    tx:{hash:txHash(1),to:null,from:expected.deployer,input:expectedCreationInput(build,expected),nonce:'0x0',blockHash:txHash(101)},
    chainId:'0x7a69',finalized:{number:'0x64',hash:txHash(100)},
    code:tokenRuntime(build.token,build.eip712,expected),domain:domainSeparator(expected),domainFields:encodeDomain(expected),
    calls:{[selector('name()')]:encodeString('NVNM Token'),[selector('symbol()')]:encodeString('NVNM'),
      [selector('decimals()')]:uint(18),[selector('totalSupply()')]:uint(SUPPLY),[selector('INITIAL_SUPPLY()')]:uint(SUPPLY),
      [selector('balanceOf(address)')+word(expected.treasury)]:uint(SUPPLY)}};
  const rpc = async (method,params) => {
    switch (method) {
      case 'eth_chainId': return state.chainId;
      case 'eth_getBlockByNumber':
        if (params[0] === 'finalized' || params[0] === '0x64') return state.finalized;
        return {number:params[0],hash:state.noncanonical ? txHash(999) : txHash(100+Number(BigInt(params[0])))};
      case 'eth_getTransactionReceipt': return params[0] === txHash(1) ? state.receipt : undefined;
      case 'eth_getTransactionByHash': return params[0] === txHash(1) ? state.tx : undefined;
      case 'eth_getCode': assert.deepEqual(params,[expected.token,'0x64']); return state.code;
      case 'eth_call': {
        assert.equal(params[0].to,expected.token);
        assert.equal(params[1],'0x64');
        const data = params[0].data, sig = data.slice(0,10);
        if (sig === selector('DOMAIN_SEPARATOR()')) return state.domain;
        if (sig === selector('eip712Domain()')) return state.domainFields;
        assert.ok(state.calls[data],`unexpected call ${data}`); return state.calls[data];
      }
      default: throw new Error(`unexpected RPC ${method}`);
    }
  };
  const options = {rpc,build,expected,tokenTx:txHash(1),provenance:{sourceCommit:'reviewed-release'}};
  return {state,options,expected,build};
};

test('Ethereum Keccak known vectors (not NIST SHA3)', () => {
  assert.equal(keccak(''),'0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
  assert.equal(keccak('abc'),'0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45');
  assert.equal(selector('transfer(address,uint256)'),'0xa9059cbb');
});

test('EIP-712 immutables match independently computed encodings', () => {
  // Domain separator computed with `cast keccak` over `cast abi-encode` for chain 1, token 0x…01.
  assert.equal(domainSeparator({chainId:1,token:addr(1)}),'0x05b2370f70f9035ffa93422adba19613443e24813fbeff96c3a3f23ed791a0b3');
  assert.equal(shortString('NVNM Token'),`4e564e4d20546f6b656e${'00'.repeat(21)}0a`);
  assert.equal(shortString('1'),`31${'00'.repeat(30)}01`);
  assert.throws(() => shortString('x'.repeat(32)),/too long/);
  const values = immutableValues({chainId:1,token:addr(1)});
  assert.equal(values._cachedChainId.word,word(1));
  assert.equal(values._cachedThis.word,word(addr(1)));
  assert.equal(values._hashedName.word,'77ff92d9effe98f18157f54ebf7413c56fdd91074825948d92d470adae1b89d8');
  assert.equal(values._hashedVersion.word,'c89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6');
});

test('every immutable in the approved build resolves', async () => {
  // Reads the build that `make check` compiles before these tests run.
  const load = async path => JSON.parse(await readFile(path,'utf8'));
  const token = await load('out/NVNMToken.sol/NVNMToken.json');
  const eip712 = await load('out/EIP712.sol/EIP712.json');
  const template = token.deployedBytecode.object.toLowerCase();
  const runtime = tokenRuntime(token,eip712,{chainId:1,token:addr(1)});
  assert.equal(runtime.length,template.length);
  assert.notEqual(runtime,template);
});

test('confirmed manifest contains actual finalized observations and receipt evidence', async () => {
  const {options,expected} = fixture();
  const result = await confirmDeployment(options);
  assert.equal(result.schemaVersion,1);
  assert.equal(result.status,'confirmed');
  assert.equal(result.token,expected.token);
  assert.equal(result.treasury,expected.treasury);
  assert.equal(result.observation.blockNumber,'100');
  assert.equal(result.transaction.hash,txHash(1));
  assert.equal(result.transaction.blockNumber,'1');
  assert.equal(result.provenance.sourceCommit,'reviewed-release');
});

const negatives = [
  ['failed receipt', s => {s.receipt.status='0x0';}, /receipt missing or failed/],
  ['missing receipt', s => {s.receipt=undefined;}, /receipt missing or failed/],
  ['call receipt', s => {s.receipt.to=addr(9);}, /expected creation receipt/],
  ['unfinalized receipt', s => {s.receipt.blockNumber='0x65';}, /not finalized/],
  ['noncanonical receipt', s => {s.noncanonical=true;}, /not canonical/],
  ['wrong signer', s => {s.receipt.from=addr(99);}, /signer mismatch/],
  ['wrong created address', s => {s.receipt.contractAddress=addr(98);}, /Creation address or signer mismatch/],
  ['wrong creation input', s => {s.tx.input='0x1234';}, /Creation input mismatch/],
  ['wrong constructor argument', s => {s.tx.input=s.tx.input.slice(0,-40)+'9'.repeat(40);}, /Creation input mismatch/],
  ['wrong chain', s => {s.chainId='0x1';}, /expected chain/],
  ['unapproved bytecode', s => {s.code+='00';}, /Token bytecode/],
  ['approved code built for another address', s => {const {build,expected}=fixture();
    s.code=tokenRuntime(build.token,build.eip712,{...expected,token:addr(2)});}, /Token bytecode/],
  ['approved code built for another chain', s => {const {build,expected}=fixture();
    s.code=tokenRuntime(build.token,build.eip712,{...expected,chainId:1});}, /Token bytecode/],
  ['wrong domain', s => {s.domain=txHash(1);}, /Permit domain mismatch/],
  ['wrong domain fields', s => {s.domainFields='0x';}, /Permit domain fields/],
  ['wrong name', s => {s.calls[selector('name()')]=encodeString('Fake');}, /name\(\) mismatch/],
  ['wrong supply', s => {s.calls[selector('totalSupply()')]=uint(1);}, /totalSupply/],
  ['distribution before finalization', s => {s.calls[selector('balanceOf(address)')+word(addr(4))]=uint(0);}, /Treasury/]
];
for (const [name,alter,message] of negatives) test(`refuses ${name}`, async () => {
  const {state,options}=fixture(); alter(state); await assert.rejects(confirmDeployment(options),message);
});

test('rejects unknown, missing or misplaced immutables, and nonzero templates', () => {
  const resolve = build => tokenRuntime(build.token,build.eip712,fixture().expected);
  let {build}=fixture();
  build.eip712.ast.nodes[0].nodes[1].name='_anotherImmutable';
  assert.throws(() => resolve(build), /Unexpected immutable _anotherImmutable/);
  ({build}=fixture());
  build.eip712.ast.nodes[0].nodes[2].typeDescriptions.typeString='bytes32';
  assert.throws(() => resolve(build), /Unexpected immutable _cachedChainId/);
  ({build}=fixture());
  build.eip712.ast.absolutePath='src/EIP712.sol';
  assert.throws(() => resolve(build), /Unexpected EIP712 source/);
  ({build}=fixture());
  build.eip712.ast.nodes[0].nodes.splice(1,1);
  assert.throws(() => resolve(build), /Unexpected EIP712 immutables/);
  ({build}=fixture());
  build.token.deployedBytecode.immutableReferences['99']=[{start:0,length:32}];
  assert.throws(() => resolve(build), /Unexpected immutable declarations/);
  ({build}=fixture());
  build.token.deployedBytecode.immutableReferences['99']=build.token.deployedBytecode.immutableReferences['10'];
  delete build.token.deployedBytecode.immutableReferences['10'];
  assert.throws(() => resolve(build), /outside EIP712/);
  ({build}=fixture());
  build.token.deployedBytecode.immutableReferences['11']=[];
  assert.throws(() => resolve(build), /Missing immutable references/);
  ({build}=fixture());
  build.token.deployedBytecode.immutableReferences['11']=[{start:1,length:32}];
  assert.throws(() => resolve(build), /Overlapping/);
  ({build}=fixture());
  build.token.deployedBytecode.immutableReferences['11']=[{start:1+32*7,length:32}];
  assert.throws(() => resolve(build), /Invalid immutable reference/);
  ({build}=fixture());
  build.token.deployedBytecode.object=`0x60${'01'.repeat(32*IMMUTABLES.length)}61`;
  assert.throws(() => resolve(build), /Nonzero/);
});

test('expectations reject unknown or malformed fields', () => {
  const {expected}=fixture();
  assert.throws(() => validateExpected({...expected,owner:addr(6)}), /Unexpected expectation field/);
  assert.throws(() => validateExpected({...expected,token:undefined}), /Invalid or zero address/);
  assert.throws(() => validateExpected({...expected,treasury:addr(0)}), /Invalid or zero address/);
  assert.throws(() => validateExpected({...expected,chainId:'1'}), /chainId/);
});

test('publication is atomic, refuses simulation and never overwrites a confirmed record', async () => {
  const directory=await mkdtemp(join(tmpdir(),'nvnm-manifest-'));
  try {
    const {options,expected}=fixture();
    const manifest=await confirmDeployment(options);
    await assert.rejects(writeConfirmedManifest(directory,{...manifest,status:'simulation'}), /Only confirmed/);
    assert.deepEqual(await readdir(directory),[]);
    const path=await writeConfirmedManifest(directory,manifest);
    assert.equal(path,join(directory,`31337-${expected.token}.json`));
    const before=await readFile(path,'utf8');
    await assert.rejects(writeConfirmedManifest(directory,{...manifest,initialSupply:'123'}), {code:'EEXIST'});
    assert.equal(await readFile(path,'utf8'),before);
    assert.equal((await readdir(directory)).length,1);
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('provenance rejects changed and untracked source but permits generated manifests', async () => {
  const root=await mkdtemp(join(tmpdir(),'nvnm-provenance-'));
  const git=(...args)=>execFileSync('git',args,{cwd:root,stdio:'pipe'});
  try {
    git('init','-q');
    await writeFile(join(root,'source.sol'),'approved'); git('add','source.sol');
    git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture');
    assert.match(sourceProvenance(root).sourceCommit,/^[0-9a-f]{40}$/);
    await mkdir(join(root,'deployments'));
    await writeFile(join(root,'deployments',`31337-${addr(1)}.json`),'generated');
    assert.match(sourceProvenance(root).sourceCommit,/^[0-9a-f]{40}$/);
    await writeFile(join(root,'untracked.sol'),'unexpected');
    assert.throws(()=>sourceProvenance(root),/clean/);
    await rm(join(root,'untracked.sol'));
    await writeFile(join(root,'source.sol'),'changed');
    assert.throws(()=>sourceProvenance(root),/clean/);
  } finally {await rm(root,{recursive:true,force:true});}
});


test('rebuild removes output/compiler overrides and cleans before offline compilation', () => {
  const names=['FOUNDRY_OUT','FOUNDRY_SOLC','FOUNDRY_CONFIG','DAPP_OUT','FOUNDRY_PROFILE'];
  const saved=Object.fromEntries(names.map(n=>[n,process.env[n]]));
  try {
    for (const name of names) process.env[name]='untrusted-override';
    const calls=[];
    rebuildApprovedRelease('/approved/release', (...args)=>calls.push(args));
    assert.deepEqual(calls.map(c=>c.slice(0,2)),[['forge',['clean']],['forge',['build','--offline','--force']]]);
    for (const [, ,options] of calls) {
      assert.equal(options.cwd,'/approved/release');
      assert.deepEqual(Object.keys(options.env).filter(k=>/^(FOUNDRY_|DAPP_)/.test(k)),['FOUNDRY_PROFILE','FOUNDRY_CONFIG','FOUNDRY_OUT','FOUNDRY_CACHE_PATH']);
      assert.equal(options.env.FOUNDRY_CONFIG,'/approved/release/foundry.toml');
      assert.equal(options.env.FOUNDRY_OUT,'/approved/release/out');
      assert.equal(options.env.FOUNDRY_CACHE_PATH,'/approved/release/cache');
      assert.equal(options.env.FOUNDRY_PROFILE,'default');
    }
  } finally {for (const name of names) {if(saved[name]===undefined) delete process.env[name]; else process.env[name]=saved[name];}}
});

test('source provenance rejects ignored imports, unrecorded nested repos and external symlinks', async () => {
  const root=await mkdtemp(join(tmpdir(),'nvnm-source-'));
  const outside=await mkdtemp(join(tmpdir(),'nvnm-outside-'));
  const git=(cwd,...args)=>execFileSync('git',args,{cwd,stdio:'pipe'});
  try {
    git(root,'init','-q');
    await writeFile(join(root,'.gitignore'),'ignored.sol\nnested/\n');
    await writeFile(join(root,'tracked.sol'),'approved');
    git(root,'add','.gitignore','tracked.sol');
    git(root,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture');
    assert.equal(await assertTrackedSource(root,'tracked.sol'),await realpath(join(root,'tracked.sol')));
    await writeFile(join(root,'ignored.sol'),'not in commit');
    await assert.rejects(assertTrackedSource(root,'ignored.sol'),/not tracked/);
    await mkdir(join(root,'nested')); git(join(root,'nested'),'init','-q');
    await writeFile(join(root,'nested','source.sol'),'nested');git(join(root,'nested'),'add','source.sol');
    await assert.rejects(assertTrackedSource(root,'nested/source.sol'),/unrecorded nested/);
    await writeFile(join(outside,'source.sol'),'external');
    await symlink(join(outside,'source.sol'),join(root,'linked.sol'));
    await assert.rejects(assertTrackedSource(root,'linked.sol'),/outside checkout/);
  } finally {await rm(root,{recursive:true,force:true});await rm(outside,{recursive:true,force:true});}
});


test('rebuild refuses dotenv build overrides before starting Forge', async () => {
  const root=await mkdtemp(join(tmpdir(),'nvnm-dotenv-'));
  try {
    await writeFile(join(root,'.env'),'MAINNET_RPC_URL=https://example.invalid\nexport FOUNDRY_OUT=/elsewhere\n');
    let calls=0;
    assert.throws(()=>rebuildApprovedRelease(root,()=>calls++),/must not contain/);
    assert.equal(calls,0);
    await writeFile(join(root,'.env'),'MAINNET_RPC_URL=https://example.invalid\n');
    rebuildApprovedRelease(root,()=>calls++);
    assert.equal(calls,2);
  } finally {await rm(root,{recursive:true,force:true});}
});
