-- ESP-10 / ESP-11: Abertura transacional segura de processo de estágio e snapshot versionado de checklist.
-- Não altera migrations anteriores nem concede escrita direta às tabelas para usuários comuns.

-- 1. Índice auxiliar para leitura ordenada do snapshot por requisito do processo
create index if not exists idx_process_requirements_process_order
  on public.process_requirements (process_id, display_order);

-- 2. RPC transacional de abertura de processo com snapshot atômico e trilha de auditoria
create or replace function public.create_internship_process(
  p_course_modality_id uuid
)
returns public.internship_processes
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_jwt_role text;
  v_profile record;
  v_scope record;
  v_template record;
  v_process public.internship_processes;
  v_snapshot_count integer := 0;
  v_required_count integer := 0;
begin
  -- 1. Sessão autenticada válida obrigatória
  v_user_id := auth.uid();
  v_jwt_role := coalesce(
    nullif(pg_catalog.current_setting('request.jwt.claim.role', true), ''),
    auth.role(),
    ''
  );

  if v_user_id is null or v_jwt_role <> 'authenticated' then
    raise exception 'Sessão autenticada válida é obrigatória para abrir processo de estágio.'
      using errcode = '42501';
  end if;

  if p_course_modality_id is null then
    raise exception 'Identificador da modalidade de estágio é obrigatório.'
      using errcode = '22023';
  end if;

  -- 2. Serializar tentativas concorrentes do mesmo estudante na mesma modalidade
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text || ':' || p_course_modality_id::text, 0)
  );

  -- 3. Confirmar perfil ativo com papel student (owner_id deriva exclusivamente de auth.uid())
  select p.id, p.role, p.active
    into v_profile
    from public.profiles as p
   where p.id = v_user_id;

  if not found then
    raise exception 'Perfil do usuário não encontrado.'
      using errcode = '42501';
  end if;

  if v_profile.active is distinct from true then
    raise exception 'Perfil inativo não pode abrir processo de estágio.'
      using errcode = '42501';
  end if;

  if v_profile.role <> 'student' then
    raise exception 'Apenas estudantes com perfil ativo podem abrir processo de estágio.'
      using errcode = '42501';
  end if;

  -- 4. Derivar instituição e curso no banco e validar catálogo ativo
  select
    cm.id as modality_id,
    cm.active as modality_active,
    cm.is_demo as modality_is_demo,
    c.id as course_id,
    c.active as course_active,
    c.is_demo as course_is_demo,
    i.id as institution_id,
    i.active as institution_active,
    i.is_demo as institution_is_demo
  into v_scope
  from public.course_modalities as cm
  join public.courses as c
    on c.id = cm.course_id
  join public.institutions as i
    on i.id = c.institution_id
  where cm.id = p_course_modality_id;

  if not found then
    raise exception 'Modalidade de estágio não encontrada.'
      using errcode = 'P0002';
  end if;

  if v_scope.institution_active is distinct from true
     or v_scope.course_active is distinct from true
     or v_scope.modality_active is distinct from true then
    raise exception 'Instituição, curso ou modalidade inativos para abertura de processo.'
      using errcode = '23514';
  end if;

  -- 5. Impedir duplicidade de processo ativo para o mesmo estudante, curso e modalidade
  if exists (
    select 1
      from public.internship_processes as ip
     where ip.owner_id = v_user_id
       and ip.course_id = v_scope.course_id
       and ip.course_modality_id = v_scope.modality_id
       and ip.status <> 'cancelled'
  ) then
    raise exception 'Já existe um processo ativo para este estudante neste curso e modalidade.'
      using errcode = '23505';
  end if;

  -- 6. Localizar exclusivamente o template published correspondente à modalidade
  select rt.id, rt.version, rt.is_demo
    into v_template
    from public.requirement_templates as rt
   where rt.institution_id = v_scope.institution_id
     and rt.course_id = v_scope.course_id
     and rt.course_modality_id = v_scope.modality_id
     and rt.status = 'published'
   order by rt.version desc
   limit 1;

  if not found then
    raise exception 'Nenhum checklist publicado está configurado para a modalidade selecionada.'
      using errcode = '23514';
  end if;

  -- 7. Criar processo atomicamente (mantendo garantia estrutural contra duplicidade)
  begin
    insert into public.internship_processes (
      owner_id,
      institution_id,
      course_id,
      course_modality_id,
      template_id,
      template_version,
      status,
      is_demo
    ) values (
      v_user_id,
      v_scope.institution_id,
      v_scope.course_id,
      v_scope.modality_id,
      v_template.id,
      v_template.version,
      'in_progress',
      (
        v_scope.institution_is_demo
        or v_scope.course_is_demo
        or v_scope.modality_is_demo
        or v_template.is_demo
      )
    )
    returning * into v_process;
  exception
    when unique_violation then
      raise exception 'Já existe um processo ativo para este estudante neste curso e modalidade.'
        using errcode = '23505';
  end;

  -- 8. Gerar snapshot versionado dos requisitos do template publicado
  with inserted_snapshot as (
    insert into public.process_requirements (
      process_id,
      template_item_id,
      code,
      title,
      description,
      acceptance_criteria,
      is_required,
      display_order,
      status,
      current_submission_id,
      current_version
    )
    select
      v_process.id,
      rti.id,
      rti.code,
      rti.title,
      rti.description,
      rti.acceptance_criteria,
      rti.is_required,
      rti.display_order,
      'not_submitted',
      null,
      0
    from public.requirement_template_items as rti
    where rti.template_id = v_template.id
    order by rti.display_order asc, rti.id asc
    returning is_required
  )
  select
    count(*)::integer,
    count(*) filter (where is_required = true)::integer
    into v_snapshot_count, v_required_count
    from inserted_snapshot;

  if coalesce(v_snapshot_count, 0) < 1 then
    raise exception 'O checklist publicado configurado não possui itens de requisitos.'
      using errcode = '23514';
  end if;

  -- 9. Registrar evento de auditoria somente após processo e snapshot concluídos
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
    'process_created',
    v_user_id,
    v_profile.role,
    'user_self_action',
    'rpc:create_internship_process',
    v_user_id,
    v_process.id,
    'internship_processes',
    v_process.id,
    pg_catalog.jsonb_build_object(
      'institution_id', v_process.institution_id,
      'course_id', v_process.course_id,
      'course_modality_id', v_process.course_modality_id,
      'template_id', v_process.template_id,
      'template_version', v_process.template_version,
      'snapshot_item_count', v_snapshot_count,
      'required_item_count', v_required_count
    )
  );

  return v_process;
end;
$$;

comment on function public.create_internship_process(uuid) is
  'Abre um processo de estágio para auth.uid() (student ativo) derivando escopo e template published da modalidade e gerando snapshot atômico em process_requirements.';

-- 3. Privilégios mínimos: bloqueado para PUBLIC/anon; liberado apenas para authenticated
revoke all on function public.create_internship_process(uuid) from public, anon, authenticated;
grant execute on function public.create_internship_process(uuid) to authenticated;
