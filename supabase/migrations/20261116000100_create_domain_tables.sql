-- ESP-07: Modelagem relacional inicial do domínio Estágio sem Pendência (MVP)
-- Todas as entidades críticas preservam histórico e impedem exclusão em cascata de evidências.

create extension if not exists pgcrypto with schema extensions;

-- 1. Catálogo institucional (configurável; dados de demonstração no seed)
create table public.institutions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  is_demo boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chk_institutions_code_nonempty check (length(btrim(code)) > 0),
  constraint chk_institutions_name_nonempty check (length(btrim(name)) > 0)
);

create table public.courses (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete restrict,
  code text not null,
  name text not null,
  is_demo boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_courses_institution_code unique (institution_id, code),
  constraint uq_courses_id_institution unique (id, institution_id),
  constraint chk_courses_code_nonempty check (length(btrim(code)) > 0),
  constraint chk_courses_name_nonempty check (length(btrim(name)) > 0)
);

create index idx_courses_institution_active
  on public.courses (institution_id, active);

create table public.course_modalities (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete restrict,
  code text not null,
  name text not null,
  is_mandatory boolean not null default true,
  is_demo boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_course_modalities_course_code unique (course_id, code),
  constraint uq_course_modalities_id_course unique (id, course_id),
  constraint chk_course_modalities_code_nonempty check (length(btrim(code)) > 0),
  constraint chk_course_modalities_name_nonempty check (length(btrim(name)) > 0)
);

create index idx_course_modalities_course_active
  on public.course_modalities (course_id, active);

-- 2. Perfis e atribuições de revisores (ESP-08 / ESP-09)
create table public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  email text not null,
  full_name text,
  role text not null default 'student',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chk_profiles_role check (role in ('student', 'reviewer')),
  constraint chk_profiles_email_nonempty check (length(btrim(email)) > 0)
);

create index idx_profiles_role_active
  on public.profiles (role, active);

create table public.reviewer_assignments (
  id uuid primary key default gen_random_uuid(),
  reviewer_id uuid not null references public.profiles(id) on delete restrict,
  institution_id uuid not null references public.institutions(id) on delete restrict,
  course_id uuid not null,
  course_modality_id uuid,
  active boolean not null default true,
  assigned_by uuid references public.profiles(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references public.profiles(id) on delete restrict,
  revocation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fk_reviewer_assignments_course_inst
    foreign key (course_id, institution_id)
    references public.courses(id, institution_id)
    on delete restrict,
  constraint fk_reviewer_assignments_modality_course
    foreign key (course_modality_id, course_id)
    references public.course_modalities(id, course_id)
    on delete restrict,
  constraint chk_reviewer_assignments_active_revoked
    check (
      (active = true and revoked_at is null)
      or (active = false and revoked_at is not null)
    )
);

create unique index uq_reviewer_assignments_active_scope
  on public.reviewer_assignments (
    reviewer_id,
    course_id,
    coalesce(course_modality_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where active = true;

create index idx_reviewer_assignments_lookup
  on public.reviewer_assignments (reviewer_id, institution_id, course_id, course_modality_id)
  where active = true;

-- 3. Templates versionados de requisitos
create table public.requirement_templates (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete restrict,
  course_id uuid not null,
  course_modality_id uuid not null,
  version integer not null,
  title text not null,
  source_reference text not null,
  status text not null default 'draft',
  is_demo boolean not null default true,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fk_requirement_templates_course_inst
    foreign key (course_id, institution_id)
    references public.courses(id, institution_id)
    on delete restrict,
  constraint fk_requirement_templates_modality_course
    foreign key (course_modality_id, course_id)
    references public.course_modalities(id, course_id)
    on delete restrict,
  constraint uq_requirement_templates_modality_version unique (course_modality_id, version),
  constraint uq_requirement_templates_id_version unique (id, version),
  constraint chk_requirement_templates_version check (version >= 1),
  constraint chk_requirement_templates_status check (status in ('draft', 'published', 'archived')),
  constraint chk_requirement_templates_title_nonempty check (length(btrim(title)) > 0),
  constraint chk_requirement_templates_source_nonempty check (length(btrim(source_reference)) > 0)
);

create unique index uq_requirement_templates_one_published
  on public.requirement_templates (course_modality_id)
  where status = 'published';

create table public.requirement_template_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.requirement_templates(id) on delete restrict,
  code text not null,
  title text not null,
  description text not null,
  acceptance_criteria text not null,
  is_required boolean not null,
  display_order integer not null,
  is_demo boolean not null default true,
  created_at timestamptz not null default now(),
  constraint uq_requirement_template_items_template_code unique (template_id, code),
  constraint uq_requirement_template_items_template_order unique (template_id, display_order),
  constraint chk_requirement_template_items_order check (display_order >= 1),
  constraint chk_requirement_template_items_code_nonempty check (length(btrim(code)) > 0),
  constraint chk_requirement_template_items_title_nonempty check (length(btrim(title)) > 0)
);

-- 4. Processos de estágio e snapshots de requisitos
create table public.internship_processes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  institution_id uuid not null references public.institutions(id) on delete restrict,
  course_id uuid not null,
  course_modality_id uuid not null,
  template_id uuid not null,
  template_version integer not null,
  status text not null default 'in_progress',
  is_demo boolean not null default true,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fk_internship_processes_course_inst
    foreign key (course_id, institution_id)
    references public.courses(id, institution_id)
    on delete restrict,
  constraint fk_internship_processes_modality_course
    foreign key (course_modality_id, course_id)
    references public.course_modalities(id, course_id)
    on delete restrict,
  constraint fk_internship_processes_template_version
    foreign key (template_id, template_version)
    references public.requirement_templates(id, version)
    on delete restrict,
  constraint chk_internship_processes_template_version check (template_version >= 1),
  constraint chk_internship_processes_status
    check (status in ('in_progress', 'documentally_complete', 'cancelled'))
);

-- Regra provisória do MVP: no máximo um processo não cancelado por estudante/curso/modalidade.
create unique index uq_internship_processes_active_student_scope
  on public.internship_processes (owner_id, course_id, course_modality_id)
  where status <> 'cancelled';

create index idx_internship_processes_owner_status
  on public.internship_processes (owner_id, status);

create index idx_internship_processes_scope_status
  on public.internship_processes (institution_id, course_id, course_modality_id, status);

create table public.process_requirements (
  id uuid primary key default gen_random_uuid(),
  process_id uuid not null references public.internship_processes(id) on delete restrict,
  template_item_id uuid not null references public.requirement_template_items(id) on delete restrict,
  code text not null,
  title text not null,
  description text not null,
  acceptance_criteria text not null,
  is_required boolean not null,
  display_order integer not null,
  status text not null default 'not_submitted',
  current_submission_id uuid,
  current_version integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_process_requirements_process_item unique (process_id, template_item_id),
  constraint uq_process_requirements_process_code unique (process_id, code),
  constraint uq_process_requirements_id_process unique (id, process_id),
  constraint chk_process_requirements_order check (display_order >= 1),
  constraint chk_process_requirements_status
    check (status in ('not_submitted', 'under_review', 'correction_requested', 'approved')),
  constraint chk_process_requirements_version check (current_version >= 0),
  constraint chk_process_requirements_submission_state
    check (
      (current_submission_id is null and current_version = 0 and status = 'not_submitted')
      or (current_submission_id is not null and current_version >= 1 and status <> 'not_submitted')
    )
);

create index idx_process_requirements_process_status
  on public.process_requirements (process_id, status);

-- 5. Submissões documentais versionadas e revisões imutáveis
create table public.document_submissions (
  id uuid primary key default gen_random_uuid(),
  process_id uuid not null references public.internship_processes(id) on delete restrict,
  process_requirement_id uuid not null,
  submitted_by uuid not null references public.profiles(id) on delete restrict,
  version integer not null,
  storage_bucket text not null default 'internship-documents',
  storage_path text not null unique,
  original_filename text,
  mime_type text not null,
  size_bytes bigint not null,
  sha256_checksum text,
  status text not null default 'under_review',
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint fk_document_submissions_requirement_process
    foreign key (process_requirement_id, process_id)
    references public.process_requirements(id, process_id)
    on delete restrict,
  constraint uq_document_submissions_req_version unique (process_requirement_id, version),
  constraint uq_document_submissions_id_req unique (id, process_requirement_id),
  constraint chk_document_submissions_version check (version >= 1),
  constraint chk_document_submissions_bucket_nonempty check (length(btrim(storage_bucket)) > 0),
  constraint chk_document_submissions_path_safe
    check (length(btrim(storage_path)) > 0 and position('..' in storage_path) = 0),
  constraint chk_document_submissions_mime_pdf check (mime_type = 'application/pdf'),
  constraint chk_document_submissions_size_positive check (size_bytes > 0),
  constraint chk_document_submissions_status
    check (status in ('under_review', 'correction_requested', 'approved'))
);

create index idx_document_submissions_req_version
  on public.document_submissions (process_requirement_id, version desc);

create index idx_document_submissions_status_submitted
  on public.document_submissions (status, submitted_at);

alter table public.process_requirements
  add constraint fk_process_requirements_current_submission
  foreign key (current_submission_id, id)
  references public.document_submissions(id, process_requirement_id)
  on delete restrict
  deferrable initially deferred;

create table public.document_reviews (
  id uuid primary key default gen_random_uuid(),
  process_id uuid not null references public.internship_processes(id) on delete restrict,
  process_requirement_id uuid not null,
  submission_id uuid not null unique,
  reviewer_id uuid not null references public.profiles(id) on delete restrict,
  decision text not null,
  reason text,
  reviewed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint fk_document_reviews_requirement_process
    foreign key (process_requirement_id, process_id)
    references public.process_requirements(id, process_id)
    on delete restrict,
  constraint fk_document_reviews_submission_req
    foreign key (submission_id, process_requirement_id)
    references public.document_submissions(id, process_requirement_id)
    on delete restrict,
  constraint chk_document_reviews_decision
    check (decision in ('approved', 'correction_requested')),
  constraint chk_document_reviews_correction_reason
    check (
      decision <> 'correction_requested'
      or (reason is not null and length(btrim(reason)) > 0)
    )
);

create index idx_document_reviews_process_reviewed
  on public.document_reviews (process_id, reviewed_at desc);

create index idx_document_reviews_reviewer_reviewed
  on public.document_reviews (reviewer_id, reviewed_at desc);

-- 6. Trilha de auditoria append-only
create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  actor_id uuid references public.profiles(id) on delete restrict,
  actor_role text not null,
  target_user_id uuid references public.profiles(id) on delete restrict,
  process_id uuid references public.internship_processes(id) on delete restrict,
  entity_table text not null,
  entity_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  constraint chk_audit_events_type_nonempty check (length(btrim(event_type)) > 0),
  constraint chk_audit_events_actor_role_nonempty check (length(btrim(actor_role)) > 0),
  constraint chk_audit_events_entity_table_nonempty check (length(btrim(entity_table)) > 0)
);

create index idx_audit_events_process_occurred
  on public.audit_events (process_id, occurred_at desc);

create index idx_audit_events_target_occurred
  on public.audit_events (target_user_id, occurred_at desc);

create index idx_audit_events_entity_occurred
  on public.audit_events (entity_table, entity_id, occurred_at desc);

-- 7. View calculada de progresso (nunca armazenada/alterada pelo cliente; 0 obrigatórios => indeterminate)
create view public.process_progress_v
with (security_invoker = true) as
select
  ip.id as process_id,
  ip.owner_id,
  ip.status as process_status,
  count(pr.id) filter (where pr.is_required = true) as required_total,
  count(pr.id) filter (where pr.is_required = true and pr.status = 'approved') as required_approved,
  count(pr.id) filter (where pr.is_required = true and pr.status = 'under_review') as required_under_review,
  count(pr.id) filter (where pr.is_required = true and pr.status = 'correction_requested') as required_correction_requested,
  case
    when count(pr.id) filter (where pr.is_required = true) = 0 then 'indeterminate'
    when count(pr.id) filter (where pr.is_required = true and pr.status = 'approved')
       = count(pr.id) filter (where pr.is_required = true) then 'documentally_complete'
    else 'in_progress'
  end as progress_status,
  case
    when count(pr.id) filter (where pr.is_required = true) = 0 then null::numeric(5, 2)
    else round(
      (count(pr.id) filter (where pr.is_required = true and pr.status = 'approved')::numeric
      / count(pr.id) filter (where pr.is_required = true)::numeric) * 100.0,
      2
    )
  end as progress_percentage
from public.internship_processes as ip
left join public.process_requirements as pr
  on pr.process_id = ip.id
group by ip.id, ip.owner_id, ip.status;

-- 8. Triggers de integridade, timestamps e preservação de histórico
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.prevent_row_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Operação proibida: registro histórico/evidência em %.% é imutável.',
    tg_table_schema, tg_table_name
    using errcode = '42501';
end;
$$;

create or replace function public.validate_reviewer_assignment_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_role text;
  v_profile_active boolean;
begin
  if new.active = true then
    select p.role, p.active
      into v_profile_role, v_profile_active
      from public.profiles as p
     where p.id = new.reviewer_id;

    if not found then
      raise exception 'Perfil de revisor não encontrado.'
        using errcode = '23503';
    end if;

    if v_profile_role <> 'reviewer' or v_profile_active is distinct from true then
      raise exception 'Atribuição exige perfil ativo com papel reviewer.'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

create trigger trg_institutions_touch_updated_at
  before update on public.institutions
  for each row execute function public.touch_updated_at();

create trigger trg_courses_touch_updated_at
  before update on public.courses
  for each row execute function public.touch_updated_at();

create trigger trg_course_modalities_touch_updated_at
  before update on public.course_modalities
  for each row execute function public.touch_updated_at();

create trigger trg_reviewer_assignments_touch_updated_at
  before update on public.reviewer_assignments
  for each row execute function public.touch_updated_at();

create trigger trg_reviewer_assignments_validate_role
  before insert or update on public.reviewer_assignments
  for each row execute function public.validate_reviewer_assignment_role();

create trigger trg_requirement_templates_touch_updated_at
  before update on public.requirement_templates
  for each row execute function public.touch_updated_at();

create trigger trg_internship_processes_touch_updated_at
  before update on public.internship_processes
  for each row execute function public.touch_updated_at();

create trigger trg_process_requirements_touch_updated_at
  before update on public.process_requirements
  for each row execute function public.touch_updated_at();

create trigger trg_internship_processes_no_delete
  before delete on public.internship_processes
  for each row execute function public.prevent_row_mutation();

create trigger trg_process_requirements_no_delete
  before delete on public.process_requirements
  for each row execute function public.prevent_row_mutation();

create trigger trg_document_submissions_no_delete
  before delete on public.document_submissions
  for each row execute function public.prevent_row_mutation();

create trigger trg_document_reviews_immutable
  before update or delete on public.document_reviews
  for each row execute function public.prevent_row_mutation();

create trigger trg_audit_events_immutable
  before update or delete on public.audit_events
  for each row execute function public.prevent_row_mutation();
