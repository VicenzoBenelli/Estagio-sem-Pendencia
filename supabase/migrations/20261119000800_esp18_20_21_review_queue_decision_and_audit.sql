-- ESP-18 / ESP-20 / ESP-21: Fila paginada do revisor, decisão atômica de revisão
-- e trilha de auditoria consultável por escopo.
-- Não altera migrations anteriores; preserva integralmente constraints, triggers e RLS dos Lotes 1-3.

-- ============================================================================
-- 1. Endurecimento incremental para idempotência de revisão, unicidade de evento e índices
-- ============================================================================

alter table public.document_reviews
  add column if not exists idempotency_key uuid;

create unique index if not exists uq_document_reviews_reviewer_idempotency
  on public.document_reviews (reviewer_id, idempotency_key)
  where idempotency_key is not null;

-- Garantia estrutural de evento único de revisão por registro em document_reviews
create unique index if not exists uq_audit_events_single_document_review
  on public.audit_events (entity_table, entity_id)
  where entity_table = 'document_reviews';

-- Garantia estrutural de evento único de conclusão documental por processo
create unique index if not exists uq_audit_events_process_doc_complete
  on public.audit_events (entity_table, entity_id, event_type)
  where entity_table = 'internship_processes'
    and event_type = 'process_documentally_completed';

-- Índices para fila paginada do revisor (ESP-18) e timeline paginada (ESP-21)
create index if not exists idx_process_requirements_under_review_queue
  on public.process_requirements (process_id, current_submission_id)
  where status = 'under_review' and current_submission_id is not null;

create index if not exists idx_document_submissions_under_review_queue
  on public.document_submissions (submitted_at asc, id asc)
  where status = 'under_review';

create index if not exists idx_audit_events_process_occurred_id
  on public.audit_events (process_id, occurred_at desc, id desc)
  where process_id is not null;

create index if not exists idx_audit_events_occurred_id
  on public.audit_events (occurred_at desc, id desc);

-- ============================================================================
-- 2. ESP-18: View security_invoker da fila de documentos pendentes para revisão
-- ============================================================================

create or replace view public.reviewer_queue_v
with (security_invoker = true) as
select
  ds.id as submission_id,
  pr.id as process_requirement_id,
  ip.id as process_id,
  ip.owner_id as student_id,
  coalesce(nullif(pg_catalog.btrim(sp.full_name), ''), 'Estudante') as student_name,
  ip.institution_id,
  i.code as institution_code,
  i.name as institution_name,
  ip.course_id,
  c.code as course_code,
  c.name as course_name,
  ip.course_modality_id,
  cm.code as modality_code,
  cm.name as modality_name,
  ip.status as process_status,
  ip.opened_at as process_opened_at,
  ip.template_version,
  pr.code as requirement_code,
  pr.title as requirement_title,
  pr.display_order as requirement_display_order,
  pr.is_required,
  pr.status as requirement_status,
  pr.current_version,
  (ds.version > 1) as is_resubmission,
  ds.version as submission_version,
  ds.status as submission_status,
  ds.original_filename,
  ds.size_bytes,
  ds.sha256_checksum,
  ds.storage_bucket,
  ds.storage_path,
  ds.submitted_at,
  ip.is_demo
from public.process_requirements as pr
join public.internship_processes as ip
  on ip.id = pr.process_id
join public.document_submissions as ds
  on ds.id = pr.current_submission_id
 and ds.process_requirement_id = pr.id
 and ds.process_id = ip.id
left join public.institutions as i
  on i.id = ip.institution_id
left join public.courses as c
  on c.id = ip.course_id
left join public.course_modalities as cm
  on cm.id = ip.course_modality_id
left join public.profiles as sp
  on sp.id = ip.owner_id
where ip.status <> 'cancelled'
  and pr.status = 'under_review'
  and pr.current_submission_id is not null
  and ds.status = 'under_review'
  and ds.version = pr.current_version
  and not exists (
    select 1
    from public.document_reviews as dr
    where dr.submission_id = ds.id
  )
  and public.is_assigned_reviewer(
    ip.institution_id,
    ip.course_id,
    ip.course_modality_id
  );

comment on view public.reviewer_queue_v is
  'Fila paginável e filtrável de versões vigentes em under_review dentro do escopo ativo do revisor autenticado (exclui processos cancelados, revisados e versões obsoletas).';

-- ============================================================================
-- 3. ESP-20: RPC transacional autenticada para decisão atômica de revisão
-- ============================================================================

create or replace function public.review_submission(
  p_submission_id uuid,
  p_decision text,
  p_reason text default null,
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_jwt_role text;
  v_profile record;
  v_decision text;
  v_clean_reason text;
  v_sub_lookup record;
  v_req public.process_requirements;
  v_sub public.document_submissions;
  v_process public.internship_processes;
  v_existing_review public.document_reviews;
  v_review public.document_reviews;
  v_progress public.process_progress_v;
  v_required_total integer := 0;
  v_required_approved integer := 0;
  v_became_complete boolean := false;
begin
  -- 1. Sessão autenticada válida obrigatória
  v_user_id := auth.uid();
  v_jwt_role := coalesce(
    nullif(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    auth.role(),
    ''
  );

  if v_user_id is null or v_jwt_role <> 'authenticated' then
    raise exception '[ERR:unauthorized_session] Sessão autenticada válida é obrigatória para registrar revisão.'
      using errcode = '42501';
  end if;

  -- 2. Verificar perfil ativo com papel reviewer antes de consultar entidades
  select p.id, p.role, p.active, p.full_name
    into v_profile
    from public.profiles as p
   where p.id = v_user_id;

  if not found
     or v_profile.active is distinct from true
     or v_profile.role <> 'reviewer' then
    raise exception '[ERR:forbidden_role] Apenas revisor com perfil ativo pode decidir submissões documentais.'
      using errcode = '42501';
  end if;

  -- 3. Validação estrita de entrada e justificativa obrigatória para correção
  if p_submission_id is null then
    raise exception '[ERR:invalid_input] Identificador da submissão é obrigatório.'
      using errcode = '22023';
  end if;

  v_decision := pg_catalog.btrim(coalesce(p_decision, ''));
  if v_decision not in ('approved', 'correction_requested') then
    raise exception '[ERR:invalid_decision] Decisão inválida: utilize approved ou correction_requested.'
      using errcode = '22023';
  end if;

  v_clean_reason := nullif(
    pg_catalog.regexp_replace(
      pg_catalog.regexp_replace(
        coalesce(p_reason, ''),
        E'[\\x01-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]',
        '',
        'g'
      ),
      '^[[:space:]]+|[[:space:]]+$',
      '',
      'g'
    ),
    ''
  );

  if v_decision = 'correction_requested' and v_clean_reason is null then
    raise exception '[ERR:missing_correction_reason] Justificativa obrigatória ao solicitar correção.'
      using errcode = '22023';
  end if;

  if v_clean_reason is not null and pg_catalog.length(v_clean_reason) > 2000 then
    raise exception '[ERR:reason_too_long] Justificativa da revisão excede o limite de 2000 caracteres.'
      using errcode = '22023';
  end if;

  -- 4. Localizar submissão para obter chaves determinísticas de lock
  select ds.id, ds.process_id, ds.process_requirement_id
    into v_sub_lookup
    from public.document_submissions as ds
   where ds.id = p_submission_id;

  if not found then
    raise exception '[ERR:submission_not_found] Submissão documental não encontrada.'
      using errcode = 'P0002';
  end if;

  -- 5. Ordem fixa de locks (advisory processo -> advisory requisito -> requisito -> submissão -> processo)
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_sub_lookup.process_id::text, 20)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_sub_lookup.process_requirement_id::text, 14)
  );

  select pr.*
    into v_req
    from public.process_requirements as pr
   where pr.id = v_sub_lookup.process_requirement_id
   for update;

  select ds.*
    into v_sub
    from public.document_submissions as ds
   where ds.id = p_submission_id
   for update;

  select ip.*
    into v_process
    from public.internship_processes as ip
   where ip.id = v_sub_lookup.process_id
   for update;

  -- 6. Verificar assignment ativo do revisor no escopo antes de qualquer avaliação de estado
  if not public.is_assigned_reviewer(
    v_process.institution_id,
    v_process.course_id,
    v_process.course_modality_id
  ) then
    raise exception '[ERR:forbidden_scope] Revisor não possui atribuição ativa para o escopo deste processo.'
      using errcode = '42501';
  end if;

  -- 7. Processo cancelado não aceita decisão
  if v_process.status = 'cancelled' then
    raise exception '[ERR:process_cancelled] Processo cancelado não permite decisão documental.'
      using errcode = '42501';
  end if;

  -- 8. Tratamento idempotente seguro para retries de rede do mesmo revisor
  if p_idempotency_key is not null then
    select dr.*
      into v_existing_review
      from public.document_reviews as dr
     where dr.reviewer_id = v_user_id
       and dr.idempotency_key = p_idempotency_key
     limit 1;

    if found then
      if v_existing_review.submission_id is distinct from v_sub.id
         or v_existing_review.decision is distinct from v_decision
         or v_existing_review.reason is distinct from v_clean_reason then
        raise exception '[ERR:idempotency_mismatch] Chave de idempotência já associada a outra decisão ou conteúdo.'
          using errcode = '23505';
      end if;

      select ppv.*
        into v_progress
        from public.process_progress_v as ppv
       where ppv.process_id = v_process.id;

      return pg_catalog.jsonb_build_object(
        'ok', true,
        'idempotent_replay', true,
        'review', pg_catalog.to_jsonb(v_existing_review),
        'submission', pg_catalog.to_jsonb(v_sub),
        'requirement', pg_catalog.to_jsonb(v_req),
        'process', pg_catalog.to_jsonb(v_process),
        'progress', pg_catalog.to_jsonb(v_progress)
      );
    end if;
  end if;

  -- 9. Impedir dupla decisão na mesma versão e decisão em versão obsoleta/não vigente
  select dr.*
    into v_existing_review
    from public.document_reviews as dr
   where dr.submission_id = v_sub.id
   limit 1;

  if found then
    raise exception '[ERR:submission_already_reviewed] Esta versão da submissão já recebeu decisão registrada.'
      using errcode = '23505';
  end if;

  if v_req.current_submission_id is distinct from v_sub.id
     or v_sub.version is distinct from v_req.current_version then
    raise exception '[ERR:obsolete_submission_version] Apenas a versão vigente da submissão pode ser revisada.'
      using errcode = '23505';
  end if;

  if v_req.status is distinct from 'under_review'
     or v_sub.status is distinct from 'under_review' then
    raise exception '[ERR:requirement_status_conflict] Requisito ou submissão no status atual não aceita revisão.'
      using errcode = '23505';
  end if;

  -- 10. Registrar revisão imutável primeiro (validações via trg_document_reviews_validate_insert)
  begin
    insert into public.document_reviews (
      process_id,
      process_requirement_id,
      submission_id,
      reviewer_id,
      decision,
      reason,
      idempotency_key
    ) values (
      v_process.id,
      v_req.id,
      v_sub.id,
      v_user_id,
      v_decision,
      v_clean_reason,
      p_idempotency_key
    )
    returning * into v_review;
  exception
    when unique_violation then
      raise exception '[ERR:submission_already_reviewed] Conflito concorrente: esta submissão ou chave já foi registrada.'
        using errcode = '23505';
  end;

  -- 11. Atualizar submissão e requisito na mesma transação (respeitando triggers de imutabilidade)
  update public.document_submissions
     set status = v_decision
   where id = v_sub.id
  returning * into v_sub;

  update public.process_requirements
     set status = v_decision
   where id = v_req.id
  returning * into v_req;

  -- 12. Atualizar estado agregado do processo apenas quando há obrigatórios e todos estão aprovados
  if v_decision = 'approved' and v_process.status = 'in_progress' then
    select
      count(*)::integer,
      count(*) filter (where pr.status = 'approved')::integer
      into v_required_total, v_required_approved
      from public.process_requirements as pr
     where pr.process_id = v_process.id
       and pr.is_required = true;

    if v_required_total > 0 and v_required_approved = v_required_total then
      update public.internship_processes
         set status = 'documentally_complete'
       where id = v_process.id
         and status = 'in_progress'
      returning * into v_process;

      v_became_complete := found;
    end if;
  end if;

  -- 13. Gravar evento único de auditoria da revisão (e transição do processo quando aplicável)
  insert into public.audit_events (
    event_type,
    actor_id,
    actor_role,
    operator_type,
    operator_identifier,
    target_user_id,
    process_id,
    entity_table,
    entity_id,
    metadata,
    occurred_at
  ) values (
    case
      when v_decision = 'approved' then 'document_approved'
      else 'document_correction_requested'
    end,
    v_user_id,
    v_profile.role,
    'user_self_action',
    'rpc:review_submission',
    v_process.owner_id,
    v_process.id,
    'document_reviews',
    v_review.id,
    pg_catalog.jsonb_build_object(
      'review_id', v_review.id,
      'submission_id', v_sub.id,
      'process_requirement_id', v_req.id,
      'requirement_code', v_req.code,
      'requirement_title', v_req.title,
      'is_required', v_req.is_required,
      'version', v_sub.version,
      'decision', v_review.decision,
      'reason', v_review.reason,
      'idempotency_key', p_idempotency_key,
      'process_status', v_process.status,
      'process_became_documentally_complete', v_became_complete,
      'not_official_internship_authorization', true
    ),
    pg_catalog.now()
  );

  if v_became_complete then
    insert into public.audit_events (
      event_type,
      actor_id,
      actor_role,
      operator_type,
      operator_identifier,
      target_user_id,
      process_id,
      entity_table,
      entity_id,
      metadata,
      occurred_at
    ) values (
      'process_documentally_completed',
      v_user_id,
      v_profile.role,
      'user_self_action',
      'rpc:review_submission',
      v_process.owner_id,
      v_process.id,
      'internship_processes',
      v_process.id,
      pg_catalog.jsonb_build_object(
        'triggered_by_review_id', v_review.id,
        'triggered_by_submission_id', v_sub.id,
        'required_total', v_required_total,
        'required_approved', v_required_approved,
        'not_official_internship_authorization', true
      ),
      pg_catalog.clock_timestamp()
    );
  end if;

  select ppv.*
    into v_progress
    from public.process_progress_v as ppv
   where ppv.process_id = v_process.id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'idempotent_replay', false,
    'review', pg_catalog.to_jsonb(v_review),
    'submission', pg_catalog.to_jsonb(v_sub),
    'requirement', pg_catalog.to_jsonb(v_req),
    'process', pg_catalog.to_jsonb(v_process),
    'progress', pg_catalog.to_jsonb(v_progress)
  );
end;
$$;

comment on function public.review_submission(uuid, text, text, uuid) is
  'Registra decisão atômica de revisão (approved ou correction_requested com justificativa obrigatória) exclusivamente por revisor autenticado atribuído ao escopo sobre a versão vigente under_review.';

-- ============================================================================
-- 4. ESP-21: Resolução segura de autor e view paginável da trilha de auditoria
-- ============================================================================

create or replace function public.get_scoped_actor_display_name(
  p_process_id uuid,
  p_actor_id uuid,
  p_actor_role text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_jwt_role text;
  v_uid uuid;
  v_is_privileged boolean := false;
  v_authorized boolean := false;
  v_full_name text;
begin
  if p_process_id is null then
    return null;
  end if;

  v_jwt_role := coalesce(
    nullif(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    auth.role(),
    ''
  );
  v_uid := auth.uid();

  v_is_privileged :=
    v_jwt_role = 'service_role'
    or (
      current_user in ('postgres', 'supabase_admin')
      and v_jwt_role not in ('anon', 'authenticated')
    );

  if not v_is_privileged then
    if v_uid is null or v_jwt_role <> 'authenticated' then
      return null;
    end if;

    select exists (
      select 1
      from public.internship_processes as ip
      where ip.id = p_process_id
        and (
          ip.owner_id = v_uid
          or public.is_assigned_reviewer(
            ip.institution_id,
            ip.course_id,
            ip.course_modality_id
          )
        )
    ) into v_authorized;

    if not v_authorized then
      return null;
    end if;
  end if;

  if p_actor_id is null then
    return 'Sistema';
  end if;

  -- Garante que o ator realmente participou de algum evento do processo autorizado (evita oráculo de perfis)
  if not exists (
    select 1
    from public.audit_events as ae
    where ae.process_id = p_process_id
      and ae.actor_id = p_actor_id
  ) then
    return null;
  end if;

  select nullif(pg_catalog.btrim(p.full_name), '')
    into v_full_name
    from public.profiles as p
   where p.id = p_actor_id;

  return coalesce(
    v_full_name,
    case
      when p_actor_role = 'reviewer' then 'Revisor'
      when p_actor_role = 'student' then 'Estudante'
      else 'Sistema'
    end
  );
end;
$$;

comment on function public.get_scoped_actor_display_name(uuid, uuid, text) is
  'Retorna apenas o nome de exibição do ator participante de eventos de um processo autorizado ao chamador, sem expor e-mail nem permitir enumeração de perfis.';

create or replace view public.process_audit_timeline_v
with (security_invoker = true) as
select
  ae.id as event_id,
  ae.process_id,
  ae.event_type,
  ae.actor_id,
  ae.actor_role,
  public.get_scoped_actor_display_name(ae.process_id, ae.actor_id, ae.actor_role) as actor_display_name,
  ae.target_user_id,
  ae.entity_table,
  ae.entity_id,
  coalesce(
    dr.process_requirement_id,
    ds.process_requirement_id,
    case
      when (ae.metadata ->> 'process_requirement_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (ae.metadata ->> 'process_requirement_id')::uuid
      else null
    end
  ) as process_requirement_id,
  coalesce(pr.code, ae.metadata ->> 'requirement_code') as requirement_code,
  coalesce(pr.title, ae.metadata ->> 'requirement_title') as requirement_title,
  coalesce(dr.submission_id, ds.id) as submission_id,
  coalesce(
    ds.version,
    case
      when (ae.metadata ->> 'version') ~ '^[0-9]+$'
        then (ae.metadata ->> 'version')::integer
      else null
    end
  ) as submission_version,
  coalesce(dr.decision, ae.metadata ->> 'decision') as decision,
  coalesce(dr.reason, ae.metadata ->> 'reason') as reason,
  ip.status as process_status,
  ip.institution_id,
  ip.course_id,
  ip.course_modality_id,
  ae.occurred_at,
  ae.metadata
from public.audit_events as ae
join public.internship_processes as ip
  on ip.id = ae.process_id
left join public.document_reviews as dr
  on ae.entity_table = 'document_reviews'
 and dr.id = ae.entity_id
left join public.document_submissions as ds
  on ds.id = coalesce(
    dr.submission_id,
    case
      when ae.entity_table = 'document_submissions' then ae.entity_id
      else null
    end
  )
left join public.process_requirements as pr
  on pr.id = coalesce(dr.process_requirement_id, ds.process_requirement_id);

comment on view public.process_audit_timeline_v is
  'Timeline imutável e paginável de eventos por processo protegida por RLS do chamador (security_invoker = true).';

-- ============================================================================
-- 5. Privilégios explícitos mínimos (zero acesso para PUBLIC e anon)
-- ============================================================================

revoke all on public.reviewer_queue_v from public, anon, authenticated;
grant select on public.reviewer_queue_v to authenticated, service_role;

revoke all on public.process_audit_timeline_v from public, anon, authenticated;
grant select on public.process_audit_timeline_v to authenticated, service_role;

revoke all on function public.review_submission(uuid, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.review_submission(uuid, text, text, uuid)
  to authenticated;

revoke all on function public.get_scoped_actor_display_name(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.get_scoped_actor_display_name(uuid, uuid, text)
  to authenticated, service_role;
