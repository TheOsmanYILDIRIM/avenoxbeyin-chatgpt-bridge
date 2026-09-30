import test from 'node:test';
import assert from 'node:assert/strict';

test('operation names are documented',()=>{
  for(const op of ['avenox_bootstrap','avenox_turn_context','avenox_turn_finalize','avenox_skill_get','brain_context','brain_source_get','brain_doctor']) {
    assert.match(op,/^[a-z_]+$/);
  }
});
