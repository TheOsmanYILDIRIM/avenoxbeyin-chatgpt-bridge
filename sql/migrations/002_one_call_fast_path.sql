-- Upgrade an existing bridge with the private one-call fast path.
-- Existing public.brain_commands / public.brain_responses are required.

create schema if not exists private;

create or replace function private.brain_result(p_command_id uuid)
returns jsonb
language sql security invoker set search_path=''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'command_id',c.id,'status',c.status,'response_kind',r.response_kind,
    'source_refs',r.source_refs,'response_text',r.response_text,
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
  in p_operation text,in p_payload jsonb,in p_idempotency_key text,
  in p_timeout_seconds integer,in p_poll_ms integer,inout p_response jsonb
)
language plpgsql
as $$
declare
  v_id uuid; v_deadline timestamptz; v_status text; v_response_kind text;
  v_source_refs text[]; v_response_text text; v_error jsonb; v_result jsonb;
begin
  if p_operation is null or btrim(p_operation)='' then raise exception 'operation_required'; end if;
  if p_idempotency_key is null or btrim(p_idempotency_key)='' then raise exception 'idempotency_key_required'; end if;
  if p_timeout_seconds is null or p_timeout_seconds<1 or p_timeout_seconds>20 then raise exception 'timeout_seconds_must_be_1_to_20'; end if;
  if p_poll_ms is null or p_poll_ms<100 or p_poll_ms>2000 then raise exception 'poll_ms_must_be_100_to_2000'; end if;

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
      p_response:=jsonb_build_object('command_id',v_id,'status',coalesce(v_status,'pending'),'timed_out',true);
      return;
    end if;

    perform pg_sleep(p_poll_ms/1000.0);
  end loop;
end;
$$;

revoke all on function private.brain_result(uuid) from public,anon,authenticated;
revoke all on procedure private.brain_execute(text,jsonb,text,integer,integer,jsonb) from public,anon,authenticated;
