-- Gate B3-R1 (C3-01 e C3-02): Correções incrementais sem alterar migrations anteriores.
-- 1) C3-01: Restringe leitura SELECT de storage.objects via authenticated exclusivamente à operação
--    object.get_authenticated (bloqueia criação de URLs assinadas / object.sign e listagens pelo cliente).
--    Observação: alterar esta RLS não invalida URLs assinadas anteriormente emitidas por HMAC antes da expiração.
-- 2) C3-02: Adiciona controle de lease em document_submission_intents e recuperação segura/concorrência-safe
--    para intenções interrompidas em 'uploading'.

-- ============================================================================
-- 1. C3-01: Restrição estrita da política SELECT no bucket privado
-- ============================================================================

drop policy if exists internship_documents_select_authorized on storage.objects;
create policy internship_documents_select_authorized
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'internship-documents'
    and auth.uid() is not null
    and storage.allow_only_operation('object.get_authenticated')
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
-- 2. C3-02: Lease e recuperação idempotente segura em document_submission_intents
-- ============================================================================

alter table public.document_submission_intents
  add column if not exists lease_token uuid not null default pg_catalog.gen_random_uuid(),
  add column if not exists lease_expires_at timestamptz not null default (pg_catalog.now() + interval '15 seconds');

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
       or new.submission_id is distinct from old.submission_id
       or new.storage_path is distinct from old.storage_path
       or new.lease_token is distinct from old.lease_token
       or new.lease_expires_at is distinct from old.lease_expires_at then
      raise exception 'Intenção de submissão em estado terminal (%) não pode ser alterada.', old.status
        using errcode = '42501';
    end if;
  elsif old.status = 'uploading' then
    if new.status not in ('uploading', 'committed', 'aborted', 'orphan_cleanup_pending', 'orphan_cleaned') then
      raise exception 'Transição inválida em document_submission_intents (% -> %).', old.status, new.status
        using errcode = '42501';
    end if;

    if new.status <> 'uploading' then
      if new.storage_path is distinct from old.storage_path then
        raise exception 'storage_path não pode mudar ao encerrar intenção de upload.'
          using errcode = '42501';
      end if;
    end if;
  elsif old.status = 'orphan_cleanup_pending' then
    if new.status not in ('orphan_cleanup_pending', 'orphan_cleaned')
       or new.storage_path is distinct from old.storage_path
       or new.lease_token is distinct from old.lease_token then
      raise exception 'Transição inválida após pendência de limpeza (% -> %).', old.status, new.status
        using errcode = '42501';
    end if;
  end if;

  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

drop function if exists public.prepare_document_submission(uuid, uuid, uuid, text, bigint, text, bigint);
create or replace function public.prepare_document_submission(
  p_actor_id uuid,
  p_process_requirement_id uuid,
  p_idempotency_key uuid,
  p_original_filename text,
  p_size_bytes bigint,
  p_sha256_checksum text,
  p_max_size_bytes bigint default 5242880,
  p_lease_ttl_seconds integer default 15
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
  v_storage_obj record;
  v_new_intent public.document_submission_intents;
  v_checksum text;
  v_clean_filename text;
  v_target_version integer;
  v_storage_path text;
  v_lease_token uuid;
  v_lease_expires_at timestamptz;
  v_ttl_seconds integer;
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

  v_ttl_seconds := coalesce(p_lease_ttl_seconds, 15);
  if v_ttl_seconds < 0 or v_ttl_seconds > 300 then
    raise exception '[ERR:invalid_input] Duração de lease inválida.'
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

  -- Verificação direta em document_submissions antes do estado 'under_review'
  if p_idempotency_key is not null then
    select ds.*
      into v_existing_sub
      from public.document_submissions as ds
     where ds.process_requirement_id = p_process_requirement_id
       and ds.idempotency_key = p_idempotency_key
     limit 1;

    if found then
      if v_existing_sub.submitted_by is distinct from p_actor_id
         or v_existing_sub.sha256_checksum is distinct from v_checksum
         or v_existing_sub.size_bytes is distinct from p_size_bytes then
        raise exception '[ERR:idempotency_mismatch] Chave de idempotência já associada a outro conteúdo.'
          using errcode = '23505';
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

      -- Intenção em 'uploading': diferenciar operação ativa (lease válido) de abandonada (lease expirado)
      if v_existing_intent.lease_expires_at > pg_catalog.now() then
        raise exception '[ERR:submission_in_progress] Submissão com esta chave de idempotência está ativa em outro envio.'
          using errcode = '55P03';
      end if;

      if v_req.status not in ('not_submitted', 'correction_requested')
         or v_existing_intent.target_version <> (v_req.current_version + 1) then
        update public.document_submission_intents
           set status = 'aborted',
               error_code = 'requirement_status_conflict',
               error_detail = 'Intenção abandonada superada por outra alteração de estado.'
         where id = v_existing_intent.id;

        raise exception '[ERR:requirement_status_conflict] Requisito no status atual (%) não aceita retomada deste envio.', v_req.status
          using errcode = '42501';
      end if;

      -- Verificar se o objeto desta tentativa abandonada já existe íntegro no Storage
      select
        o.id,
        nullif(o.metadata ->> 'size', '')::bigint as obj_size,
        o.metadata ->> 'mimetype' as obj_mimetype
      into v_storage_obj
      from storage.objects as o
      where o.bucket_id = v_existing_intent.storage_bucket
        and o.name = v_existing_intent.storage_path
        and o.archived_at is null
        and o.is_delete_marker = false;

      v_lease_token := pg_catalog.gen_random_uuid();
      v_lease_expires_at := pg_catalog.now() + (v_ttl_seconds * interval '1 second');

      if found
         and v_storage_obj.obj_mimetype = 'application/pdf'
         and v_storage_obj.obj_size = v_existing_intent.size_bytes then
        update public.document_submission_intents
           set lease_token = v_lease_token,
               lease_expires_at = v_lease_expires_at,
               error_code = null,
               error_detail = null
         where id = v_existing_intent.id
        returning * into v_existing_intent;

        return pg_catalog.jsonb_build_object(
          'outcome', 'ready_to_finalize',
          'intent_id', v_existing_intent.id,
          'lease_token', v_existing_intent.lease_token,
          'process_id', v_existing_intent.process_id,
          'process_requirement_id', v_existing_intent.process_requirement_id,
          'target_version', v_existing_intent.target_version,
          'storage_bucket', v_existing_intent.storage_bucket,
          'storage_path', v_existing_intent.storage_path
        );
      end if;

      -- Objeto não chegou ao Storage (ou estava inconsistente): aloca novo storage_path opaco mantendo o mesmo intent
      v_storage_path :=
        'processes/' || v_req.process_id::text
        || '/requirements/' || v_req.id::text
        || '/submissions/' || pg_catalog.gen_random_uuid()::text || '.pdf';

      update public.document_submission_intents
         set storage_path = v_storage_path,
             lease_token = v_lease_token,
             lease_expires_at = v_lease_expires_at,
             error_code = null,
             error_detail = null
       where id = v_existing_intent.id
      returning * into v_existing_intent;

      return pg_catalog.jsonb_build_object(
        'outcome', 'ready_to_upload',
        'intent_id', v_existing_intent.id,
        'lease_token', v_existing_intent.lease_token,
        'process_id', v_existing_intent.process_id,
        'process_requirement_id', v_existing_intent.process_requirement_id,
        'target_version', v_existing_intent.target_version,
        'storage_bucket', v_existing_intent.storage_bucket,
        'storage_path', v_existing_intent.storage_path
      );
    end if;
  end if;

  if v_req.status not in ('not_submitted', 'correction_requested') then
    raise exception '[ERR:requirement_status_conflict] Requisito no status atual (%) não aceita novo envio.', v_req.status
      using errcode = '42501';
  end if;

  v_target_version := v_req.current_version + 1;
  v_lease_token := pg_catalog.gen_random_uuid();
  v_lease_expires_at := pg_catalog.now() + (v_ttl_seconds * interval '1 second');
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
    status,
    lease_token,
    lease_expires_at
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
    'uploading',
    v_lease_token,
    v_lease_expires_at
  )
  returning * into v_new_intent;

  return pg_catalog.jsonb_build_object(
    'outcome', 'ready_to_upload',
    'intent_id', v_new_intent.id,
    'lease_token', v_new_intent.lease_token,
    'process_id', v_new_intent.process_id,
    'process_requirement_id', v_new_intent.process_requirement_id,
    'target_version', v_new_intent.target_version,
    'storage_bucket', v_new_intent.storage_bucket,
    'storage_path', v_new_intent.storage_path
  );
end;
$$;

drop function if exists public.finalize_document_submission(uuid, uuid);
create or replace function public.finalize_document_submission(
  p_actor_id uuid,
  p_intent_id uuid,
  p_lease_token uuid default null
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

  if p_lease_token is not null and v_intent.lease_token is distinct from p_lease_token then
    raise exception '[ERR:lease_lost] Intenção assumida por nova tentativa de recuperação.'
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

create or replace function public.release_document_submission_attempt(
  p_intent_id uuid,
  p_lease_token uuid,
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
  v_has_valid_object boolean := false;
  v_safe_code text;
  v_safe_detail text;
begin
  perform public.assert_submission_backend_caller();

  if p_intent_id is null or p_lease_token is null then
    raise exception '[ERR:invalid_input] intent_id e lease_token são obrigatórios.'
      using errcode = '22023';
  end if;

  select i.*
    into v_intent
    from public.document_submission_intents as i
   where i.id = p_intent_id
   for update;

  if not found then
    return pg_catalog.jsonb_build_object('action', 'intent_not_found');
  end if;

  if v_intent.status <> 'uploading' or v_intent.submission_id is not null then
    return pg_catalog.jsonb_build_object(
      'action', 'noop',
      'status', v_intent.status
    );
  end if;

  if v_intent.lease_token is distinct from p_lease_token then
    return pg_catalog.jsonb_build_object('action', 'noop_lease_mismatch');
  end if;

  if exists (
    select 1
      from public.document_submissions as ds
     where ds.storage_bucket = v_intent.storage_bucket
       and ds.storage_path = v_intent.storage_path
  ) then
    return pg_catalog.jsonb_build_object('action', 'noop_referenced_by_submission');
  end if;

  v_safe_code := nullif(pg_catalog.btrim(coalesce(p_error_code, '')), '');
  v_safe_detail := pg_catalog.substr(nullif(pg_catalog.btrim(coalesce(p_error_detail, '')), ''), 1, 500);

  select exists (
    select 1
      from storage.objects as o
     where o.bucket_id = v_intent.storage_bucket
       and o.name = v_intent.storage_path
       and o.archived_at is null
       and o.is_delete_marker = false
       and o.metadata ->> 'mimetype' = 'application/pdf'
       and nullif(o.metadata ->> 'size', '')::bigint = v_intent.size_bytes
  ) into v_has_valid_object;

  if v_has_valid_object then
    update public.document_submission_intents
       set lease_expires_at = pg_catalog.now(),
           error_code = v_safe_code,
           error_detail = v_safe_detail
     where id = v_intent.id;

    return pg_catalog.jsonb_build_object(
      'action', 'lease_released_object_present',
      'intent_id', v_intent.id,
      'status', 'uploading'
    );
  end if;

  update public.document_submission_intents
     set status = 'aborted',
         lease_expires_at = pg_catalog.now(),
         error_code = v_safe_code,
         error_detail = v_safe_detail
   where id = v_intent.id;

  return pg_catalog.jsonb_build_object(
    'action', 'aborted_no_object',
    'intent_id', v_intent.id,
    'status', 'aborted'
  );
end;
$$;

revoke all on function public.prepare_document_submission(uuid, uuid, uuid, text, bigint, text, bigint, integer)
  from public, anon, authenticated;
grant execute on function public.prepare_document_submission(uuid, uuid, uuid, text, bigint, text, bigint, integer)
  to service_role;

revoke all on function public.finalize_document_submission(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.finalize_document_submission(uuid, uuid, uuid)
  to service_role;

revoke all on function public.release_document_submission_attempt(uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.release_document_submission_attempt(uuid, uuid, text, text)
  to service_role;
