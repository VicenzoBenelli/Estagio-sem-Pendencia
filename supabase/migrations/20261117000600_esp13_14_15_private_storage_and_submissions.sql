-- ESP-13 / ESP-14 / ESP-15: Storage privado, submissão segura de PDFs e versionamento imutável.
-- Não altera migrations anteriores; preserva integralmente dados e histórico de Lotes 1 e 2.

-- ============================================================================
-- 1. ESP-13: Bucket privado e RLS restrita de leitura no Supabase Storage
-- ============================================================================

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'internship-documents',
  'internship-documents',
  false,
  5242880,
  array['application/pdf']::text[]
)
on conflict (id) do update
  set name = excluded.name,
      public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists internship_documents_select_authorized on storage.objects;
create policy internship_documents_select_authorized
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'internship-documents'
    and auth.uid() is not null
    and storage.objects.archived_at is null
    and storage.objects.is_delete_marker = false
    and exists (
      select 1
      from public.document_submissions as ds
      join public.internship_processes as ip
        on ip.id = ds.process_id
      where ds.storage_bucket = storage.objects.bucket_id
        and ds.storage_path = storage.objects.name
        and (
          ip.owner_id = auth.uid()
          or public.is_assigned_reviewer(
            ip.institution_id,
            ip.course_id,
            ip.course_modality_id
          )
        )
    )
  );

-- ============================================================================
-- 2. ESP-14 / ESP-15: Idempotência e índice auxiliar em document_submissions
-- ============================================================================

alter table public.document_submissions
  add column if not exists idempotency_key uuid;

create unique index if not exists uq_document_submissions_req_idempotency
  on public.document_submissions (process_requirement_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_document_submissions_bucket_path
  on public.document_submissions (storage_bucket, storage_path);

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
     or new.idempotency_key is distinct from old.idempotency_key
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

-- ============================================================================
-- 3. ESP-14: Controle transacional de intenções de upload e compensação
-- ============================================================================

create table if not exists public.document_submission_intents (
  id uuid primary key default gen_random_uuid(),
  process_id uuid not null references public.internship_processes(id) on delete restrict,
  process_requirement_id uuid not null,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  idempotency_key uuid,
  target_version integer not null,
  storage_bucket text not null default 'internship-documents',
  storage_path text not null unique,
  original_filename text not null,
  mime_type text not null default 'application/pdf',
  size_bytes bigint not null,
  sha256_checksum text not null,
  status text not null default 'uploading',
  submission_id uuid references public.document_submissions(id) on delete restrict,
  error_code text,
  error_detail text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fk_doc_sub_intents_req_process
    foreign key (process_requirement_id, process_id)
    references public.process_requirements(id, process_id)
    on delete restrict,
  constraint chk_doc_sub_intents_target_version check (target_version >= 1),
  constraint chk_doc_sub_intents_bucket check (storage_bucket = 'internship-documents'),
  constraint chk_doc_sub_intents_path_safe
    check (
      pg_catalog.length(pg_catalog.btrim(storage_path)) > 0
      and position('..' in storage_path) = 0
      and pg_catalog.substr(storage_path, 1, 1) <> '/'
    ),
  constraint chk_doc_sub_intents_filename_nonempty
    check (pg_catalog.length(pg_catalog.btrim(original_filename)) > 0),
  constraint chk_doc_sub_intents_mime check (mime_type = 'application/pdf'),
  constraint chk_doc_sub_intents_size_positive check (size_bytes > 0),
  constraint chk_doc_sub_intents_sha256 check (sha256_checksum ~ '^[0-9a-f]{64}$'),
  constraint chk_doc_sub_intents_status
    check (status in ('uploading', 'committed', 'aborted', 'orphan_cleaned', 'orphan_cleanup_pending')),
  constraint chk_doc_sub_intents_committed_link
    check (
      (status = 'committed' and submission_id is not null)
      or (status <> 'committed' and submission_id is null)
    )
);

create unique index if not exists uq_doc_sub_intents_active_idempotency
  on public.document_submission_intents (process_requirement_id, idempotency_key)
  where idempotency_key is not null and status in ('uploading', 'committed');

create index if not exists idx_doc_sub_intents_req_created
  on public.document_submission_intents (process_requirement_id, created_at desc);

alter table public.document_submission_intents enable row level security;

revoke all on public.document_submission_intents from public, anon, authenticated;
grant all on public.document_submission_intents to service_role;

create or replace function public.guard_document_submission_intents_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.process_id is distinct from old.process_id
     or new.process_requirement_id is distinct from old.process_requirement_id
     or new.actor_id is distinct from old.actor_id
     or new.idempotency_key is distinct from old.idempotency_key
     or new.target_version is distinct from old.target_version
     or new.storage_bucket is distinct from old.storage_bucket
     or new.storage_path is distinct from old.storage_path
     or new.original_filename is distinct from old.original_filename
     or new.mime_type is distinct from old.mime_type
     or new.size_bytes is distinct from old.size_bytes
     or new.sha256_checksum is distinct from old.sha256_checksum
     or new.created_at is distinct from old.created_at then
    raise exception 'Campos estruturais de document_submission_intents são imutáveis.'
      using errcode = '42501';
  end if;

  if old.status in ('committed', 'aborted', 'orphan_cleaned') then
    if new.status is distinct from old.status
       or new.submission_id is distinct from old.submission_id then
      raise exception 'Intenção de submissão em estado terminal (%) não pode ser alterada.', old.status
        using errcode = '42501';
    end if;
  elsif old.status = 'uploading' then
    if new.status not in ('uploading', 'committed', 'aborted', 'orphan_cleanup_pending', 'orphan_cleaned') then
      raise exception 'Transição inválida em document_submission_intents (% -> %).', old.status, new.status
        using errcode = '42501';
    end if;
  elsif old.status = 'orphan_cleanup_pending' then
    if new.status not in ('orphan_cleanup_pending', 'orphan_cleaned') then
      raise exception 'Transição inválida após pendência de limpeza (% -> %).', old.status, new.status
        using errcode = '42501';
    end if;
  end if;

  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

drop trigger if exists trg_document_submission_intents_no_delete on public.document_submission_intents;
create trigger trg_document_submission_intents_no_delete
  before delete on public.document_submission_intents
  for each row execute function public.prevent_row_mutation();

drop trigger if exists trg_document_submission_intents_immutability on public.document_submission_intents;
create trigger trg_document_submission_intents_immutability
  before update on public.document_submission_intents
  for each row execute function public.guard_document_submission_intents_immutability();

-- ============================================================================
-- 4. RPCs internas (exclusivas de service_role / backend)
-- ============================================================================

create or replace function public.assert_submission_backend_caller()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jwt_role text;
begin
  v_jwt_role := nullif(pg_catalog.current_setting('request.jwt.claim.role', true), '');

  if current_user not in ('service_role', 'postgres', 'supabase_admin')
     or (v_jwt_role is not null and v_jwt_role <> 'service_role') then
    raise exception '[ERR:unauthorized_backend_caller] Operação restrita ao backend autorizado.'
      using errcode = '42501';
  end if;
end;
$$;

create or replace function public.prepare_document_submission(
  p_actor_id uuid,
  p_process_requirement_id uuid,
  p_idempotency_key uuid,
  p_original_filename text,
  p_size_bytes bigint,
  p_sha256_checksum text,
  p_max_size_bytes bigint default 5242880
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile record;
  v_req record;
  v_existing_intent public.document_submission_intents;
  v_existing_sub public.document_submissions;
  v_new_intent public.document_submission_intents;
  v_checksum text;
  v_clean_filename text;
  v_target_version integer;
  v_storage_path text;
begin
  perform public.assert_submission_backend_caller();

  if p_actor_id is null or p_process_requirement_id is null then
    raise exception '[ERR:invalid_input] Actor e requisito são obrigatórios.'
      using errcode = '22023';
  end if;

  if p_max_size_bytes is null or p_max_size_bytes <= 0 then
    raise exception '[ERR:invalid_input] Limite máximo de arquivo inválido.'
      using errcode = '22023';
  end if;

  if p_size_bytes is null or p_size_bytes <= 0 then
    raise exception '[ERR:empty_file] Arquivo PDF vazio ou tamanho inválido.'
      using errcode = '22023';
  end if;

  if p_size_bytes > p_max_size_bytes then
    raise exception '[ERR:file_too_large] Arquivo PDF excede o limite configurado (% bytes).', p_max_size_bytes
      using errcode = '22023';
  end if;

  v_checksum := pg_catalog.lower(pg_catalog.btrim(coalesce(p_sha256_checksum, '')));
  if v_checksum !~ '^[0-9a-f]{64}$' then
    raise exception '[ERR:invalid_checksum] Checksum SHA-256 inválido.'
      using errcode = '22023';
  end if;

  v_clean_filename := pg_catalog.btrim(
    pg_catalog.regexp_replace(coalesce(p_original_filename, ''), '[[:cntrl:]]', '', 'g')
  );
  if v_clean_filename = '' or pg_catalog.length(v_clean_filename) > 180 then
    raise exception '[ERR:invalid_filename] Nome de arquivo inválido.'
      using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_process_requirement_id::text, 14)
  );

  select p.id, p.role, p.active
    into v_profile
    from public.profiles as p
   where p.id = p_actor_id;

  if not found or v_profile.active is distinct from true or v_profile.role <> 'student' then
    raise exception '[ERR:forbidden_role] Apenas estudante ativo pode enviar documento.'
      using errcode = '42501';
  end if;

  select
    pr.id,
    pr.process_id,
    pr.status,
    pr.current_version,
    pr.current_submission_id,
    ip.owner_id,
    ip.status as process_status
  into v_req
  from public.process_requirements as pr
  join public.internship_processes as ip
    on ip.id = pr.process_id
  where pr.id = p_process_requirement_id
  for update of pr;

  if not found then
    raise exception '[ERR:requirement_not_found] Requisito do processo não encontrado.'
      using errcode = 'P0002';
  end if;

  if v_req.owner_id is distinct from p_actor_id then
    raise exception '[ERR:forbidden_owner] Estudante não é proprietário do processo.'
      using errcode = '42501';
  end if;

  if v_req.process_status = 'cancelled' then
    raise exception '[ERR:process_cancelled] Processo cancelado não aceita envio documental.'
      using errcode = '42501';
  end if;

  -- Replay idempotente antes do bloqueio por status under_review
  if p_idempotency_key is not null then
    select i.*
      into v_existing_intent
      from public.document_submission_intents as i
     where i.process_requirement_id = p_process_requirement_id
       and i.idempotency_key = p_idempotency_key
       and i.status in ('uploading', 'committed')
     order by i.created_at desc
     limit 1
     for update;

    if found then
      if v_existing_intent.actor_id is distinct from p_actor_id
         or v_existing_intent.sha256_checksum is distinct from v_checksum
         or v_existing_intent.size_bytes is distinct from p_size_bytes then
        raise exception '[ERR:idempotency_mismatch] Chave de idempotência já associada a outro conteúdo.'
          using errcode = '23505';
      end if;

      if v_existing_intent.status = 'committed' then
        select ds.*
          into v_existing_sub
          from public.document_submissions as ds
         where ds.id = v_existing_intent.submission_id;

        if not found then
          raise exception '[ERR:submission_not_found] Submissão idempotente não localizada.'
            using errcode = 'P0002';
        end if;

        return pg_catalog.jsonb_build_object(
          'outcome', 'already_committed',
          'submission', pg_catalog.to_jsonb(v_existing_sub),
          'requirement', pg_catalog.jsonb_build_object(
            'id', v_req.id,
            'process_id', v_req.process_id,
            'status', v_req.status,
            'current_version', v_req.current_version,
            'current_submission_id', v_req.current_submission_id
          )
        );
      end if;

      raise exception '[ERR:submission_in_progress] Submissão com esta chave de idempotência já está em andamento.'
        using errcode = '55P03';
    end if;
  end if;

  if v_req.status not in ('not_submitted', 'correction_requested') then
    raise exception '[ERR:requirement_status_conflict] Requisito no status atual (%) não aceita novo envio.', v_req.status
      using errcode = '42501';
  end if;

  v_target_version := v_req.current_version + 1;
  v_storage_path :=
    'processes/' || v_req.process_id::text
    || '/requirements/' || v_req.id::text
    || '/submissions/' || pg_catalog.gen_random_uuid()::text || '.pdf';

  insert into public.document_submission_intents (
    process_id,
    process_requirement_id,
    actor_id,
    idempotency_key,
    target_version,
    storage_bucket,
    storage_path,
    original_filename,
    mime_type,
    size_bytes,
    sha256_checksum,
    status
  ) values (
    v_req.process_id,
    v_req.id,
    p_actor_id,
    p_idempotency_key,
    v_target_version,
    'internship-documents',
    v_storage_path,
    v_clean_filename,
    'application/pdf',
    p_size_bytes,
    v_checksum,
    'uploading'
  )
  returning * into v_new_intent;

  return pg_catalog.jsonb_build_object(
    'outcome', 'ready_to_upload',
    'intent_id', v_new_intent.id,
    'process_id', v_new_intent.process_id,
    'process_requirement_id', v_new_intent.process_requirement_id,
    'target_version', v_new_intent.target_version,
    'storage_bucket', v_new_intent.storage_bucket,
    'storage_path', v_new_intent.storage_path
  );
end;
$$;

create or replace function public.finalize_document_submission(
  p_actor_id uuid,
  p_intent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_intent_lookup record;
  v_intent public.document_submission_intents;
  v_profile record;
  v_req public.process_requirements;
  v_process public.internship_processes;
  v_storage_obj record;
  v_existing_sub public.document_submissions;
  v_submission public.document_submissions;
  v_next_version integer;
begin
  perform public.assert_submission_backend_caller();

  if p_actor_id is null or p_intent_id is null then
    raise exception '[ERR:invalid_input] Actor e intent_id são obrigatórios.'
      using errcode = '22023';
  end if;

  select i.id, i.process_requirement_id
    into v_intent_lookup
    from public.document_submission_intents as i
   where i.id = p_intent_id;

  if not found then
    raise exception '[ERR:intent_not_found] Intenção de envio não encontrada.'
      using errcode = 'P0002';
  end if;

  -- Ordem fixa de locks (advisory -> process_requirements -> document_submission_intents) evita deadlocks
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_intent_lookup.process_requirement_id::text, 14)
  );

  select pr.*
    into v_req
    from public.process_requirements as pr
   where pr.id = v_intent_lookup.process_requirement_id
   for update;

  select i.*
    into v_intent
    from public.document_submission_intents as i
   where i.id = p_intent_id
   for update;

  if v_intent.actor_id is distinct from p_actor_id then
    raise exception '[ERR:forbidden_owner] Ator incompatível com a intenção de submissão.'
      using errcode = '42501';
  end if;

  if v_intent.status = 'committed' then
    select ds.*
      into v_existing_sub
      from public.document_submissions as ds
     where ds.id = v_intent.submission_id;

    return pg_catalog.jsonb_build_object(
      'outcome', 'already_committed',
      'submission', pg_catalog.to_jsonb(v_existing_sub),
      'requirement', pg_catalog.jsonb_build_object(
        'id', v_req.id,
        'process_id', v_req.process_id,
        'status', v_req.status,
        'current_version', v_req.current_version,
        'current_submission_id', v_req.current_submission_id
      )
    );
  end if;

  if v_intent.status <> 'uploading' then
    raise exception '[ERR:intent_invalid_state] Intenção de submissão não está aberta para finalização (%).',
      v_intent.status
      using errcode = '42501';
  end if;

  select p.id, p.role, p.active
    into v_profile
    from public.profiles as p
   where p.id = p_actor_id;

  if not found or v_profile.active is distinct from true or v_profile.role <> 'student' then
    raise exception '[ERR:forbidden_role] Perfil não autorizado para concluir submissão.'
      using errcode = '42501';
  end if;

  select ip.*
    into v_process
    from public.internship_processes as ip
   where ip.id = v_req.process_id
   for share;

  if not found or v_process.owner_id is distinct from p_actor_id then
    raise exception '[ERR:forbidden_owner] Estudante não é proprietário do processo.'
      using errcode = '42501';
  end if;

  if v_process.status = 'cancelled' then
    raise exception '[ERR:process_cancelled] Processo cancelado não aceita submissão.'
      using errcode = '42501';
  end if;

  if v_req.status not in ('not_submitted', 'correction_requested') then
    raise exception '[ERR:requirement_status_conflict] Requisito já alterado para status (%) antes da finalização.',
      v_req.status
      using errcode = '42501';
  end if;

  v_next_version := v_req.current_version + 1;
  if v_intent.target_version <> v_next_version then
    raise exception '[ERR:version_conflict] Versão alvo (%) diverge da próxima versão esperada (%).',
      v_intent.target_version, v_next_version
      using errcode = '42501';
  end if;

  -- Verificação real anti-TOCTOU no catálogo storage.objects
  select
    o.id,
    o.bucket_id,
    o.name,
    nullif(o.metadata ->> 'size', '')::bigint as obj_size,
    o.metadata ->> 'mimetype' as obj_mimetype
  into v_storage_obj
  from storage.objects as o
  where o.bucket_id = v_intent.storage_bucket
    and o.name = v_intent.storage_path
    and o.archived_at is null
    and o.is_delete_marker = false;

  if not found then
    raise exception '[ERR:storage_object_missing] Objeto PDF não localizado no bucket privado.'
      using errcode = 'P0002';
  end if;

  if v_storage_obj.obj_mimetype is distinct from 'application/pdf' then
    raise exception '[ERR:storage_mime_mismatch] MIME registrado no Storage (%) difere de application/pdf.',
      coalesce(v_storage_obj.obj_mimetype, 'null')
      using errcode = '22023';
  end if;

  if v_storage_obj.obj_size is distinct from v_intent.size_bytes then
    raise exception '[ERR:storage_size_mismatch] Tamanho registrado no Storage (%) difere do arquivo validado (%).',
      coalesce(v_storage_obj.obj_size::text, 'null'), v_intent.size_bytes
      using errcode = '22023';
  end if;

  insert into public.document_submissions (
    process_id,
    process_requirement_id,
    submitted_by,
    version,
    storage_bucket,
    storage_path,
    original_filename,
    mime_type,
    size_bytes,
    sha256_checksum,
    idempotency_key,
    status
  ) values (
    v_process.id,
    v_req.id,
    p_actor_id,
    v_next_version,
    v_intent.storage_bucket,
    v_intent.storage_path,
    v_intent.original_filename,
    v_intent.mime_type,
    v_intent.size_bytes,
    v_intent.sha256_checksum,
    v_intent.idempotency_key,
    'under_review'
  )
  returning * into v_submission;

  update public.process_requirements
     set status = 'under_review',
         current_submission_id = v_submission.id,
         current_version = v_next_version
   where id = v_req.id
  returning * into v_req;

  update public.document_submission_intents
     set status = 'committed',
         submission_id = v_submission.id,
         error_code = null,
         error_detail = null
   where id = v_intent.id;

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
    'document_submitted',
    p_actor_id,
    v_profile.role,
    'user_self_action',
    'edge:submit-requirement-pdf',
    p_actor_id,
    v_process.id,
    'document_submissions',
    v_submission.id,
    pg_catalog.jsonb_build_object(
      'process_requirement_id', v_req.id,
      'version', v_submission.version,
      'is_resubmission', (v_submission.version > 1),
      'storage_bucket', v_submission.storage_bucket,
      'storage_path', v_submission.storage_path,
      'size_bytes', v_submission.size_bytes,
      'sha256_checksum', v_submission.sha256_checksum,
      'intent_id', v_intent.id,
      'idempotency_key', v_intent.idempotency_key
    )
  );

  return pg_catalog.jsonb_build_object(
    'outcome', 'committed',
    'submission', pg_catalog.to_jsonb(v_submission),
    'requirement', pg_catalog.jsonb_build_object(
      'id', v_req.id,
      'process_id', v_req.process_id,
      'status', v_req.status,
      'current_version', v_req.current_version,
      'current_submission_id', v_req.current_submission_id
    )
  );
end;
$$;

create or replace function public.prepare_submission_orphan_cleanup(
  p_intent_id uuid,
  p_error_code text default null,
  p_error_detail text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_intent public.document_submission_intents;
  v_has_committed_submission boolean;
begin
  perform public.assert_submission_backend_caller();

  if p_intent_id is null then
    raise exception '[ERR:invalid_input] intent_id é obrigatório.'
      using errcode = '22023';
  end if;

  select i.*
    into v_intent
    from public.document_submission_intents as i
   where i.id = p_intent_id
   for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'safe_to_delete', false,
      'reason', 'intent_not_found'
    );
  end if;

  if v_intent.status = 'committed' or v_intent.submission_id is not null then
    return pg_catalog.jsonb_build_object(
      'safe_to_delete', false,
      'reason', 'intent_already_committed'
    );
  end if;

  if v_intent.status in ('aborted', 'orphan_cleaned') then
    return pg_catalog.jsonb_build_object(
      'safe_to_delete', false,
      'reason', 'already_closed'
    );
  end if;

  select exists (
    select 1
      from public.document_submissions as ds
     where ds.storage_bucket = v_intent.storage_bucket
       and ds.storage_path = v_intent.storage_path
  ) into v_has_committed_submission;

  if v_has_committed_submission then
    return pg_catalog.jsonb_build_object(
      'safe_to_delete', false,
      'reason', 'referenced_by_submission'
    );
  end if;

  update public.document_submission_intents
     set status = 'orphan_cleanup_pending',
         error_code = nullif(pg_catalog.btrim(coalesce(p_error_code, '')), ''),
         error_detail = pg_catalog.substr(nullif(pg_catalog.btrim(coalesce(p_error_detail, '')), ''), 1, 500)
   where id = v_intent.id
  returning * into v_intent;

  return pg_catalog.jsonb_build_object(
    'safe_to_delete', true,
    'intent_id', v_intent.id,
    'storage_bucket', v_intent.storage_bucket,
    'storage_path', v_intent.storage_path
  );
end;
$$;

create or replace function public.compensate_document_submission_intent(
  p_intent_id uuid,
  p_outcome_status text,
  p_error_code text default null,
  p_error_detail text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_intent public.document_submission_intents;
begin
  perform public.assert_submission_backend_caller();

  if p_intent_id is null then
    raise exception '[ERR:invalid_input] intent_id é obrigatório.'
      using errcode = '22023';
  end if;

  if p_outcome_status not in ('aborted', 'orphan_cleaned', 'orphan_cleanup_pending') then
    raise exception '[ERR:invalid_input] Estado de compensação inválido (%).', p_outcome_status
      using errcode = '22023';
  end if;

  select i.*
    into v_intent
    from public.document_submission_intents as i
   where i.id = p_intent_id
   for update;

  if not found then
    raise exception '[ERR:intent_not_found] Intenção de submissão não encontrada.'
      using errcode = 'P0002';
  end if;

  if v_intent.status = 'committed' or v_intent.submission_id is not null then
    raise exception '[ERR:intent_already_committed] Intenção já persistida nunca pode ser compensada.'
      using errcode = '42501';
  end if;

  if exists (
    select 1
      from public.document_submissions as ds
     where ds.storage_bucket = v_intent.storage_bucket
       and ds.storage_path = v_intent.storage_path
  ) then
    raise exception '[ERR:referenced_by_submission] Objeto vinculado a submissão persistida não pode sofrer compensação.'
      using errcode = '42501';
  end if;

  update public.document_submission_intents
     set status = p_outcome_status,
         error_code = nullif(pg_catalog.btrim(coalesce(p_error_code, '')), ''),
         error_detail = pg_catalog.substr(nullif(pg_catalog.btrim(coalesce(p_error_detail, '')), ''), 1, 500)
   where id = v_intent.id
  returning * into v_intent;

  return pg_catalog.jsonb_build_object(
    'intent_id', v_intent.id,
    'status', v_intent.status,
    'storage_path', v_intent.storage_path
  );
end;
$$;

-- ============================================================================
-- 5. Privilégios mínimos explícitos (nunca expor RPCs internas ao cliente)
-- ============================================================================

revoke all on function public.assert_submission_backend_caller() from public, anon, authenticated;
grant execute on function public.assert_submission_backend_caller() to service_role;

revoke all on function public.prepare_document_submission(uuid, uuid, uuid, text, bigint, text, bigint)
  from public, anon, authenticated;
grant execute on function public.prepare_document_submission(uuid, uuid, uuid, text, bigint, text, bigint)
  to service_role;

revoke all on function public.finalize_document_submission(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.finalize_document_submission(uuid, uuid)
  to service_role;

revoke all on function public.prepare_submission_orphan_cleanup(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.prepare_submission_orphan_cleanup(uuid, text, text)
  to service_role;

revoke all on function public.compensate_document_submission_intent(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.compensate_document_submission_intent(uuid, text, text, text)
  to service_role;
