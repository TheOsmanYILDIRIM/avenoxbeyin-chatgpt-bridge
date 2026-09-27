-- Simplify Bridge API v3 full-vault transport (schema v11).
-- Supabase is a trusted relay owned by the user; full-vault operations use the normal queue.
-- Credential/runtime path guards, CAS, task revision checks and no-shell policy remain.

update private.bridge_transport_meta
set schema_version=11,
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
    'vault_transport', 'trusted_supabase_queue'
  );
end;
$$;

notify pgrst, 'reload schema';
