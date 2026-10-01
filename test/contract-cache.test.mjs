import test from 'node:test';
import assert from 'node:assert/strict';
import {
  Bridge,
  stableJson,
  contractHashForTest,
  adaptiveIdlePollMs,
  CONTRACT_SNAPSHOT_VERSION
} from '../src/worker.mjs';

test('stableJson and contract hash ignore object key order', () => {
  const a = { bridge_skill:{name:'x',content:'abc'}, bridge_capabilities:[{name:'a'}], core_skill:{name:'b'}, skills_manifest:[] };
  const b = { skills_manifest:[], core_skill:{name:'b'}, bridge_capabilities:[{name:'a'}], bridge_skill:{content:'abc',name:'x'} };
  assert.equal(stableJson(a), stableJson(b));
  assert.equal(contractHashForTest(a), contractHashForTest(b));
});

test('contract hash changes when canonical contract content changes', () => {
  const a = { bridge_skill:{content:'abc'}, bridge_capabilities:[], core_skill:{content:'core'}, skills_manifest:[] };
  const b = { ...a, bridge_skill:{content:'abcd'} };
  assert.notEqual(contractHashForTest(a), contractHashForTest(b));
});

test('compact hook capsule carries cached contract identity and operational rules', async () => {
  const bridge = new Bridge({});
  bridge._contractSnapshot = {
    contract_hash: 'a'.repeat(64),
    contract_version: CONTRACT_SNAPSHOT_VERSION
  };
  const capsule = await bridge.compactHookCapsule();
  assert.match(capsule, /contract=aaaaaaaa/);
  assert.match(capsule, /avenox_turn_context is refresh\/recovery\/debug only/);
  assert.ok(capsule.length < 700);
});

test('adaptive idle polling backs off and applies bounded jitter', () => {
  const noJitter = () => 0.5;
  assert.equal(adaptiveIdlePollMs(1, noJitter), 3000);
  assert.equal(adaptiveIdlePollMs(11, noJitter), 5000);
  assert.equal(adaptiveIdlePollMs(25, noJitter), 10000);
  assert.equal(adaptiveIdlePollMs(37, noJitter), 30000);
  assert.equal(adaptiveIdlePollMs(43, noJitter), 60000);
  assert.equal(adaptiveIdlePollMs(1, () => 0), 2700);
  assert.equal(adaptiveIdlePollMs(1, () => 1), 3300);
});
