-- Avenox Beyin ChatGPT Bridge - Supabase transport schema
-- Trusted ChatGPT Supabase management connector + authenticated local worker.

create extension if not exists pgcrypto;
create schema if not exists private;

create table if not exists public.brain_commands (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text unique not null,
  operation text not null check (operation in (
    'brain_context','brain_note_create','brain_task_create','brain_task_update',
    'brain_receipt','brain_doctor','avenox_bootstrap','avenox_skill_get','brain_source_get'
  )),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','claimed','running','completed','failed','conflict')),
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
  response_kind text not null check (response_kind in ('context','doctor','mutation','bootstrap','skill','source')),
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
returns public.brain_commands
language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=auth.uid(); v_row public.brain_commands;
begin
  if not exists(select 1 from private.bridge_workers w where w.user_id=v_uid and w.enabled) then
    raise exception 'unauthorized worker';
  end if;
  select * into v_row from public.brain_commands
  where status='pending' order by created_at
  for update skip locked limit 1;
  if v_row.id is null then return null; end if;
  update public.brain_commands
  set status='claimed',worker_id=v_uid::text,claimed_at=now(),updated_at=now()
  where id=v_row.id returning * into v_row;
  return v_row;
end;$$;

create or replace function public.finish_brain_command(
  p_id uuid,p_status text,p_result jsonb default null,p_error jsonb default null,
  p_response_text text default null,p_source_refs text[] default array[]::text[],
  p_response_kind text default null)
returns public.brain_commands
language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=auth.uid(); v_row public.brain_commands;
begin
  if not exists(select 1 from private.bridge_workers w where w.user_id=v_uid and w.enabled) then
    raise exception 'unauthorized worker';
  end if;
  if p_status not in ('completed','failed','conflict') then raise exception 'invalid terminal status'; end if;
  if p_status='completed' and p_response_text is not null
     and p_response_kind not in ('context','doctor','mutation','bootstrap','skill','source') then
    raise exception 'invalid response kind';
  end if;

  update public.brain_commands
  set status=p_status,result=p_result,error=p_error,completed_at=now(),updated_at=now()
  where id=p_id and worker_id=v_uid::text and status in ('claimed','running')
  returning * into v_row;
  if v_row.id is null then raise exception 'command not owned by worker or not finishable'; end if;

  if p_status='completed' and p_response_text is not null then
    insert into public.brain_responses(command_id,response_text,source_refs,response_kind)
    values(p_id,p_response_text,coalesce(p_source_refs,array[]::text[]),p_response_kind)
    on conflict(command_id) do update
      set response_text=excluded.response_text,
          source_refs=excluded.source_refs,
          response_kind=excluded.response_kind;
  end if;
  return v_row;
end;$$;

revoke all on function public.claim_next_brain_command() from public,anon;
revoke all on function public.finish_brain_command(uuid,text,jsonb,jsonb,text,text[],text) from public,anon;
grant execute on function public.claim_next_brain_command() to authenticated;
grant execute on function public.finish_brain_command(uuid,text,jsonb,jsonb,text,text[],text) to authenticated;

create or replace function private.brain_result(p_command_id uuid)
returns jsonb
language sql security invoker set search_path=''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'command_id',c.id,
    'status',c.status,
    'response_kind',r.response_kind,
    'source_refs',r.source_refs,
    'response_text',r.response_text,
    'sha256',case when c.operation='brain_source_get' then c.result->>'sha256' end,
    'size_bytes',case when c.operation='brain_source_get' then (c.result->>'size_bytes')::bigint end,
    'source',case when c.operation='brain_source_get' then c.result->>'source' end,
    'error',c.error
  ))
  from public.brain_commands c
  left join public.brain_responses r on r.command_id=c.id
  where c.id=p_command_id;
$$;

create or replace procedure private.brain_execute(
  in p_operation text,
  in p_payload jsonb,
  in p_idempotency_key text,
  in p_timeout_seconds integer,
  in p_poll_ms integer,
  inout p_response jsonb
)
language plpgsql
as $$
declare
  v_id uuid; v_deadline timestamptz; v_status text; v_response_kind text;
  v_source_refs text[]; v_response_text text; v_error jsonb; v_result jsonb;
begin
  if p_operation is null or btrim(p_operation)='' then raise exception 'operation_required'; end if;
  if p_idempotency_key is null or btrim(p_idempotency_key)='' then raise exception 'idempotency_key_required'; end if;
  if p_timeout_seconds is null or p_timeout_seconds<1 or p_timeout_seconds>20 then
    raise exception 'timeout_seconds_must_be_1_to_20';
  end if;
  if p_poll_ms is null or p_poll_ms<100 or p_poll_ms>2000 then
    raise exception 'poll_ms_must_be_100_to_2000';
  end if;

  insert into public.brain_commands(idempotency_key,operation,payload,status,requested_by)
  values(p_idempotency_key,p_operation,coalesce(p_payload,'{}'::jsonb),'pending','chatgpt')
  on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key
  returning id into v_id;

  commit;
  v_deadline:=clock_timestamp()+make_interval(secs=>p_timeout_seconds);

  loop
    select c.status,r.response_kind,r.source_refs,r.response_text,c.error,c.result
      into v_status,v_response_kind,v_source_refs,v_response_text,v_error,v_result
    from public.brain_commands c
    left join public.brain_responses r on r.command_id=c.id
    where c.id=v_id;

    if v_status in ('completed','failed','conflict') then
      p_response:=jsonb_strip_nulls(jsonb_build_object(
        'command_id',v_id,'status',v_status,'response_kind',v_response_kind,
        'source_refs',v_source_refs,'response_text',v_response_text,
        'sha256',case when p_operation='brain_source_get' then v_result->>'sha256' end,
        'size_bytes',case when p_operation='brain_source_get' then (v_result->>'size_bytes')::bigint end,
        'source',case when p_operation='brain_source_get' then v_result->>'source' end,
        'error',v_error
      ));
      return;
    end if;

    if clock_timestamp()>=v_deadline then
      p_response:=jsonb_build_object(
        'command_id',v_id,'status',coalesce(v_status,'pending'),'timed_out',true
      );
      return;
    end if;

    perform pg_sleep(p_poll_ms/1000.0);
  end loop;
end;
$$;

revoke all on function private.brain_result(uuid) from public,anon,authenticated;
revoke all on procedure private.brain_execute(text,jsonb,text,integer,integer,jsonb) from public,anon,authenticated;
