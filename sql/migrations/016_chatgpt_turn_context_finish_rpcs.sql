-- Update finish RPC response_kind validation to accept 'turn_context' (schema v11 / bridge API v3).

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

revoke all on function public.finish_brain_command(uuid,text,jsonb,jsonb,text,text[],text) from public,anon;
revoke all on function public.finish_brain_command_v2(jsonb) from public,anon;
grant execute on function public.finish_brain_command(uuid,text,jsonb,jsonb,text,text[],text) to authenticated;
grant execute on function public.finish_brain_command_v2(jsonb) to authenticated;

notify pgrst, 'reload schema';
