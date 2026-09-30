-- Avenox Beyin ChatGPT Bridge - Supabase transport schema
-- ChatGPT writes commands through the trusted Supabase connector.
-- The local worker authenticates with a dedicated Supabase Auth user.

create extension if not exists pgcrypto;
create schema if not exists private;

create table if not exists public.brain_commands (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text unique not null default gen_random_uuid()::text,
  operation text not null check (operation in (
    'avenox_bootstrap','avenox_turn_context','avenox_skill_get',
    'brain_context','brain_source_get','brain_source_update',
    'brain_vault_list','brain_vault_find','brain_vault_search','brain_vault_read_range','brain_vault_get','brain_vault_update',
    'brain_note_create','brain_task_create','brain_task_update','brain_receipt',
    'brain_sync','brain_history','brain_skill_sync','brain_companion_compact',
    'brain_preferences_get','brain_preferences_update','brain_doctor',
    'brain_update_check','brain_update','brain_update_dismiss','brain_rollback','brain_recover',
    'brain_jev_status','brain_jev_config','brain_jev_memory'
  )),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending'
    check (status in ('pending','claimed','running','completed','failed','conflict')),
  requested_by text not null default 'chatgpt',
  worker_id text,
  result jsonb,
  error jsonb,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.brain_responses (
  command_id uuid primary key references public.brain_commands(id) on delete cascade,
  response_text text not null,
  source_refs text[] not null default '{}',
  response_kind text not null
    check (response_kind in ('context','doctor','mutation','bootstrap','skill','source','turn_context')),
  created_at timestamptz not null default now()
);

create table if not exists private.bridge_workers (
  user_id uuid primary key,
  worker_name text unique not null,
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.brain_commands enable row level security;
alter table public.brain_responses enable row level security;
revoke all on public.brain_commands from anon, authenticated;
revoke all on public.brain_responses from anon, authenticated;

create or replace function public.claim_next_brain_command()
returns setof public.brain_commands
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_worker text;
begin
  select w.worker_name into v_worker
  from private.bridge_workers w
  where w.user_id = v_uid and w.enabled;

  if v_worker is null then
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

  return query
  with candidate as (
    select c.id
    from public.brain_commands c
    where c.status = 'pending'
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
  returning c.*;
end;
$$;

create or replace function public.finish_brain_command(
  p_id uuid,
  p_status text,
  p_result jsonb default null,
  p_error jsonb default null,
  p_response_text text default null,
  p_source_refs text[] default array[]::text[],
  p_response_kind text default null
)
returns public.brain_commands
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

  if p_status not in ('completed','failed','conflict') then
    raise exception 'invalid terminal status';
  end if;

  if p_status='completed' and p_response_text is not null
     and p_response_kind not in ('context','doctor','mutation','bootstrap','skill','source') then
    raise exception 'invalid response kind';
  end if;

  update public.brain_commands
  set status=p_status,
      result=p_result,
      error=p_error,
      completed_at=now(),
      updated_at=now()
  where id=p_id
    and worker_id=v_uid::text
    and status in ('claimed','running')
  returning * into v_row;

  if v_row.id is null then
    raise exception 'command not owned by worker or not finishable';
  end if;

  if p_status='completed' and p_response_text is not null then
    insert into public.brain_responses(command_id,response_text,source_refs,response_kind)
    values(p_id,p_response_text,coalesce(p_source_refs,array[]::text[]),p_response_kind)
    on conflict(command_id) do update
      set response_text=excluded.response_text,
          source_refs=excluded.source_refs,
          response_kind=excluded.response_kind;
  end if;

  return v_row;
end;
$$;

revoke all on function public.claim_next_brain_command() from public,anon;
revoke all on function public.finish_brain_command(uuid,text,jsonb,jsonb,text,text[],text)
  from public,anon;
grant execute on function public.claim_next_brain_command() to authenticated;
grant execute on function public.finish_brain_command(uuid,text,jsonb,jsonb,text,text[],text)
  to authenticated;


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
      'brain_note_create','brain_task_create','brain_task_update','brain_receipt',
      'brain_sync','brain_history','brain_skill_sync','brain_companion_compact',
      'brain_preferences_get','brain_preferences_update','brain_doctor',
      'brain_update_check','brain_update','brain_update_dismiss','brain_rollback','brain_recover',
      'brain_jev_status','brain_jev_config','brain_jev_memory'
    )
  );
$$;

revoke all on function private.brain_capabilities() from public,anon,authenticated;


-- Versioned Bridge transport contract. Worker startup must validate this before claiming work.
create table if not exists private.bridge_transport_meta (
  singleton boolean primary key default true check (singleton),
  schema_version integer not null,
  updated_at timestamptz not null default now()
);

insert into private.bridge_transport_meta(singleton,schema_version)
values (true, 11)
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
    'command_terminal_statuses', jsonb_build_array('completed','failed','conflict'),
    'vault_transport', 'trusted_supabase_queue'
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

create or replace function public.finish_brain_command_v2(p jsonb)
returns public.brain_commands
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_status text;
  v_result jsonb;
  v_error jsonb;
  v_response_text text;
  v_source_refs text[];
  v_response_kind text;
  v_row public.brain_commands;
begin
  if not exists (
    select 1 from private.bridge_workers w
    where w.user_id=v_uid and w.enabled
  ) then
    raise exception 'unauthorized worker';
  end if;

  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'payload must be object';
  end if;

  v_id := (p->>'id')::uuid;
  v_status := p->>'status';
  v_result := p->'result';
  v_error := p->'error';
  v_response_text := p->>'response_text';
  v_response_kind := p->>'response_kind';

  select coalesce(array_agg(value), array[]::text[])
    into v_source_refs
  from jsonb_array_elements_text(coalesce(p->'source_refs','[]'::jsonb));

  if v_status not in ('completed','failed','conflict') then
    raise exception 'invalid terminal status';
  end if;

  if v_status='completed' and v_response_text is not null
     and v_response_kind not in ('context','doctor','mutation','bootstrap','skill','source') then
    raise exception 'invalid response kind';
  end if;

  update public.brain_commands
  set status=v_status,
      result=v_result,
      error=v_error,
      completed_at=now(),
      updated_at=now()
  where id=v_id
    and worker_id=v_uid::text
    and status in ('claimed','running')
  returning * into v_row;

  if v_row.id is null then
    raise exception 'command not owned by worker or not finishable';
  end if;

  if v_status='completed' and v_response_text is not null then
    insert into public.brain_responses(command_id,response_text,source_refs,response_kind)
    values(v_id,v_response_text,v_source_refs,v_response_kind)
    on conflict(command_id) do update
      set response_text=excluded.response_text,
          source_refs=excluded.source_refs,
          response_kind=excluded.response_kind;
  end if;

  return v_row;
end;
$$;

create or replace function public.get_recent_task_journal(p_limit integer default 30)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_result jsonb;
begin
  if not exists (
    select 1 from private.bridge_workers w
    where w.user_id=v_uid and w.enabled
  ) then
    raise exception 'unauthorized worker';
  end if;

  select coalesce(jsonb_agg(entry), '[]'::jsonb)
  into v_result
  from (
    select
      c.id,
      c.idempotency_key,
      c.operation,
      c.status,
      c.requested_by,
      c.created_at,
      c.claimed_at,
      c.completed_at,
      case
        when c.operation in ('brain_task_create','brain_note_create','brain_source_get','brain_source_update','brain_vault_get','brain_vault_update','brain_vault_read_range')
          then c.payload->>'source'
        when c.operation = 'brain_task_update'
          then coalesce(c.payload->>'id', c.payload->>'source')
        when c.operation = 'brain_receipt'
          then c.payload->>'event_id'
        when c.operation in ('avenox_bootstrap','avenox_turn_context')
          then coalesce(c.payload->>'task', c.payload->>'project')
        when c.operation = 'avenox_skill_get'
          then c.payload->>'name'
        when c.operation = 'brain_context'
          then c.payload->>'project'
        else null
      end as target_ref,
      case
        when c.operation in ('brain_task_create')
          then c.payload->'metadata'->>'id'
        when c.operation = 'brain_task_update'
          then c.payload->>'id'
        when c.operation = 'brain_receipt'
          then c.payload->>'event_id'
        else null
      end as task_id,
      case
        when c.operation = 'brain_receipt'
          then coalesce(c.payload->>'summary', '')
        when c.operation = 'brain_context'
          then coalesce(c.payload->>'query', '')
        when c.operation in ('avenox_bootstrap','avenox_turn_context')
          then coalesce(c.payload->>'task', c.payload->>'project', '')
        when c.operation in ('brain_task_create')
          then coalesce(c.payload->'metadata'->>'title', '')
        when c.operation in ('brain_task_update')
          then coalesce(c.payload->'changes'->>'status', '')
        else null
      end as summary,
      coalesce(r.source_refs, array[]::text[]) as source_refs,
      r.response_kind,
      c.error->>'error' as error_code
    from public.brain_commands c
    left join public.brain_responses r on r.command_id = c.id
    order by c.created_at desc
    limit v_limit
  ) entry;

  return v_result;
end;
$$;

revoke all on function public.bridge_transport_contract() from public,anon;
revoke all on function public.claim_next_brain_command_v2() from public,anon;
revoke all on function public.finish_brain_command_v2(jsonb) from public,anon;
revoke all on function public.get_recent_task_journal(integer) from public,anon;
grant execute on function public.bridge_transport_contract() to authenticated;
grant execute on function public.claim_next_brain_command_v2() to authenticated;
grant execute on function public.finish_brain_command_v2(jsonb) to authenticated;
grant execute on function public.get_recent_task_journal(integer) to authenticated;
