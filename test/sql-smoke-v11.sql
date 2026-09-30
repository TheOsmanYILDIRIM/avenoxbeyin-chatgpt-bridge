\set ON_ERROR_STOP on

do $$
begin
  create role anon nologin;
exception when duplicate_object then null;
end
$$;

do $$
begin
  create role authenticated nologin;
exception when duplicate_object then null;
end
$$;

create schema if not exists auth;

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select null::uuid;
$$;

\i sql/schema.sql

do $$
declare
  v integer;
begin
  select schema_version into v
  from private.bridge_transport_meta
  where singleton=true;

  if v <> 11 then
    raise exception 'expected transport schema 11, got %', v;
  end if;

  if to_regprocedure('public.bridge_transport_contract()') is null then
    raise exception 'missing bridge_transport_contract()';
  end if;

  if to_regprocedure('public.claim_next_brain_command_v2()') is null then
    raise exception 'missing claim_next_brain_command_v2()';
  end if;

  if to_regprocedure('public.finish_brain_command_v2(jsonb)') is null then
    raise exception 'missing finish_brain_command_v2(jsonb)';
  end if;

  if to_regprocedure('public.get_recent_task_journal(integer)') is null then
    raise exception 'missing get_recent_task_journal(integer)';
  end if;

  if to_regprocedure('public.open_chatgpt_turn(text,text,text)') is null then
    raise exception 'missing open_chatgpt_turn(text,text,text)';
  end if;

  if to_regprocedure('public.finalize_chatgpt_turn(text,boolean,text,text[])') is null then
    raise exception 'missing finalize_chatgpt_turn(text,boolean,text,text[])';
  end if;
end
$$;

insert into public.brain_commands(operation,payload,requested_by)
values
  ('avenox_turn_context','{"task":"test-task","project":"test-proj"}'::jsonb,'sql-smoke-v11'),
  ('avenox_turn_finalize','{"turn_id":"turn-123","state_changed":false,"summary":"test","refs":[]}'::jsonb,'sql-smoke-v11'),
  ('brain_vault_list','{}'::jsonb,'sql-smoke-v11'),
  ('brain_vault_find','{"query":"study"}'::jsonb,'sql-smoke-v11'),
  ('brain_vault_search','{"query":"study"}'::jsonb,'sql-smoke-v11'),
  ('brain_vault_read_range','{"source":"Threads.md","start_line":1,"end_line":10}'::jsonb,'sql-smoke-v11'),
  ('brain_vault_get','{"source":"Threads.md"}'::jsonb,'sql-smoke-v11'),
  ('brain_vault_update','{"source":"Threads.md","expected_sha256":"x","content":"y"}'::jsonb,'sql-smoke-v11');

delete from public.brain_commands where requested_by='sql-smoke-v11';
