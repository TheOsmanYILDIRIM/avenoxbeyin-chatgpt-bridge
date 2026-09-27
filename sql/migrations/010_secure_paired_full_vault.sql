-- Secure paired full-vault transport (schema v10).
-- Expand-first: apply before publishing workers that require schema 10.

alter table public.brain_commands
  drop constraint if exists brain_commands_operation_check;

alter table public.brain_commands
  add constraint brain_commands_operation_check
  check (operation in (
    'avenox_bootstrap','avenox_skill_get',
    'brain_context','brain_source_get','brain_source_update',
    'brain_vault_list','brain_vault_get','brain_vault_update',
    'brain_note_create','brain_task_create','brain_task_update','brain_receipt',
    'brain_sync','brain_history','brain_skill_sync','brain_companion_compact',
    'brain_preferences_get','brain_preferences_update','brain_doctor',
    'brain_update_check','brain_update','brain_update_dismiss','brain_rollback','brain_recover',
    'brain_jev_status','brain_jev_config','brain_jev_memory'
  ));

update private.bridge_transport_meta
set schema_version=10,
    updated_at=now()
where singleton=true;

create or replace function public.bridge_transport_contract()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_version integer;
begin
  if not exists (
    select 1 from private.bridge_workers w
    where w.user_id=v_uid and w.enabled
  ) then
    raise exception 'unauthorized worker';
  end if;

  select schema_version into v_version
  from private.bridge_transport_meta
  where singleton=true;

  return jsonb_build_object(
    'schema_version', v_version,
    'claim_rpc', 'claim_next_brain_command_v2',
    'finish_rpc', 'finish_brain_command_v2',
    'command_terminal_statuses', jsonb_build_array('completed','failed','conflict'),
    'secure_envelope_version', 1,
    'secure_cipher', 'AES-256-GCM',
    'secure_result_field', 'result'
  );
end;
$$;

create or replace function private.brain_capabilities()
returns jsonb
language sql
security invoker
set search_path=''
as $$
  select jsonb_build_object(
    'bridge_api_version',3,
    'operations',jsonb_build_array(
      'avenox_bootstrap','avenox_skill_get',
      'brain_context','brain_source_get','brain_source_update',
      'brain_vault_list','brain_vault_get','brain_vault_update',
      'brain_note_create','brain_task_create','brain_task_update','brain_receipt',
      'brain_sync','brain_history','brain_skill_sync','brain_companion_compact',
      'brain_preferences_get','brain_preferences_update','brain_doctor',
      'brain_update_check','brain_update','brain_update_dismiss','brain_rollback','brain_recover',
      'brain_jev_status','brain_jev_config','brain_jev_memory'
    )
  );
$$;

revoke all on function private.brain_capabilities()
  from public,anon,authenticated;

notify pgrst, 'reload schema';
