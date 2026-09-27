# ChatGPT project instructions

Before the first meaningful Avenox/Brain task in a conversation, use the connected Supabase project `avenox-bridge` (`qkywbefhhcwnmsrhprnh`) to run `avenox_bootstrap`.

Bootstrap is not required for simple greetings or social conversation.

Treat the bootstrap response fields `bridge_skill`, `bridge_capabilities`, `core_skill`, and `skills_manifest` as the current Avenox contract for that conversation and follow them.

Do not guess operation names, payload fields, transport behavior, or capabilities. If the live contract does not provide the required information, do not invent it.
