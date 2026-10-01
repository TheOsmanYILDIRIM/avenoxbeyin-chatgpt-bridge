-- 019_long_poll_transport.sql
-- Reduce idle worker claims and ChatGPT result polling.

begin;

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

commit;
