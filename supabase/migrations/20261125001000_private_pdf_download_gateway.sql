-- GATE E3-CACHE-FIX: Gateway server-side de download de PDF privado e bloqueio de leitura direta no Storage.
-- 1. Remove a policy SELECT direta para authenticated em storage.objects, tornando o schema storage
--    deny-by-default para anon e authenticated enquanto o bucket permanece privado e com RLS ativa.
-- 2. Cria RPC interna exclusiva de service_role (public.authorize_document_submission_download)
--    preservando equivalência de posse/revisor em escopo ativo, validação de perfil ativo, versões
--    históricas e integridade do objeto ativo (não arquivado, sem delete_marker, application/pdf, <= limite).

drop policy if exists internship_documents_select_authorized on storage.objects;

create or replace function public.authorize_document_submission_download(
  p_actor_id uuid,
  p_submission_id uuid,
  p_max_size_bytes bigint default 5242880
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile record;
  v_sub record;
  v_storage_obj record;
  v_obj_size bigint;
  v_is_owner boolean := false;
  v_is_reviewer boolean := false;
begin
  perform public.assert_submission_backend_caller();

  if p_actor_id is null
     or p_submission_id is null
     or p_max_size_bytes is null
     or p_max_size_bytes <= 0 then
    raise exception '[ERR:invalid_input] Parâmetros obrigatórios inválidos para autorização de download.'
      using errcode = '22023';
  end if;

  select
    p.id,
    p.role,
    p.active
  into v_profile
  from public.profiles as p
  where p.id = p_actor_id;

  if not found or v_profile.active is distinct from true then
    raise exception '[ERR:forbidden_inactive_profile] Perfil ausente ou inativo para acesso documental.'
      using errcode = '42501';
  end if;

  select
    ds.id,
    ds.process_id,
    ds.process_requirement_id,
    ds.version,
    ds.storage_bucket,
    ds.storage_path,
    ds.original_filename,
    ds.mime_type,
    ds.size_bytes,
    ds.sha256_checksum,
    ds.status,
    ds.submitted_at,
    ip.owner_id,
    ip.institution_id,
    ip.course_id,
    ip.course_modality_id
  into v_sub
  from public.document_submissions as ds
  join public.internship_processes as ip
    on ip.id = ds.process_id
  where ds.id = p_submission_id;

  -- Resposta uniforme para submissão inexistente, processo de terceiros ou falta de escopo (sem oracle).
  if not found then
    raise exception '[ERR:submission_not_found] Submissão documental não encontrada ou indisponível.'
      using errcode = 'P0002';
  end if;

  v_is_owner := (v_sub.owner_id = p_actor_id);

  if not v_is_owner and v_profile.role = 'reviewer' then
    select exists (
      select 1
      from public.reviewer_assignments as ra
      where ra.reviewer_id = p_actor_id
        and ra.institution_id = v_sub.institution_id
        and ra.course_id = v_sub.course_id
        and (
          ra.course_modality_id is null
          or ra.course_modality_id = v_sub.course_modality_id
        )
        and ra.active = true
        and ra.revoked_at is null
    )
    into v_is_reviewer;
  end if;

  if not v_is_owner and not v_is_reviewer then
    raise exception '[ERR:submission_not_found] Submissão documental não encontrada ou indisponível.'
      using errcode = 'P0002';
  end if;

  if v_sub.storage_bucket is distinct from 'internship-documents'
     or v_sub.storage_path is null
     or pg_catalog.length(pg_catalog.btrim(v_sub.storage_path)) = 0
     or position('..' in v_sub.storage_path) > 0
     or pg_catalog.substr(v_sub.storage_path, 1, 1) = '/'
     or v_sub.mime_type is distinct from 'application/pdf' then
    raise exception '[ERR:submission_not_found] Submissão documental não encontrada ou indisponível.'
      using errcode = 'P0002';
  end if;

  if v_sub.size_bytes <= 0 or v_sub.size_bytes > p_max_size_bytes then
    raise exception '[ERR:file_too_large] Documento excede o limite máximo permitido (% bytes).',
      p_max_size_bytes
      using errcode = '42501';
  end if;

  select
    o.id,
    o.bucket_id,
    o.name,
    o.archived_at,
    o.is_delete_marker,
    o.metadata ->> 'mimetype' as obj_mimetype,
    o.metadata ->> 'size' as raw_obj_size
  into v_storage_obj
  from storage.objects as o
  where o.bucket_id = v_sub.storage_bucket
    and o.name = v_sub.storage_path;

  if not found
     or v_storage_obj.archived_at is not null
     or v_storage_obj.is_delete_marker is distinct from false then
    raise exception '[ERR:storage_object_missing] Objeto PDF indisponível no repositório privado.'
      using errcode = 'P0002';
  end if;

  if v_storage_obj.raw_obj_size is null
     or v_storage_obj.raw_obj_size !~ '^[0-9]+$' then
    raise exception '[ERR:storage_size_mismatch] Tamanho do objeto no Storage inválido.'
      using errcode = 'P0002';
  end if;

  v_obj_size := v_storage_obj.raw_obj_size::bigint;

  if v_storage_obj.obj_mimetype is distinct from 'application/pdf' then
    raise exception '[ERR:storage_mime_mismatch] Tipo MIME do objeto no Storage inválido.'
      using errcode = 'P0002';
  end if;

  if v_obj_size <= 0
     or v_obj_size > p_max_size_bytes
     or v_obj_size is distinct from v_sub.size_bytes then
    raise exception '[ERR:storage_size_mismatch] Tamanho do objeto no Storage diverge da submissão.'
      using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'submission_id', v_sub.id,
    'process_id', v_sub.process_id,
    'process_requirement_id', v_sub.process_requirement_id,
    'version', v_sub.version,
    'storage_bucket', v_sub.storage_bucket,
    'storage_path', v_sub.storage_path,
    'original_filename', v_sub.original_filename,
    'mime_type', v_sub.mime_type,
    'size_bytes', v_sub.size_bytes,
    'sha256_checksum', v_sub.sha256_checksum,
    'access_role', case when v_is_owner then 'owner' else 'reviewer' end
  );
end;
$$;

revoke all on function public.authorize_document_submission_download(uuid, uuid, bigint)
  from public, anon, authenticated;

grant execute on function public.authorize_document_submission_download(uuid, uuid, bigint)
  to service_role;
