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

  if v <> 10 then
    raise exception 'expected transport schema 10, got %', v;
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
end
$;

insert into public.brain_commands(operation,payload,requested_by)
values
  ('brain_vault_list','{}'::jsonb,'sql-smoke'),
  ('brain_vault_get','{}'::jsonb,'sql-smoke'),
  ('brain_vault_update','{}'::jsonb,'sql-smoke');

delete from public.brain_commands where requested_by='sql-smoke';
