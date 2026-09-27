# Upstream ChatGPT Web integration proposal

Pinned upstream base: `avenoxai/avenoxbeyin@eed645c2323b76bf6f0105fc9b60e440fb49bc80`.

Design constraints:

1. Treat ChatGPT Web like Jev/Laya: optional, explicit opt-in, default off.
2. Do not vendor or rewrite the Node Bridge in Avenox core.
3. Do not add Node/Supabase requirements to normal Avenox installs.
4. Avenox stores no Bridge secret; only `mode` and external `bridge_root`.
5. Process lifecycle stays inside the Node Bridge via `start|stop|status`.
6. Doctor exposes a separate `chatgpt_bridge` object, not fake lifecycle events.
7. `chatgpt` may be accepted as receipt attribution without becoming a hook harness.
8. Upstream update/rollback owns only the small Python controller that ships with Avenox;
   the external Bridge remains independently installed, like an external optional backend.

Files in this proposal mirror the intended upstream paths. They are not applied to
`avenoxai/avenoxbeyin` yet because the connected GitHub account has no push permission
and no fork-creation action is available.

## File map

Copy these proposal files to the same relative paths in an upstream checkout:

- `template/.claude/scripts/beyin_v3_chatgpt.py` — new optional controller.
- `scripts/beyin_v3.py` — `chatgpt status|on|off`, doctor field, receipt CLI choice.
- `scripts/beyin_entry.py` — human-readable ChatGPT status/doctor lines.
- `template/.claude/scripts/beyin_v3.py` — accepts `chatgpt` for receipt attribution only.
- `template/.claude/scripts/beyin_v3_sync.py` — accepts/replays `chatgpt` receipts.
- `template/.agents/skills/beyin/SKILL.md` — names `chatgpt` as a receipt source.
- `docs/v3/CHATGPT-WEB.md` — opt-in behavior and boundaries.
- `docs/v3/README.md` — documentation link.
- `tests/v3_chatgpt_test.py` — controller unit contract.
- `tests/v3_chatgpt_installed_test.py` — installed-product/receipt contract.

No installer file-list edit is required: the installer already packages
`template/.claude/scripts/beyin_v3*.py`.

## Coordinated Bridge change

The proposal branch also changes the external Bridge so that, once upstream accepts
`chatgpt` receipts, `brain_receipt` defaults to `harness=chatgpt`. Keep this
change on the proposal branch until the upstream runtime accepts that value.

## Merge gates after applying to an upstream fork

Run from the upstream checkout:

```sh
python -m unittest tests/v3_chatgpt_test.py
python -m unittest tests/v3_chatgpt_installed_test.py
python -m unittest discover -s tests -p 'v3_*test.py'
python scripts/evaluate_v3.py
```

Then build/install the candidate package into a temporary synthetic vault and verify:

1. fresh install creates no `chatgpt.json`;
2. `beyin.py doctor --json` reports ChatGPT off without invoking Node;
3. `beyin.py chatgpt status` is read-only;
4. `beyin.py chatgpt on --bridge-root PATH` starts exactly one external Bridge worker;
5. repeated `on` is idempotent;
6. `beyin.py chatgpt off` stops that worker and preserves Bridge config;
7. `receipt --harness chatgpt` writes and replays normally;
8. doctor lifecycle remains limited to actual hook harnesses and contains no synthetic
   `chatgpt` lifecycle row;
9. update/rollback of Avenox preserves `chatgpt.json` because it is runtime state, while
   the external Node Bridge remains independently managed.

Live evidence should be collected only from a synthetic/test vault. Do not include
Supabase secrets, real note content or worker passwords in PR logs.
