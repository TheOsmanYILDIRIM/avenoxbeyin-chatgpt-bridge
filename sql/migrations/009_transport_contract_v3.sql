-- Bridge transport contract v3.
-- Expand-only migration: safe to apply before updating workers.

create table if not exists private.bridge_transport_meta (
  singleton boolean primary key default true check (singleton),
  schema_version integer not null,
  updated_at timestamptz not null default now()
);

insert into private.bridge_transport_meta(singleton,schema_version)
values (true, 9)
on conflict (singleton) do update
set schema_version=excluded.schema_version,
    updated_at=now();

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
    'command_terminal_statuses', jsonb_build_array('completed','failed','conflict')
  );
end;
$$;

create or replace function public.claim_next_brain_command_v2()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.brain_commands;
begin
  if not exists (
    select 1 from private.bridge_workers w
    where w.user_id=v_uid and w.enabled
  ) then
    raise exception 'unauthorized worker';
  end if;

  update public.brain_commands c
  set status='failed',
      error=jsonb_build_object(
        'error','stale_claim_recovered',
        'message','stale claimed/running command was closed before claiming new work'
      ),
      completed_at=now(),
      updated_at=now()
  where c.worker_id=v_uid::text
    and c.status in ('claimed','running')
    and c.updated_at < now() - interval '60 seconds';

  with candidate as (
    select c.id
    from public.brain_commands c
    where c.status='pending'
    order by c.created_at asc
    for update skip locked
    limit 1
  )
  update public.brain_commands c
  set status='claimed',
      worker_id=v_uid::text,
      claimed_at=now(),
      updated_at=now()
  from candidate
  where c.id=candidate.id
  returning c.* into v_row;

  if v_row.id is null then
    return null;
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.bridge_transport_contract() from public,anon;
revoke all on function public.claim_next_brain_command_v2() from public,anon;
grant execute on function public.bridge_transport_contract() to authenticated;
grant execute on function public.claim_next_brain_command_v2() to authenticated;

notify pgrst, 'reload schema';
