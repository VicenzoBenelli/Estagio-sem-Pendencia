-- Gate B1-R1 (C1-03, C1-04, C1-05, C1-06):
-- Endurecimento incremental de integridade referencial, imutabilidade histórica,
-- privilégios de funções e rastreabilidade verificável do operador administrativo.

-- ============================================================================
-- 1. C1-03: Integridade referencial de templates, versões e origem do snapshot
-- ============================================================================

alter table public.requirement_templates
  add constraint uq_requirement_templates_scope
  unique (id, version, institution_id, course_id, course_modality_id);

alter table public.internship_processes
  drop constraint if exists fk_internship_processes_template_version,
  add constraint fk_internship_processes_template_scope
  foreign key (template_id, template_version, institution_id, course_id, course_modality_id)
  references public.requirement_templates (id, version, institution_id, course_id, course_modality_id)
  on delete restrict;

alter table public.document_submissions
  add constraint uq_document_submissions_id_req_version
  unique (id, process_requirement_id, version);

alter table public.process_requirements
  drop constraint if exists fk_process_requirements_current_submission,
  add constraint fk_process_requirements_current_submission
  foreign key (current_submission_id, id, current_version)
  references public.document_submissions (id, process_requirement_id, version)
  on delete restrict
  deferrable initially deferred;

create or replace function public.validate_internship_process_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_template_status text;
begin
  select rt.status
    into v_template_status
    from public.requirement_templates as rt
   where rt.id = new.template_id
     and rt.version = new.template_version;

  if v_template_status is distinct from 'published' then
    raise exception 'Processo só pode ser aberto com template publicado (status atual: %).',
      coalesce(v_template_status, 'ausente')
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger trg_internship_processes_validate_insert
  before insert on public.internship_processes
  for each row execute function public.validate_internship_process_insert();

create or replace function public.validate_process_requirement_origin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_process_template_id uuid;
  v_item_template_id uuid;
begin
  select ip.template_id
    into v_process_template_id
    from public.internship_processes as ip
   where ip.id = new.process_id;

  select rti.template_id
    into v_item_template_id
    from public.requirement_template_items as rti
   where rti.id = new.template_item_id;

  if v_process_template_id is null
     or v_item_template_id is null
     or v_item_template_id is distinct from v_process_template_id then
    raise exception 'Item de requisito (%) incompatível com o template (%) do processo (%).',
      new.template_item_id, v_process_template_id, new.process_id
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger trg_process_requirements_validate_origin
  before insert or update of process_id, template_item_id on public.process_requirements
  for each row execute function public.validate_process_requirement_origin();

-- ============================================================================
-- 2. C1-04: Imutabilidade histórica (proteção inclusive contra credenciais operacionais)
-- ============================================================================

create or replace function public.guard_requirement_templates_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_item_count integer;
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then
      raise exception 'Templates publicados ou arquivados não podem ser excluídos.'
        using errcode = '42501';
    end if;
    return old;
  end if;

  if old.status = 'draft' then
    if new.status = 'published' then
      select count(*)::integer
        into v_item_count
        from public.requirement_template_items as rti
       where rti.template_id = old.id;

      if v_item_count < 1 then
        raise exception 'Template não pode ser publicado sem itens configurados.'
          using errcode = '23514';
      end if;

      new.published_at := coalesce(new.published_at, now());
    elsif new.status = 'archived' then
      raise exception 'Template em rascunho não pode ir diretamente para archived.'
        using errcode = '23514';
    end if;

    new.updated_at := now();
    return new;
  end if;

  if old.status = 'published' then
    if new.status <> 'archived'
       or new.id is distinct from old.id
       or new.institution_id is distinct from old.institution_id
       or new.course_id is distinct from old.course_id
       or new.course_modality_id is distinct from old.course_modality_id
       or new.version is distinct from old.version
       or new.title is distinct from old.title
       or new.source_reference is distinct from old.source_reference
       or new.is_demo is distinct from old.is_demo
       or new.published_at is distinct from old.published_at
       or new.created_at is distinct from old.created_at then
      raise exception 'Conteúdo de template publicado é imutável; apenas arquivamento (status = archived) é permitido.'
        using errcode = '42501';
    end if;
    new.updated_at := now();
    return new;
  end if;

  raise exception 'Template arquivado é estritamente imutável.'
    using errcode = '42501';
end;
$$;

create trigger trg_requirement_templates_immutability
  before update or delete on public.requirement_templates
  for each row execute function public.guard_requirement_templates_immutability();

create or replace function public.guard_requirement_template_items_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_template_id uuid;
  v_status text;
begin
  v_template_id := coalesce(new.template_id, old.template_id);

  select rt.status
    into v_status
    from public.requirement_templates as rt
   where rt.id = v_template_id;

  if v_status is distinct from 'draft' then
    raise exception 'Itens de template publicado ou arquivado são imutáveis (status: %).',
      coalesce(v_status, 'ausente')
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger trg_requirement_template_items_immutability
  before insert or update or delete on public.requirement_template_items
  for each row execute function public.guard_requirement_template_items_immutability();

create or replace function public.guard_internship_processes_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.owner_id is distinct from old.owner_id
     or new.institution_id is distinct from old.institution_id
     or new.course_id is distinct from old.course_id
     or new.course_modality_id is distinct from old.course_modality_id
     or new.template_id is distinct from old.template_id
     or new.template_version is distinct from old.template_version
     or new.is_demo is distinct from old.is_demo
     or new.opened_at is distinct from old.opened_at
     or new.created_at is distinct from old.created_at then
    raise exception 'Identidade, escopo e versão de template do processo são imutáveis.'
      using errcode = '42501';
  end if;

  if old.status = 'cancelled' and new.status is distinct from 'cancelled' then
    raise exception 'Processo cancelado não pode ser reaberto.'
      using errcode = '42501';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_internship_processes_immutability
  before update on public.internship_processes
  for each row execute function public.guard_internship_processes_immutability();

create or replace function public.guard_process_requirements_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.process_id is distinct from old.process_id
     or new.template_item_id is distinct from old.template_item_id
     or new.code is distinct from old.code
     or new.title is distinct from old.title
     or new.description is distinct from old.description
     or new.acceptance_criteria is distinct from old.acceptance_criteria
     or new.is_required is distinct from old.is_required
     or new.display_order is distinct from old.display_order
     or new.created_at is distinct from old.created_at then
    raise exception 'Snapshot de requisito do processo é imutável.'
      using errcode = '42501';
  end if;

  if new.current_version < old.current_version then
    raise exception 'Versão vigente do requisito não pode regredir.'
      using errcode = '42501';
  end if;

  if old.status = 'approved'
     and (
       new.status is distinct from 'approved'
       or new.current_version is distinct from old.current_version
       or new.current_submission_id is distinct from old.current_submission_id
     ) then
    raise exception 'Requisito aprovado não pode ser alterado sem regra explícita.'
      using errcode = '42501';
  end if;

  if old.status = 'not_submitted' and new.status <> 'not_submitted' then
    if new.status <> 'under_review' or new.current_version <> 1 or new.current_submission_id is null then
      raise exception 'Transição inválida a partir de not_submitted.'
        using errcode = '42501';
    end if;
  elsif old.status = 'under_review' and new.status <> 'under_review' then
    if new.status not in ('approved', 'correction_requested')
       or new.current_version is distinct from old.current_version
       or new.current_submission_id is distinct from old.current_submission_id then
      raise exception 'Transição inválida a partir de under_review.'
        using errcode = '42501';
    end if;
  elsif old.status = 'correction_requested' and new.status <> 'correction_requested' then
    if new.status <> 'under_review'
       or new.current_version <> old.current_version + 1
       or new.current_submission_id is null
       or new.current_submission_id is not distinct from old.current_submission_id then
      raise exception 'Reenvio após correção exige nova versão e nova submissão em análise.'
        using errcode = '42501';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_process_requirements_immutability
  before update on public.process_requirements
  for each row execute function public.guard_process_requirements_immutability();

create or replace function public.guard_document_submissions_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.process_id is distinct from old.process_id
     or new.process_requirement_id is distinct from old.process_requirement_id
     or new.submitted_by is distinct from old.submitted_by
     or new.version is distinct from old.version
     or new.storage_bucket is distinct from old.storage_bucket
     or new.storage_path is distinct from old.storage_path
     or new.original_filename is distinct from old.original_filename
     or new.mime_type is distinct from old.mime_type
     or new.size_bytes is distinct from old.size_bytes
     or new.sha256_checksum is distinct from old.sha256_checksum
     or new.submitted_at is distinct from old.submitted_at
     or new.created_at is distinct from old.created_at then
    raise exception 'Metadados históricos, storage_path, checksum e versão da submissão são imutáveis.'
      using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    if old.status <> 'under_review' or new.status not in ('approved', 'correction_requested') then
      raise exception 'Transição inválida de status da submissão (% -> %).', old.status, new.status
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

create trigger trg_document_submissions_immutability
  before update on public.document_submissions
  for each row execute function public.guard_document_submissions_immutability();

-- ============================================================================
-- 3. C1-06: Identidade verificável e auditável do operador administrativo
-- ============================================================================

alter table public.audit_events
  add column if not exists operator_type text not null default 'system',
  add column if not exists operator_identifier text not null default 'legacy_bootstrap';

alter table public.audit_events
  drop constraint if exists chk_audit_events_operator_type,
  add constraint chk_audit_events_operator_type
  check (
    operator_type in (
      'user_self_action',
      'verified_human_operator',
      'technical_automation',
      'local_demo_provisioning',
      'system'
    )
  );

alter table public.audit_events
  drop constraint if exists chk_audit_events_operator_identifier_nonempty,
  add constraint chk_audit_events_operator_identifier_nonempty
  check (length(btrim(operator_identifier)) > 0);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_full_name text;
begin
  v_full_name := nullif(
    left(btrim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), 120),
    ''
  );

  -- Cadastro público SEMPRE resulta em 'student'; qualquer role enviada no metadata é ignorada.
  insert into public.profiles (id, email, full_name, role, active)
  values (
    new.id,
    coalesce(nullif(btrim(new.email), ''), new.id::text || '@sem-email.local'),
    v_full_name,
    'student',
    true
  );

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
    metadata
  ) values (
    'profile_created',
    new.id,
    'student',
    'user_self_action',
    'auth_signup',
    new.id,
    null,
    'profiles',
    new.id,
    jsonb_build_object('assigned_role', 'student')
  );

  return new;
end;
$$;

create or replace function public._resolve_privileged_operator(
  p_operator_type text,
  p_operator_identifier text,
  p_reason text,
  out out_actor_id uuid,
  out out_actor_role text,
  out out_operator_type text,
  out out_operator_identifier text,
  out out_reason text,
  out out_jwt_role text
)
returns record
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_verified_uid uuid;
  v_profile public.profiles;
  v_trimmed_identifier text;
begin
  out_jwt_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    auth.role(),
    ''
  );

  if out_jwt_role in ('anon', 'authenticated')
     or (
       out_jwt_role <> 'service_role'
       and session_user not in ('postgres', 'supabase_admin')
     ) then
    raise exception 'Contexto privilegiado obrigatório para operação administrativa.'
      using errcode = '42501';
  end if;

  out_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if out_reason is null or length(out_reason) < 5 then
    raise exception 'Justificativa administrativa obrigatória (mínimo de 5 caracteres).'
      using errcode = '22023';
  end if;

  out_operator_type := btrim(coalesce(p_operator_type, ''));
  v_trimmed_identifier := btrim(coalesce(p_operator_identifier, ''));

  if out_operator_type = 'verified_human_operator' then
    v_verified_uid := auth.uid();
    if v_verified_uid is null then
      raise exception 'Operador humano exige sub verificado no contexto de autenticação (UUID arbitrário não é aceito).'
        using errcode = '42501';
    end if;

    select *
      into v_profile
      from public.profiles
     where id = v_verified_uid
       and active = true;

    if not found then
      raise exception 'Perfil ativo não encontrado para operador humano verificado.'
        using errcode = '42501';
    end if;

    if v_trimmed_identifier <> ''
       and v_trimmed_identifier <> v_verified_uid::text
       and lower(v_trimmed_identifier) <> lower(v_profile.email) then
      raise exception 'Identificador informado diverge do operador humano autenticado.'
        using errcode = '42501';
    end if;

    out_actor_id := v_verified_uid;
    out_actor_role := v_profile.role;
    out_operator_identifier := 'verified_profile:' || v_verified_uid::text;
    return;
  elsif out_operator_type in ('technical_automation', 'local_demo_provisioning') then
    if length(v_trimmed_identifier) < 3 or v_trimmed_identifier like 'verified_profile:%' then
      raise exception 'Identificador de automação/provisionamento inválido ou ausente.'
        using errcode = '22023';
    end if;

    out_actor_id := null;
    out_actor_role := coalesce(nullif(out_jwt_role, ''), session_user::text);
    out_operator_identifier := v_trimmed_identifier;
    return;
  end if;

  raise exception 'Tipo de operador administrativo inválido: %.', coalesce(p_operator_type, 'NULL')
    using errcode = '22023';
end;
$$;

-- Remover assinaturas anteriores que aceitavam p_actor_id arbitrário
drop function if exists public.admin_set_user_role(uuid, text, uuid, text);
drop function if exists public.admin_assign_reviewer_scope(uuid, uuid, uuid, uuid, uuid, text);
drop function if exists public.admin_revoke_reviewer_assignment(uuid, uuid, text);

create function public.admin_set_user_role(
  p_user_id uuid,
  p_new_role text,
  p_operator_type text,
  p_operator_identifier text,
  p_reason text
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op record;
  v_profile public.profiles;
  v_old_role text;
  v_revoked_row public.reviewer_assignments;
begin
  select *
    into v_op
    from public._resolve_privileged_operator(p_operator_type, p_operator_identifier, p_reason);

  if p_new_role not in ('student', 'reviewer') then
    raise exception 'Papel inválido: %.', p_new_role
      using errcode = '22023';
  end if;

  select *
    into v_profile
    from public.profiles
   where id = p_user_id
   for update;

  if not found then
    raise exception 'Perfil % não encontrado.', p_user_id
      using errcode = 'P0002';
  end if;

  v_old_role := v_profile.role;

  if v_old_role = p_new_role then
    return v_profile;
  end if;

  perform set_config('estagio.privileged_op', 'on', true);

  if v_old_role = 'reviewer' and p_new_role = 'student' then
    for v_revoked_row in
      update public.reviewer_assignments
         set active = false,
             revoked_at = now(),
             revoked_by = v_op.out_actor_id,
             revocation_reason = v_op.out_reason,
             updated_at = now()
       where reviewer_id = p_user_id
         and active = true
      returning *
    loop
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
        metadata
      ) values (
        'reviewer_assignment_revoked',
        v_op.out_actor_id,
        v_op.out_actor_role,
        v_op.out_operator_type,
        v_op.out_operator_identifier,
        p_user_id,
        null,
        'reviewer_assignments',
        v_revoked_row.id,
        jsonb_build_object(
          'institution_id', v_revoked_row.institution_id,
          'course_id', v_revoked_row.course_id,
          'course_modality_id', v_revoked_row.course_modality_id,
          'reason', v_revoked_row.revocation_reason,
          'db_session_user', session_user::text,
          'jwt_role', v_op.out_jwt_role
        )
      );
    end loop;
  end if;

  update public.profiles
     set role = p_new_role,
         updated_at = now()
   where id = p_user_id
  returning * into v_profile;

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
    metadata
  ) values (
    'user_role_changed',
    v_op.out_actor_id,
    v_op.out_actor_role,
    v_op.out_operator_type,
    v_op.out_operator_identifier,
    p_user_id,
    null,
    'profiles',
    p_user_id,
    jsonb_build_object(
      'previous_role', v_old_role,
      'new_role', p_new_role,
      'reason', v_op.out_reason,
      'db_session_user', session_user::text,
      'jwt_role', v_op.out_jwt_role
    )
  );

  return v_profile;
end;
$$;

create function public.admin_assign_reviewer_scope(
  p_reviewer_id uuid,
  p_institution_id uuid,
  p_course_id uuid,
  p_course_modality_id uuid,
  p_operator_type text,
  p_operator_identifier text,
  p_reason text
)
returns public.reviewer_assignments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op record;
  v_profile public.profiles;
  v_assignment public.reviewer_assignments;
begin
  select *
    into v_op
    from public._resolve_privileged_operator(p_operator_type, p_operator_identifier, p_reason);

  select *
    into v_profile
    from public.profiles
   where id = p_reviewer_id
   for update;

  if not found then
    raise exception 'Perfil % não encontrado.', p_reviewer_id
      using errcode = 'P0002';
  end if;

  if v_profile.role <> 'reviewer' or v_profile.active is distinct from true then
    raise exception 'Usuário % precisa estar ativo e com papel reviewer antes da atribuição.', p_reviewer_id
      using errcode = '42501';
  end if;

  insert into public.reviewer_assignments (
    reviewer_id,
    institution_id,
    course_id,
    course_modality_id,
    active,
    assigned_by
  ) values (
    p_reviewer_id,
    p_institution_id,
    p_course_id,
    p_course_modality_id,
    true,
    v_op.out_actor_id
  )
  returning * into v_assignment;

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
    metadata
  ) values (
    'reviewer_assignment_created',
    v_op.out_actor_id,
    v_op.out_actor_role,
    v_op.out_operator_type,
    v_op.out_operator_identifier,
    p_reviewer_id,
    null,
    'reviewer_assignments',
    v_assignment.id,
    jsonb_build_object(
      'institution_id', p_institution_id,
      'course_id', p_course_id,
      'course_modality_id', p_course_modality_id,
      'reason', v_op.out_reason,
      'db_session_user', session_user::text,
      'jwt_role', v_op.out_jwt_role
    )
  );

  return v_assignment;
end;
$$;

create function public.admin_revoke_reviewer_assignment(
  p_assignment_id uuid,
  p_operator_type text,
  p_operator_identifier text,
  p_reason text
)
returns public.reviewer_assignments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op record;
  v_assignment public.reviewer_assignments;
begin
  select *
    into v_op
    from public._resolve_privileged_operator(p_operator_type, p_operator_identifier, p_reason);

  update public.reviewer_assignments
     set active = false,
         revoked_at = now(),
         revoked_by = v_op.out_actor_id,
         revocation_reason = v_op.out_reason,
         updated_at = now()
   where id = p_assignment_id
     and active = true
  returning * into v_assignment;

  if not found then
    raise exception 'Atribuição ativa % não encontrada.', p_assignment_id
      using errcode = 'P0002';
  end if;

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
    metadata
  ) values (
    'reviewer_assignment_revoked',
    v_op.out_actor_id,
    v_op.out_actor_role,
    v_op.out_operator_type,
    v_op.out_operator_identifier,
    v_assignment.reviewer_id,
    null,
    'reviewer_assignments',
    v_assignment.id,
    jsonb_build_object(
      'institution_id', v_assignment.institution_id,
      'course_id', v_assignment.course_id,
      'course_modality_id', v_assignment.course_modality_id,
      'reason', v_assignment.revocation_reason,
      'db_session_user', session_user::text,
      'jwt_role', v_op.out_jwt_role
    )
  );

  return v_assignment;
end;
$$;

-- ============================================================================
-- 4. C1-05: Revogação explícita de EXECUTE sobre todas as funções e padrão futuro
-- ============================================================================

revoke all on all functions in schema public from public, anon, authenticated;

alter default privileges in schema public
  revoke all on functions from public, anon, authenticated;

alter default privileges in schema public
  revoke all on tables from public, anon, authenticated;

alter default privileges in schema public
  revoke all on sequences from public, anon, authenticated;

grant execute on function public.is_assigned_reviewer(uuid, uuid, uuid)
  to authenticated, service_role;

grant execute on function public.admin_set_user_role(uuid, text, text, text, text)
  to service_role;

grant execute on function public.admin_assign_reviewer_scope(uuid, uuid, uuid, uuid, text, text, text)
  to service_role;

grant execute on function public.admin_revoke_reviewer_assignment(uuid, text, text, text)
  to service_role;
