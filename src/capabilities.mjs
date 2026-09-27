export const CAPABILITIES = [
  {
    name: 'avenox_bootstrap',
    mode: 'read',
    description: 'Return the current Bridge skill, capability catalog, Avenox core skill, version and skill manifest.',
    maps_to: 'versioned Bridge skill + local Avenox skill files + .beyin-version',
    payload_schema: { type:'object', properties:{ task:{type:'string'} }, additionalProperties:false }
  },
  {
    name: 'avenox_skill_get',
    mode: 'read',
    description: 'Read one managed Avenox skill exactly as SKILL.md.',
    maps_to: '.agents/skills/<name>/SKILL.md',
    payload_schema: { type:'object', required:['name'], properties:{ name:{type:'string'} }, additionalProperties:false }
  },
  {
    name: 'brain_context',
    mode: 'read',
    description: 'Search live Brain context with citations.',
    maps_to: 'beyin.py context',
    payload_schema: { type:'object', required:['query'], properties:{
      query:{type:'string'}, project:{type:'string'}, limit:{type:'integer'}, budget_chars:{type:'integer'},
      jev:{type:'boolean'}, audience:{enum:['public']}
    }, additionalProperties:false }
  },
  {
    name: 'brain_source_get',
    mode: 'read',
    description: 'Read one exact canonical Markdown source. Basename is allowed only when unique.',
    maps_to: 'safe vault read',
    payload_schema: { type:'object', required:['source'], properties:{ source:{type:'string'} }, additionalProperties:false }
  },
  {
    name: 'brain_source_update',
    mode: 'write',
    description: 'CAS-update an existing Markdown source and sync it. Task files are rejected; use task-update.',
    maps_to: 'safe Markdown replace + beyin.py sync',
    payload_schema: { type:'object', required:['source','expected_sha256','content'], properties:{
      source:{type:'string'}, expected_sha256:{type:'string'}, content:{type:'string'}
    }, additionalProperties:false }
  },
  {
    name: 'brain_vault_list',
    mode: 'read',
    description: 'List the trusted remote view of the Brain vault through the normal authenticated Supabase queue.',
    maps_to: 'trusted vault list',
    transport: 'trusted_supabase_queue',
    payload_schema: { type:'object', properties:{
      path:{type:'string'}, recursive:{type:'boolean'}, max_entries:{type:'integer'}
    }, additionalProperties:false }
  },
  {
    name: 'brain_vault_get',
    mode: 'read',
    description: 'Read one exact text file in the Brain vault, including companion/private Markdown, through the trusted Supabase queue.',
    maps_to: 'trusted exact vault read',
    transport: 'trusted_supabase_queue',
    payload_schema: { type:'object', required:['source'], properties:{
      source:{type:'string'}
    }, additionalProperties:false }
  },
  {
    name: 'brain_vault_update',
    mode: 'write',
    description: 'CAS-update an allowed text content file in the Brain vault through the trusted Supabase queue. Task files still require task-update.',
    maps_to: 'trusted CAS vault update + beyin.py sync',
    transport: 'trusted_supabase_queue',
    payload_schema: { type:'object', required:['source','expected_sha256','content'], properties:{
      source:{type:'string'}, expected_sha256:{type:'string'}, content:{type:'string'}
    }, additionalProperties:false }
  },
  {
    name: 'brain_note_create',
    mode: 'write',
    description: 'Create a new note/knowledge source using the official Brain transaction.',
    maps_to: 'beyin.py note-create --file',
    payload_schema: { type:'object', required:['source','text','metadata'], properties:{
      source:{type:'string'}, text:{type:'string'}, metadata:{type:'object'}
    }, additionalProperties:false }
  },
  {
    name: 'brain_task_create',
    mode: 'write',
    description: 'Create a task with revision/status/owner metadata.',
    maps_to: 'beyin.py task-create --file',
    payload_schema: { type:'object', required:['source','text','metadata'], properties:{
      source:{type:'string'}, text:{type:'string'}, metadata:{type:'object'}
    }, additionalProperties:false }
  },
  {
    name: 'brain_task_update',
    mode: 'write',
    description: 'Revision-checked task update.',
    maps_to: 'beyin.py task-update --file',
    payload_schema: { type:'object', required:['id','expected_revision','changes'], properties:{
      id:{type:'string'}, expected_revision:{type:'integer'}, changes:{type:'object'}
    }, additionalProperties:false }
  },
  {
    name: 'brain_receipt',
    mode: 'write',
    description: 'Record a source-backed work result.',
    maps_to: 'beyin.py receipt --file --harness',
    payload_schema: { type:'object', required:['event_id','summary','refs'], properties:{
      event_id:{type:'string'}, summary:{type:'string'}, refs:{type:'array',items:{type:'string'}},
      session:{type:'string'}, harness:{enum:['codex','claude','antigravity','hermes','opencode','omp']}
    }, additionalProperties:false }
  },
  {
    name: 'brain_sync',
    mode: 'maintenance',
    description: 'Refresh the Brain index from canonical sources.',
    maps_to: 'beyin.py sync',
    payload_schema: { type:'object', additionalProperties:false }
  },
  {
    name: 'brain_history',
    mode: 'read',
    description: 'Inspect the history of one Brain record without treating rejected history as current truth.',
    maps_to: 'beyin.py history RECORD_ID',
    payload_schema: { type:'object', required:['id'], properties:{ id:{type:'string'} }, additionalProperties:false }
  },
  {
    name: 'brain_skill_sync',
    mode: 'maintenance',
    description: 'Reconcile managed skill mirrors using Avenox conflict rules.',
    maps_to: 'beyin.py skill-sync',
    payload_schema: { type:'object', additionalProperties:false }
  },
  {
    name: 'brain_companion_compact',
    mode: 'maintenance',
    description: 'Losslessly archive old companion sections; may be dry-run.',
    maps_to: 'beyin.py companion-compact',
    payload_schema: { type:'object', properties:{ dry_run:{type:'boolean'} }, additionalProperties:false }
  },
  {
    name: 'brain_preferences_get',
    mode: 'read',
    description: 'Read current Brain runtime/preferences settings.',
    maps_to: 'beyin.py preferences',
    payload_schema: { type:'object', additionalProperties:false }
  },
  {
    name: 'brain_preferences_update',
    mode: 'write',
    description: 'Update only explicitly supplied supported preference fields.',
    maps_to: 'beyin.py preferences <validated flags>',
    payload_schema: { type:'object', properties:{
      profile:{enum:['normal','economical','manual']},
      interval_minutes:{type:'integer'}, context_mode:{enum:['turn','session','off']},
      context_chars:{type:'integer'}, auto_sync:{type:'boolean'},
      secret_filter:{type:'boolean'}, last_session_chars:{type:'integer'},
      threads_chars:{type:'integer'}, update_notifications:{type:'boolean'}
    }, additionalProperties:false }
  },
  {
    name: 'brain_doctor',
    mode: 'read',
    description: 'Inspect Brain health, lifecycle, sync freshness, skill conflicts and update status.',
    maps_to: 'beyin.py doctor',
    payload_schema: { type:'object', additionalProperties:false }
  },
  {
    name: 'brain_update_check',
    mode: 'read',
    description: 'Check official release metadata without installing.',
    maps_to: 'beyin.py update --check --metadata-only',
    payload_schema: { type:'object', additionalProperties:false }
  },
  {
    name: 'brain_update',
    mode: 'write',
    description: 'Install the official stable Brain update. Requires explicit user intent.',
    maps_to: 'beyin.py update',
    user_intent_required: true,
    payload_schema: { type:'object', additionalProperties:false }
  },
  {
    name: 'brain_update_dismiss',
    mode: 'write',
    description: 'Dismiss one release notification.',
    maps_to: 'beyin.py update --dismiss VERSION',
    payload_schema: { type:'object', required:['version'], properties:{ version:{type:'string'} }, additionalProperties:false }
  },
  {
    name: 'brain_rollback',
    mode: 'write',
    description: 'Rollback to the previous managed Brain release, then verify health.',
    maps_to: 'beyin.py rollback + doctor',
    user_intent_required: true,
    payload_schema: { type:'object', additionalProperties:false }
  },
  {
    name: 'brain_recover',
    mode: 'write',
    description: 'Recover an interrupted managed update.',
    maps_to: 'beyin.py recover',
    user_intent_required: true,
    payload_schema: { type:'object', additionalProperties:false }
  },
  {
    name: 'brain_jev_status',
    mode: 'read',
    description: 'Read optional Jev/Laya advisor status; optional local health check for Laya.',
    maps_to: 'beyin.py jev status',
    payload_schema: { type:'object', properties:{ check:{type:'boolean'} }, additionalProperties:false }
  },
  {
    name: 'brain_jev_config',
    mode: 'write',
    description: 'Change Jev mode/features/provider using validated options only.',
    maps_to: 'beyin.py jev off|shadow|on <validated flags>',
    user_intent_required: true,
    payload_schema: { type:'object', required:['mode'], properties:{
      mode:{enum:['off','shadow','on']},
      enable:{type:'array',items:{enum:['context','review','answer','auto_context']}},
      disable:{type:'array',items:{enum:['context','review','answer','auto_context']}},
      provider:{enum:['typesafe','vercel','laya']},
      model:{enum:['multilingual','english']},
      base_url:{type:'string'}
    }, additionalProperties:false }
  },
  {
    name: 'brain_jev_memory',
    mode: 'write',
    description: 'Run source-grounded memory review for a proposal. It never writes memory by itself.',
    maps_to: 'beyin.py jev-memory --project --file',
    payload_schema: { type:'object', required:['project','proposal'], properties:{
      project:{type:'string'}, proposal:{type:'object'}
    }, additionalProperties:false }
  }
];

export const CAPABILITY_MAP = new Map(CAPABILITIES.map(x => [x.name, x]));

export const BRIDGE_API_VERSION = 3;
