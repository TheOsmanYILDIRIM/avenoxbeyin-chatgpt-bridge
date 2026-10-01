-- Avenox Beyin ChatGPT Bridge - Supabase transport schema
-- ChatGPT writes commands through the trusted Supabase connector.
-- The local worker authenticates with a dedicated Supabase Auth user.

create extension if not exists pgcrypto;
create schema if not exists private;

create table if not exists public.brain_commands (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text unique not null default gen_random_uuid()::text,
  operation text not null check (operation in (
    'avenox_bootstrap','avenox_turn_context','avenox_turn_finalize','avenox_skill_get',
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
    check (response_kind in ('context','doctor','mutation','bootstrap','skill','source','turn_context','turn_finalize')),
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
     and p_response_kind not in ('context','doctor','mutation','bootstrap','skill','source','turn_context') then
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
     and v_response_kind not in ('context','doctor','mutation','bootstrap','skill','source','turn_context') then
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

create table if not exists public.chatgpt_turns (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  task text,
  project text,
  status text not null check (status in ('open', 'finalized', 'abandoned')) default 'open',
  state_changed boolean,
  summary text,
  refs text[] default '{}',
  created_at timestamptz not null default now(),
  finalized_at timestamptz
);

create index if not exists idx_chatgpt_turns_user_status_created 
  on public.chatgpt_turns(user_id, status, created_at desc);

create index if not exists idx_chatgpt_turns_user_created 
  on public.chatgpt_turns(user_id, created_at desc);

alter table public.chatgpt_turns enable row level security;

create policy "chatgpt_turns_select_own" on public.chatgpt_turns
  for select using (auth.uid() = user_id);

create policy "chatgpt_turns_insert_own" on public.chatgpt_turns
  for insert with check (auth.uid() = user_id);

create policy "chatgpt_turns_update_own" on public.chatgpt_turns
  for update using (auth.uid() = user_id);

create or replace function public.open_chatgpt_turn(
  p_task text default null,
  p_project text default null,
  p_turn_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as 15527
declare
  v_user_id uuid := auth.uid();
  v_turn_id text := coalesce(nullif(trim(p_turn_id), ''), gen_random_uuid()::text);
  v_prev record;
  v_prev_summary jsonb := null;
begin
  if v_user_id is null then
    raise exception 'authenticated user required';
  end if;

  select id, task, project, created_at
  into v_prev
  from public.chatgpt_turns
  where user_id = v_user_id
    and status = 'open'
    and id <> v_turn_id
  order by created_at desc
  limit 1;

  if found then
    v_prev_summary := jsonb_build_object(
      'turn_id', v_prev.id,
      'task', v_prev.task,
      'project', v_prev.project,
      'created_at', v_prev.created_at
    );
  end if;

  insert into public.chatgpt_turns (id, user_id, task, project, status, created_at)
  values (v_turn_id, v_user_id, p_task, p_project, 'open', now())
  on conflict (id) do update set
    task = coalesce(excluded.task, public.chatgpt_turns.task),
    project = coalesce(excluded.project, public.chatgpt_turns.project);

  return jsonb_build_object(
    'turn_id', v_turn_id,
    'previous_unfinalized_turn', v_prev_summary
  );
end;
15527;

create or replace function public.finalize_chatgpt_turn(
  p_turn_id text,
  p_state_changed boolean,
  p_summary text,
  p_refs text[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as 15527
declare
  v_user_id uuid := auth.uid();
  v_turn record;
begin
  if v_user_id is null then
    raise exception 'authenticated user required';
  end if;

  if p_turn_id is null or trim(p_turn_id) = '' then
    raise exception 'turn_id required';
  end if;

  select id, status, state_changed, summary, refs, finalized_at
  into v_turn
  from public.chatgpt_turns
  where id = trim(p_turn_id)
    and user_id = v_user_id;

  if not found then
    insert into public.chatgpt_turns (
      id, user_id, status, state_changed, summary, refs, created_at, finalized_at
    )
    values (
      trim(p_turn_id), v_user_id, 'finalized', p_state_changed, p_summary, coalesce(p_refs, '{}'), now(), now()
    );

    return jsonb_build_object(
      'status', 'finalized',
      'turn_id', trim(p_turn_id),
      'idempotent', false
    );
  end if;

  if v_turn.status = 'finalized' then
    return jsonb_build_object(
      'status', 'finalized',
      'turn_id', v_turn.id,
      'idempotent', true
    );
  end if;

  update public.chatgpt_turns
  set
    status = 'finalized',
    state_changed = p_state_changed,
    summary = p_summary,
    refs = coalesce(p_refs, '{}'),
    finalized_at = now()
  where id = v_turn.id;

  return jsonb_build_object(
    'status', 'finalized',
    'turn_id', v_turn.id,
    'idempotent', false
  );
end;
15527;


-- Contract snapshot cache: read-mostly ChatGPT bootstrap fast path.
create table if not exists public.avenox_contract_snapshot (
  singleton boolean primary key default true check (singleton),
  contract_hash text not null check (length(contract_hash) = 64),
  contract_version integer not null check (contract_version > 0),
  snapshot jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.avenox_contract_snapshot enable row level security;
revoke all on public.avenox_contract_snapshot from anon;
grant select on public.avenox_contract_snapshot to authenticated;

drop policy if exists avenox_contract_snapshot_read on public.avenox_contract_snapshot;
create policy avenox_contract_snapshot_read
on public.avenox_contract_snapshot
for select
to authenticated
using (true);

create or replace function public.publish_avenox_contract_snapshot(p_snapshot jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_version integer;
  v_row public.avenox_contract_snapshot;
begin
  if not exists (
    select 1 from private.bridge_workers w
    where w.user_id=v_uid and w.enabled
  ) then
    raise exception 'unauthorized worker';
  end if;

  v_hash := nullif(p_snapshot->>'contract_hash','');
  v_version := nullif(p_snapshot->>'contract_version','')::integer;
  if v_hash is null or length(v_hash) <> 64 or v_version is null or v_version < 1 then
    raise exception 'invalid contract snapshot';
  end if;

  insert into public.avenox_contract_snapshot(singleton,contract_hash,contract_version,snapshot,updated_at)
  values(true,v_hash,v_version,p_snapshot,now())
  on conflict(singleton) do update
    set contract_hash=excluded.contract_hash,
        contract_version=excluded.contract_version,
        snapshot=excluded.snapshot,
        updated_at=case
          when public.avenox_contract_snapshot.contract_hash is distinct from excluded.contract_hash
            or public.avenox_contract_snapshot.contract_version is distinct from excluded.contract_version
          then now()
          else public.avenox_contract_snapshot.updated_at
        end
  returning * into v_row;

  return v_row.snapshot || jsonb_build_object('published_at',v_row.updated_at);
end;
$$;

revoke all on function public.publish_avenox_contract_snapshot(jsonb) from public,anon;
grant execute on function public.publish_avenox_contract_snapshot(jsonb) to authenticated;

create or replace function public.get_avenox_contract_snapshot()
returns jsonb
language sql
security definer
stable
set search_path=''
as $$
  select s.snapshot || jsonb_build_object('published_at',s.updated_at)
  from public.avenox_contract_snapshot s
  where s.singleton=true;
$$;

revoke all on function public.get_avenox_contract_snapshot() from public,anon;
grant execute on function public.get_avenox_contract_snapshot() to authenticated;


-- Long-poll transport optimization (2026-10-01)

create or replace function public.claim_next_brain_command_wait(
  p_timeout_seconds integer default 25,
  p_poll_interval_ms integer default 1000
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.brain_commands;
  v_deadline timestamptz;
  v_sleep double precision;
begin
  if not exists (
    select 1 from private.bridge_workers w
    where w.user_id=v_uid and w.enabled
  ) then raise exception 'unauthorized worker'; end if;

  p_timeout_seconds := least(greatest(coalesce(p_timeout_seconds,25),0),30);
  p_poll_interval_ms := least(greatest(coalesce(p_poll_interval_ms,1000),100),5000);
  v_deadline := clock_timestamp()+make_interval(secs=>p_timeout_seconds);
  v_sleep := p_poll_interval_ms::double precision/1000.0;

  loop
    update public.brain_commands c
    set status='failed',
        error=jsonb_build_object('error','stale_claim_recovered','message','stale claimed/running command was closed before claiming new work'),
        completed_at=now(),updated_at=now()
    where c.worker_id=v_uid::text
      and c.status in ('claimed','running')
      and c.updated_at < now()-interval '60 seconds';

    with candidate as (
      select c.id from public.brain_commands c
      where c.status='pending'
      order by c.created_at asc
      for update skip locked
      limit 1
    )
    update public.brain_commands c
    set status='claimed',worker_id=v_uid::text,claimed_at=now(),updated_at=now()
    from candidate
    where c.id=candidate.id
    returning c.* into v_row;

    if v_row.id is not null then return to_jsonb(v_row); end if;
    if p_timeout_seconds=0 or clock_timestamp()>=v_deadline then return null; end if;
    perform pg_sleep(least(v_sleep,greatest(0.0,extract(epoch from (v_deadline-clock_timestamp())))));
  end loop;
end;
$$;

revoke all on function public.claim_next_brain_command_wait(integer,integer) from public,anon;
grant execute on function public.claim_next_brain_command_wait(integer,integer) to authenticated;

create or replace function public.wait_brain_command(
  p_command_id uuid,
  p_timeout_seconds integer default 20,
  p_poll_interval_ms integer default 500
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_deadline timestamptz;
  v_sleep double precision;
  v_cmd public.brain_commands;
  v_response public.brain_responses;
begin
  p_timeout_seconds := least(greatest(coalesce(p_timeout_seconds,20),0),30);
  p_poll_interval_ms := least(greatest(coalesce(p_poll_interval_ms,500),100),5000);
  v_deadline := clock_timestamp()+make_interval(secs=>p_timeout_seconds);
  v_sleep := p_poll_interval_ms::double precision/1000.0;

  loop
    select * into v_cmd from public.brain_commands where id=p_command_id;
    if v_cmd.id is null then
      return jsonb_build_object('command_id',p_command_id,'found',false,'terminal',true,'status','not_found','timed_out',false);
    end if;

    if v_cmd.status in ('completed','failed','conflict') then
      select * into v_response from public.brain_responses where command_id=p_command_id;
      return jsonb_build_object(
        'command_id',v_cmd.id,'found',true,'status',v_cmd.status,'terminal',true,'timed_out',false,
        'result',v_cmd.result,'error',v_cmd.error,
        'response_text',v_response.response_text,
        'source_refs',coalesce(to_jsonb(v_response.source_refs),'[]'::jsonb),
        'response_kind',v_response.response_kind,
        'completed_at',v_cmd.completed_at
      );
    end if;

    if p_timeout_seconds=0 or clock_timestamp()>=v_deadline then
      return jsonb_build_object(
        'command_id',v_cmd.id,'found',true,'status',v_cmd.status,'terminal',false,'timed_out',(p_timeout_seconds>0),
        'response_text',null,'error',v_cmd.error,'updated_at',v_cmd.updated_at
      );
    end if;
    perform pg_sleep(least(v_sleep,greatest(0.0,extract(epoch from (v_deadline-clock_timestamp())))));
  end loop;
end;
$$;

revoke all on function public.wait_brain_command(uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.wait_brain_command(uuid,integer,integer) to service_role;

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
  ) then raise exception 'unauthorized worker'; end if;

  select schema_version into v_version
  from private.bridge_transport_meta
  where singleton=true;

  return jsonb_build_object(
    'schema_version',v_version,
    'claim_rpc','claim_next_brain_command_v2',
    'claim_wait_rpc','claim_next_brain_command_wait',
    'finish_rpc','finish_brain_command_v2',
    'command_terminal_statuses',jsonb_build_array('completed','failed','conflict'),
    'vault_transport','trusted_supabase_queue'
  );
end;
$$;

