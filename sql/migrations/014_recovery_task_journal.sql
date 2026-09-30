-- Recovery task journal (schema v11 / bridge API v3).
-- Returns the last 30 compact task/command entries for ChatGPT session recovery without heavy payloads.

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
        when c.operation = 'avenox_bootstrap'
          then coalesce(c.payload->>'task', '')
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

revoke all on function public.get_recent_task_journal(integer) from public,anon;
grant execute on function public.get_recent_task_journal(integer) to authenticated;

notify pgrst, 'reload schema';
