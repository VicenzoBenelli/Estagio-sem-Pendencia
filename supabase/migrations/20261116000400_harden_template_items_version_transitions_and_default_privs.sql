-- Gate B1-R2 (R1-01, R1-02, R1-03):
-- Correção incremental sem editar migrations anteriores:
-- 1) R1-01: verificar template de origem e destino separadamente e bloquear troca de template_id em itens.
-- 2) R1-02: validar current_submission_id, current_version e status em todas as transições (inclusive mesmo status) e bloquear revisão de versão antiga.
-- 3) R1-03: revogar EXECUTE padrão GLOBAL (e no schema public) para ROLE postgres.

-- ============================================================================
-- 1. R1-03: Corrigir default privileges GLOBAIS e de schema para ROLE postgres
-- ============================================================================

alter default privileges for role postgres
  revoke execute on functions from public, anon, authenticated;

alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

-- ============================================================================
-- 2. R1-01: Proteção de template ORIGINAL e DESTINO em requirement_template_items
-- ============================================================================

create or replace function public.guard_requirement_template_items_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_status text;
  v_new_status text;
begin
  if tg_op = 'DELETE' then
    select rt.status
      into v_old_status
      from public.requirement_templates as rt
     where rt.id = old.template_id;

    if v_old_status is distinct from 'draft' then
      raise exception 'Itens de template publicado ou arquivado são imutáveis (status origem: %).',
        coalesce(v_old_status, 'ausente')
        using errcode = '42501';
    end if;

    if exists (
      select 1
        from public.process_requirements as pr
       where pr.template_item_id = old.id
    ) then
      raise exception 'Item referenciado por snapshot de processo não pode ser excluído.'
        using errcode = '42501';
    end if;

    return old;
  end if;

  if tg_op = 'INSERT' then
    select rt.status
      into v_new_status
      from public.requirement_templates as rt
     where rt.id = new.template_id;

    if v_new_status is distinct from 'draft' then
      raise exception 'Itens só podem ser inseridos em templates draft (status destino: %).',
        coalesce(v_new_status, 'ausente')
        using errcode = '42501';
    end if;

    return new;
  end if;

  -- UPDATE: validar separadamente origem (OLD.template_id) e destino (NEW.template_id)
  select rt.status
    into v_old_status
    from public.requirement_templates as rt
   where rt.id = old.template_id;

  if v_old_status is distinct from 'draft' then
    raise exception 'Itens de template publicado ou arquivado são imutáveis (status origem: %).',
      coalesce(v_old_status, 'ausente')
      using errcode = '42501';
  end if;

  select rt.status
    into v_new_status
    from public.requirement_templates as rt
   where rt.id = new.template_id;

  if v_new_status is distinct from 'draft' then
    raise exception 'Item não pode ser movido para template não-rascunho (status destino: %).',
      coalesce(v_new_status, 'ausente')
      using errcode = '42501';
  end if;

  if new.template_id is distinct from old.template_id then
    raise exception 'Não é permitido alterar template_id de item existente.'
      using errcode = '42501';
  end if;

  if new.id is distinct from old.id then
    raise exception 'Identificador de item de template é imutável.'
      using errcode = '42501';
  end if;

  if exists (
    select 1
      from public.process_requirements as pr
     where pr.template_item_id = old.id
  ) then
    raise exception 'Item associado a snapshots de processos existentes é imutável.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

-- ============================================================================
-- 3. R1-02: Máquina de estados estrita, proteção de ponteiro/versão e reviews
-- ============================================================================

create or replace function public.guard_process_requirements_immutability()
returns trigger
language plpgsql
security definer
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

  case old.status
    when 'approved' then
      if new.status is distinct from 'approved'
         or new.current_version is distinct from old.current_version
         or new.current_submission_id is distinct from old.current_submission_id then
        raise exception 'Requisito aprovado é terminal e não permite alteração de status, versão ou submissão vigente.'
          using errcode = '42501';
      end if;

    when 'not_submitted' then
      if new.status = 'not_submitted' then
        if new.current_version is distinct from old.current_version
           or new.current_submission_id is distinct from old.current_submission_id then
          raise exception 'Requisito not_submitted não pode alterar versão ou submissão sem transicionar para under_review.'
            using errcode = '42501';
        end if;
      elsif new.status = 'under_review' then
        if new.current_version <> 1 or new.current_submission_id is null then
          raise exception 'Primeira submissão a partir de not_submitted exige current_version = 1 e current_submission_id válido.'
            using errcode = '42501';
        end if;

        if exists (
          select 1
            from public.document_submissions as ds
           where ds.id = new.current_submission_id
             and (
               ds.process_requirement_id is distinct from old.id
               or ds.version <> 1
               or ds.status is distinct from 'under_review'
             )
        ) then
          raise exception 'Submissão inicial incompatível com o requisito ou status under_review.'
            using errcode = '42501';
        end if;
      else
        raise exception 'Transição inválida a partir de not_submitted (% -> %).',
          old.status, new.status
          using errcode = '42501';
      end if;

    when 'under_review' then
      if new.status = 'under_review' then
        if new.current_version is distinct from old.current_version
           or new.current_submission_id is distinct from old.current_submission_id then
          raise exception 'Não é permitido substituir submissão vigente ou alterar versão mantendo status under_review.'
            using errcode = '42501';
        end if;
      elsif new.status in ('approved', 'correction_requested') then
        if new.current_version is distinct from old.current_version
           or new.current_submission_id is distinct from old.current_submission_id then
          raise exception 'Decisão de revisão (% -> %) deve manter ponteiro e versão vigentes inalterados.',
            old.status, new.status
            using errcode = '42501';
        end if;
      else
        raise exception 'Transição inválida a partir de under_review (% -> %).',
          old.status, new.status
          using errcode = '42501';
      end if;

    when 'correction_requested' then
      if new.status = 'correction_requested' then
        if new.current_version is distinct from old.current_version
           or new.current_submission_id is distinct from old.current_submission_id then
          raise exception 'Não é permitido substituir submissão vigente ou versão mantendo status correction_requested.'
            using errcode = '42501';
        end if;
      elsif new.status = 'under_review' then
        if new.current_version <> old.current_version + 1
           or new.current_submission_id is null
           or new.current_submission_id is not distinct from old.current_submission_id then
          raise exception 'Reenvio após correção exige nova versão incremental e nova submissão em análise.'
            using errcode = '42501';
        end if;

        if exists (
          select 1
            from public.document_submissions as ds
           where ds.id = new.current_submission_id
             and (
               ds.process_requirement_id is distinct from old.id
               or ds.version <> new.current_version
               or ds.status is distinct from 'under_review'
             )
        ) then
          raise exception 'Submissão de reenvio incompatível com a nova versão em análise.'
            using errcode = '42501';
        end if;
      else
        raise exception 'Transição inválida a partir de correction_requested (% -> %).',
          old.status, new.status
          using errcode = '42501';
      end if;

    else
      raise exception 'Estado inválido em process_requirements: %.', old.status
        using errcode = '42501';
  end case;

  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.guard_document_reviews_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req record;
  v_sub record;
begin
  select pr.process_id, pr.status, pr.current_submission_id, pr.current_version
    into v_req
    from public.process_requirements as pr
   where pr.id = new.process_requirement_id;

  if not found or v_req.process_id is distinct from new.process_id then
    raise exception 'Requisito incompatível com o processo informado na revisão.'
      using errcode = '23503';
  end if;

  if v_req.status is distinct from 'under_review' then
    raise exception 'Revisão permitida apenas quando o requisito está under_review (status atual: %).',
      v_req.status
      using errcode = '42501';
  end if;

  if v_req.current_submission_id is distinct from new.submission_id then
    raise exception 'Revisão de versão antiga ou não vigente bloqueada.'
      using errcode = '42501';
  end if;

  select ds.process_id, ds.process_requirement_id, ds.version, ds.status
    into v_sub
    from public.document_submissions as ds
   where ds.id = new.submission_id;

  if not found
     or v_sub.process_requirement_id is distinct from new.process_requirement_id
     or v_sub.process_id is distinct from new.process_id
     or v_sub.version is distinct from v_req.current_version
     or v_sub.status is distinct from 'under_review' then
    raise exception 'Submissão inválida, já decidida ou divergente da versão vigente.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_document_reviews_validate_insert on public.document_reviews;
create trigger trg_document_reviews_validate_insert
  after insert on public.document_reviews
  for each row execute function public.guard_document_reviews_insert();

-- Reforçar explicitamente revogação e concessões mínimas após criação das funções
revoke all on all functions in schema public from public, anon, authenticated;

grant execute on function public.is_assigned_reviewer(uuid, uuid, uuid)
  to authenticated, service_role;

grant execute on function public.admin_set_user_role(uuid, text, text, text, text)
  to service_role;

grant execute on function public.admin_assign_reviewer_scope(uuid, uuid, uuid, uuid, text, text, text)
  to service_role;

grant execute on function public.admin_revoke_reviewer_assignment(uuid, text, text, text)
  to service_role;
