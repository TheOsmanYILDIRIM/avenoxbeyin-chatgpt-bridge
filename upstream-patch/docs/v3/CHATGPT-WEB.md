# ChatGPT Web bridge (optional)

ChatGPT Web cannot execute a local `beyin.py` directly. The optional
`avenoxbeyin-chatgpt-bridge` adapter uses Supabase only as a command/result
transport while the installed local Beyin remains authoritative.

This integration follows the Jev opt-in model:

- default is **off**;
- a normal Avenox installation does not require Node, Supabase or a worker;
- enabling ChatGPT Web requires a separately installed Node Bridge;
- Avenox stores only `mode` and the absolute Bridge root in runtime state;
- Supabase credentials and worker secrets stay in the Bridge configuration;
- `off` stops the Bridge worker but preserves its configuration for a later `on`.

Commands:

```sh
python3 beyin.py chatgpt status
python3 beyin.py chatgpt on --bridge-root "$HOME/.local/share/avenox-brain-bridge"
python3 beyin.py chatgpt off
```

`chatgpt on` validates Node 20.6+ and the external Bridge installation before
starting it. Repeating `on` is idempotent. `off` never deletes Bridge config,
Supabase data or Brain sources.

The Bridge has its own remote privacy boundary: exact remote source reads/writes
reject Companion/identity files and sources marked `visibility: private`,
`remote_allowed: false` or sensitive.

This first integration does not install an OS startup service. After a device
reboot, `chatgpt status` may show `mode: on` with `running: false`; running
`chatgpt on` again restarts the worker. Platform startup services can remain a
separate follow-up rather than becoming a default Avenox dependency.
