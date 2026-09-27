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
