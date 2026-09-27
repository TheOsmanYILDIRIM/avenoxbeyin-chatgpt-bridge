-- Avenox Beyin ChatGPT Bridge - Supabase transport schema
-- ChatGPT writes commands through the trusted Supabase connector.
-- The local worker authenticates with a dedicated Supabase Auth user.

create extension if not exists pgcrypto;
create schema if not exists private;

create table if not exists public.brain_commands (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text unique not null,
  operation text not null check (operation in (
    'avenox_bootstrap','avenox_skill_get',
    'brain_context','brain_source_get','brain_source_update',
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
    check (response_kind in ('context','doctor','mutation','bootstrap','skill','source')),
  created_at timestamptz not null default now()
);

create table if not exists private.bridge_workers (
  user_id uuid primary key,
  worker_name text unique not null,
  enabled boolean not null default true,
  last_seen_at timestamptz,
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
as $
declare
  v_uid uuid := auth.uid();
  v_worker text;
begin
  select w.worker_name into v_worker
  from private.bridge_workers w
  where w.user_id=v_uid and w.enabled;

  if v_worker is null then
    raise exception 'unauthorized worker';
  end if;

  update private.bridge_workers
  set last_seen_at=now()
  where user_id=v_uid and enabled;

  return query
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
  returning c.*;
end;
$;

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


create or replace function private.brain_worker_status(
  p_stale_after_seconds integer default 20
)
returns jsonb
language sql
security invoker
set search_path=''
as $
  select coalesce(
    (
      select jsonb_strip_nulls(jsonb_build_object(
        'worker_name', w.worker_name,
        'enabled', w.enabled,
        'last_seen_at', w.last_seen_at,
        'heartbeat_age_seconds',
          case
            when w.last_seen_at is null then null
            else greatest(0, floor(extract(epoch from (clock_timestamp() - w.last_seen_at))))::bigint
          end,
        'stale_after_seconds', greatest(coalesce(p_stale_after_seconds, 20), 5),
        'online',
          coalesce(
            w.last_seen_at >= clock_timestamp() - make_interval(
              secs => greatest(coalesce(p_stale_after_seconds, 20), 5)
            ),
            false
          )
      ))
      from private.bridge_workers w
      where w.enabled
      order by w.last_seen_at desc nulls last, w.created_at desc
      limit 1
    ),
    jsonb_build_object(
      'online', false,
      'reason', 'no_enabled_worker',
      'stale_after_seconds', greatest(coalesce(p_stale_after_seconds, 20), 5)
    )
  );
$;

revoke all on function private.brain_worker_status(integer)
  from public,anon,authenticated;

create or replace function private.brain_capabilities()
returns jsonb
language sql
security invoker
set search_path=''
as $$
  select jsonb_build_object(
    'bridge_api_version',2,
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
