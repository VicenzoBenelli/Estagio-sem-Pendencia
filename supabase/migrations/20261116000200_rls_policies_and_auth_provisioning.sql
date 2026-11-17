-- ESP-07 / ESP-08 / ESP-09: RLS deny-by-default, provisionamento seguro e auditoria.

-- 1. Remoção preventiva de privilégios padrão no schema public
revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

-- 2. Proteção de escrita no perfil e criação automática de estudante no Auth
create or replace function public.guard_profiles_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt_role text;
begin
  v_jwt_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    auth.role(),
    ''
  );

  if current_setting('estagio.privileged_op', true) is distinct from 'on'
     and current_user <> 'service_role'
     and not (
       current_user in ('postgres', 'supabase_admin')
       and v_jwt_role not in ('anon', 'authenticated')
     ) then
    if new.id is distinct from old.id
       or new.email is distinct from old.email
       or new.role is distinct from old.role
       or new.active is distinct from old.active
       or new.created_at is distinct from old.created_at then
      raise exception 'Alteração não autorizada em campos protegidos do perfil.'
        using errcode = '42501';
    end if;
  end if;

  new.full_name := nullif(left(btrim(coalesce(new.full_name, '')), 120), '');
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_profiles_guard_write
  before update on public.profiles
  for each row execute function public.guard_profiles_write();

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
    target_user_id,
    process_id,
    entity_table,
    entity_id,
    metadata
  ) values (
    'profile_created',
    new.id,
    'student',
    new.id,
    null,
    'profiles',
    new.id,
    jsonb_build_object('assigned_role', 'student')
  );

  return new;
end;
$$;

create or replace function public.handle_auth_user_email_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is distinct from old.email and new.email is not null then
    perform set_config('estagio.privileged_op', 'on', true);
    update public.profiles
       set email = new.email,
           updated_at = now()
     where id = new.id;
  end if;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create trigger on_auth_user_email_updated
  after update of email on auth.users
  for each row execute function public.handle_auth_user_email_sync();

-- 3. Função auxiliar de escopo para revisores (SECURITY DEFINER ancorada em auth.uid())
create or replace function public.is_assigned_reviewer(
  p_institution_id uuid,
  p_course_id uuid,
  p_course_modality_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.profiles as p
      join public.reviewer_assignments as ra
        on ra.reviewer_id = p.id
      where p.id = auth.uid()
        and p.role = 'reviewer'
        and p.active = true
        and ra.active = true
        and ra.revoked_at is null
        and ra.institution_id = p_institution_id
        and ra.course_id = p_course_id
        and (
          ra.course_modality_id is null
          or ra.course_modality_id = p_course_modality_id
        )
    );
$$;

-- 4. Operações privilegiadas auditáveis para provisionamento de revisores e escopos
create or replace function public.admin_set_user_role(
  p_user_id uuid,
  p_new_role text,
  p_actor_id uuid default null,
  p_reason text default null
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jwt_role text;
  v_profile public.profiles;
  v_old_role text;
  v_revoked_row public.reviewer_assignments;
  v_actor_role text;
begin
  v_jwt_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    auth.role(),
    ''
  );

  if v_jwt_role in ('anon', 'authenticated')
     or (
       v_jwt_role <> 'service_role'
       and session_user not in ('postgres', 'supabase_admin')
     ) then
    raise exception 'Contexto privilegiado obrigatório para alteração de papel.'
      using errcode = '42501';
  end if;

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
  v_actor_role := coalesce(nullif(v_jwt_role, ''), session_user::text);

  if v_old_role = p_new_role then
    return v_profile;
  end if;

  perform set_config('estagio.privileged_op', 'on', true);

  if v_old_role = 'reviewer' and p_new_role = 'student' then
    for v_revoked_row in
      update public.reviewer_assignments
         set active = false,
             revoked_at = now(),
             revoked_by = p_actor_id,
             revocation_reason = coalesce(nullif(btrim(p_reason), ''), 'Papel alterado para student'),
             updated_at = now()
       where reviewer_id = p_user_id
         and active = true
      returning *
    loop
      insert into public.audit_events (
        event_type,
        actor_id,
        actor_role,
        target_user_id,
        process_id,
        entity_table,
        entity_id,
        metadata
      ) values (
        'reviewer_assignment_revoked',
        p_actor_id,
        v_actor_role,
        p_user_id,
        null,
        'reviewer_assignments',
        v_revoked_row.id,
        jsonb_build_object(
          'institution_id', v_revoked_row.institution_id,
          'course_id', v_revoked_row.course_id,
          'course_modality_id', v_revoked_row.course_modality_id,
          'reason', v_revoked_row.revocation_reason
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
    target_user_id,
    process_id,
    entity_table,
    entity_id,
    metadata
  ) values (
    'user_role_changed',
    p_actor_id,
    v_actor_role,
    p_user_id,
    null,
    'profiles',
    p_user_id,
    jsonb_build_object(
      'previous_role', v_old_role,
      'new_role', p_new_role,
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    )
  );

  return v_profile;
end;
$$;

create or replace function public.admin_assign_reviewer_scope(
  p_reviewer_id uuid,
  p_institution_id uuid,
  p_course_id uuid,
  p_course_modality_id uuid default null,
  p_actor_id uuid default null,
  p_reason text default null
)
returns public.reviewer_assignments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jwt_role text;
  v_profile public.profiles;
  v_assignment public.reviewer_assignments;
  v_actor_role text;
begin
  v_jwt_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    auth.role(),
    ''
  );

  if v_jwt_role in ('anon', 'authenticated')
     or (
       v_jwt_role <> 'service_role'
       and session_user not in ('postgres', 'supabase_admin')
     ) then
    raise exception 'Contexto privilegiado obrigatório para atribuição de revisor.'
      using errcode = '42501';
  end if;

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

  v_actor_role := coalesce(nullif(v_jwt_role, ''), session_user::text);

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
    p_actor_id
  )
  returning * into v_assignment;

  insert into public.audit_events (
    event_type,
    actor_id,
    actor_role,
    target_user_id,
    process_id,
    entity_table,
    entity_id,
    metadata
  ) values (
    'reviewer_assignment_created',
    p_actor_id,
    v_actor_role,
    p_reviewer_id,
    null,
    'reviewer_assignments',
    v_assignment.id,
    jsonb_build_object(
      'institution_id', p_institution_id,
      'course_id', p_course_id,
      'course_modality_id', p_course_modality_id,
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    )
  );

  return v_assignment;
end;
$$;

create or replace function public.admin_revoke_reviewer_assignment(
  p_assignment_id uuid,
  p_actor_id uuid default null,
  p_reason text default 'Revogação administrativa de escopo'
)
returns public.reviewer_assignments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jwt_role text;
  v_assignment public.reviewer_assignments;
  v_actor_role text;
begin
  v_jwt_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    auth.role(),
    ''
  );

  if v_jwt_role in ('anon', 'authenticated')
     or (
       v_jwt_role <> 'service_role'
       and session_user not in ('postgres', 'supabase_admin')
     ) then
    raise exception 'Contexto privilegiado obrigatório para revogação de revisor.'
      using errcode = '42501';
  end if;

  update public.reviewer_assignments
     set active = false,
         revoked_at = now(),
         revoked_by = p_actor_id,
         revocation_reason = coalesce(nullif(btrim(p_reason), ''), 'Revogação administrativa de escopo'),
         updated_at = now()
   where id = p_assignment_id
     and active = true
  returning * into v_assignment;

  if not found then
    raise exception 'Atribuição ativa % não encontrada.', p_assignment_id
      using errcode = 'P0002';
  end if;

  v_actor_role := coalesce(nullif(v_jwt_role, ''), session_user::text);

  insert into public.audit_events (
    event_type,
    actor_id,
    actor_role,
    target_user_id,
    process_id,
    entity_table,
    entity_id,
    metadata
  ) values (
    'reviewer_assignment_revoked',
    p_actor_id,
    v_actor_role,
    v_assignment.reviewer_id,
    null,
    'reviewer_assignments',
    v_assignment.id,
    jsonb_build_object(
      'institution_id', v_assignment.institution_id,
      'course_id', v_assignment.course_id,
      'course_modality_id', v_assignment.course_modality_id,
      'reason', v_assignment.revocation_reason
    )
  );

  return v_assignment;
end;
$$;

-- 5. Habilitação de RLS (negação por padrão) em todas as tabelas do domínio
alter table public.institutions enable row level security;
alter table public.courses enable row level security;
alter table public.course_modalities enable row level security;
alter table public.profiles enable row level security;
alter table public.reviewer_assignments enable row level security;
alter table public.requirement_templates enable row level security;
alter table public.requirement_template_items enable row level security;
alter table public.internship_processes enable row level security;
alter table public.process_requirements enable row level security;
alter table public.document_submissions enable row level security;
alter table public.document_reviews enable row level security;
alter table public.audit_events enable row level security;

-- 6. Políticas RLS mínimas para o Lote 1 (nenhuma permissão a anon)
create policy institutions_select_authenticated
  on public.institutions
  for select
  to authenticated
  using (active = true);

create policy courses_select_authenticated
  on public.courses
  for select
  to authenticated
  using (active = true);

create policy course_modalities_select_authenticated
  on public.course_modalities
  for select
  to authenticated
  using (active = true);

create policy requirement_templates_select_authenticated
  on public.requirement_templates
  for select
  to authenticated
  using (
    status = 'published'
    or exists (
      select 1
      from public.internship_processes as ip
      where ip.template_id = requirement_templates.id
        and (
          ip.owner_id = auth.uid()
          or public.is_assigned_reviewer(ip.institution_id, ip.course_id, ip.course_modality_id)
        )
    )
  );

create policy requirement_template_items_select_authenticated
  on public.requirement_template_items
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.requirement_templates as rt
      where rt.id = requirement_template_items.template_id
        and (
          rt.status = 'published'
          or exists (
            select 1
            from public.internship_processes as ip
            where ip.template_id = rt.id
              and (
                ip.owner_id = auth.uid()
                or public.is_assigned_reviewer(ip.institution_id, ip.course_id, ip.course_modality_id)
              )
          )
        )
    )
  );

create policy profiles_select_own_or_scoped_reviewer
  on public.profiles
  for select
  to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1
      from public.internship_processes as ip
      where ip.owner_id = profiles.id
        and public.is_assigned_reviewer(ip.institution_id, ip.course_id, ip.course_modality_id)
    )
  );

create policy profiles_update_own_display_fields
  on public.profiles
  for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy reviewer_assignments_select_own
  on public.reviewer_assignments
  for select
  to authenticated
  using (reviewer_id = auth.uid());

create policy internship_processes_select_owner_or_scoped_reviewer
  on public.internship_processes
  for select
  to authenticated
  using (
    owner_id = auth.uid()
    or public.is_assigned_reviewer(institution_id, course_id, course_modality_id)
  );

create policy process_requirements_select_owner_or_scoped_reviewer
  on public.process_requirements
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.internship_processes as ip
      where ip.id = process_requirements.process_id
        and (
          ip.owner_id = auth.uid()
          or public.is_assigned_reviewer(ip.institution_id, ip.course_id, ip.course_modality_id)
        )
    )
  );

create policy document_submissions_select_owner_or_scoped_reviewer
  on public.document_submissions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.internship_processes as ip
      where ip.id = document_submissions.process_id
        and (
          ip.owner_id = auth.uid()
          or public.is_assigned_reviewer(ip.institution_id, ip.course_id, ip.course_modality_id)
        )
    )
  );

create policy document_reviews_select_owner_or_scoped_reviewer
  on public.document_reviews
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.internship_processes as ip
      where ip.id = document_reviews.process_id
        and (
          ip.owner_id = auth.uid()
          or public.is_assigned_reviewer(ip.institution_id, ip.course_id, ip.course_modality_id)
        )
    )
  );

create policy audit_events_select_authorized_scope
  on public.audit_events
  for select
  to authenticated
  using (
    (
      process_id is not null
      and exists (
        select 1
        from public.internship_processes as ip
        where ip.id = audit_events.process_id
          and (
            ip.owner_id = auth.uid()
            or public.is_assigned_reviewer(ip.institution_id, ip.course_id, ip.course_modality_id)
          )
      )
    )
    or (
      process_id is null
      and target_user_id = auth.uid()
    )
  );

-- 7. Grants explícitos mínimos (zero acesso para anon; mutações sensíveis bloqueadas para authenticated)
grant select on
  public.institutions,
  public.courses,
  public.course_modalities,
  public.requirement_templates,
  public.requirement_template_items,
  public.profiles,
  public.reviewer_assignments,
  public.internship_processes,
  public.process_requirements,
  public.document_submissions,
  public.document_reviews,
  public.audit_events,
  public.process_progress_v
  to authenticated;

grant update (full_name) on public.profiles to authenticated;

grant execute on function public.is_assigned_reviewer(uuid, uuid, uuid) to authenticated;

grant execute on function public.admin_set_user_role(uuid, text, uuid, text) to service_role;
grant execute on function public.admin_assign_reviewer_scope(uuid, uuid, uuid, uuid, uuid, text) to service_role;
grant execute on function public.admin_revoke_reviewer_assignment(uuid, uuid, text) to service_role;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;
