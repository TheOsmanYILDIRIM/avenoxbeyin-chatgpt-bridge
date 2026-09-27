-- Add read-only vault discovery/search primitives without changing transport schema v11.
-- These operations do not execute shell commands and keep existing vault denylist semantics.

alter table public.brain_commands
  drop constraint if exists brain_commands_operation_check;

alter table public.brain_commands
  add constraint brain_commands_operation_check
  check (operation in (
    'avenox_bootstrap','avenox_skill_get',
    'brain_context','brain_source_get','brain_source_update',
    'brain_vault_list','brain_vault_find','brain_vault_search','brain_vault_read_range',
    'brain_vault_get','brain_vault_update',
    'brain_note_create','brain_task_create','brain_task_update','brain_receipt',
    'brain_sync','brain_history','brain_skill_sync','brain_companion_compact',
    'brain_preferences_get','brain_preferences_update','brain_doctor',
    'brain_update_check','brain_update','brain_update_dismiss','brain_rollback','brain_recover',
    'brain_jev_status','brain_jev_config','brain_jev_memory'
  ));
