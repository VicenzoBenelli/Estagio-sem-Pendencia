begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(76);

-- ============================================================================
-- 1. Estado do bucket, policy e semântica nula de storage.allow_any_operation
-- ============================================================================

select is(
  (
    select row(public, file_size_limit, allowed_mime_types)::text
    from storage.buckets
    where id = 'internship-documents'
  ),
  row(false, 5242880::bigint, array['application/pdf']::text[])::text,
  'Bucket internship-documents permanece privado (5 MiB, application/pdf)'
);

select is(
  (
    select (
      (
        select count(*)::integer
        from pg_policies
        where schemaname = 'storage'
          and tablename = 'objects'
          and (roles && array['anon'::name, 'authenticated'::name])
      ) = 0
      and (
        select count(*)::integer
        from pg_policies
        where schemaname = 'storage'
          and tablename = 'buckets'
          and (roles && array['anon'::name, 'authenticated'::name])
      ) = 0
      and (
        select bool_and(c.relrowsecurity)
        from pg_class as c
        join pg_namespace as n on n.oid = c.relnamespace
        where n.nspname = 'storage'
          and c.relname in ('objects', 'buckets')
      ) = true
    )
  ),
  true,
  'Gateway ativo: storage.objects e storage.buckets permanecem deny-by-default (0 policies anon/authenticated e RLS ativa)'
);

select is(
  (
    select (storage.operation() is null)
      and (not storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info']))
  ),
  true,
  'storage.allow_any_operation retorna false quando storage.operation() é NULL'
);

-- ============================================================================
-- 2. Fixtures isoladas (E1 dono, E2 outro estudante, R1 ativo, R2 fora, R3 revogado, R4 inativo)
-- ============================================================================

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  (
    '00000000-0000-4000-8000-000000000000',
    'a5000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated',
    'estudante.e1.fix@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante E1 Fix"}'::jsonb, now(), now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'b5000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated',
    'estudante.e2.fix@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante E2 Fix"}'::jsonb, now(), now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'c5000000-0000-4000-8000-000000000003',
    'authenticated', 'authenticated',
    'revisor.r1.fix@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R1 Ativo Fix"}'::jsonb, now(), now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'd5000000-0000-4000-8000-000000000004',
    'authenticated', 'authenticated',
    'revisor.r2.fix@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R2 Fora Escopo Fix"}'::jsonb, now(), now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'e5000000-0000-4000-8000-000000000005',
    'authenticated', 'authenticated',
    'revisor.r3.fix@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R3 Revogado Fix"}'::jsonb, now(), now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'f5000000-0000-4000-8000-000000000006',
    'authenticated', 'authenticated',
    'revisor.r4.inativo.fix@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R4 Inativo Fix"}'::jsonb, now(), now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    '05000000-0000-4000-8000-000000000007',
    'authenticated', 'authenticated',
    'revisor.r5.curso.fix@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R5 Curso Fix"}'::jsonb, now(), now()
  );

select public.admin_set_user_role('c5000000-0000-4000-8000-000000000003', 'reviewer', 'technical_automation', 'pgtap:00005', 'Fixture R1 Fix');
select public.admin_set_user_role('d5000000-0000-4000-8000-000000000004', 'reviewer', 'technical_automation', 'pgtap:00005', 'Fixture R2 Fix');
select public.admin_set_user_role('e5000000-0000-4000-8000-000000000005', 'reviewer', 'technical_automation', 'pgtap:00005', 'Fixture R3 Fix');
select public.admin_set_user_role('f5000000-0000-4000-8000-000000000006', 'reviewer', 'technical_automation', 'pgtap:00005', 'Fixture R4 Fix');
select public.admin_set_user_role('05000000-0000-4000-8000-000000000007', 'reviewer', 'technical_automation', 'pgtap:00005', 'Fixture R5 Curso Fix');

insert into public.institutions (id, code, name, is_demo, active)
values
  ('51000000-0000-4000-8000-000000000001', 'FIX_INST_A', 'Instituicao Fix A', true, true),
  ('51000000-0000-4000-8000-000000000002', 'FIX_INST_B', 'Instituicao Fix B', true, true);

insert into public.courses (id, institution_id, code, name, is_demo, active)
values
  ('52000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001', 'FIX_CUR_A', 'Curso Fix A', true, true),
  ('52000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000002', 'FIX_CUR_B', 'Curso Fix B', true, true),
  ('52000000-0000-4000-8000-000000000003', '51000000-0000-4000-8000-000000000001', 'FIX_CUR_A2', 'Curso Fix A2 Mesma Inst', true, true);

insert into public.course_modalities (id, course_id, code, name, is_mandatory, is_demo, active)
values
  ('53000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000001', 'FIX_MOD_A', 'Modalidade Fix A', true, true, true),
  ('53000000-0000-4000-8000-000000000002', '52000000-0000-4000-8000-000000000002', 'FIX_MOD_B', 'Modalidade Fix B', true, true, true),
  ('53000000-0000-4000-8000-000000000003', '52000000-0000-4000-8000-000000000001', 'FIX_MOD_A2', 'Modalidade Fix A2 Mesmo Curso', false, true, true),
  ('53000000-0000-4000-8000-000000000004', '52000000-0000-4000-8000-000000000003', 'FIX_MOD_CUR_A2', 'Modalidade Fix Outro Curso Mesma Inst', true, true, true);

insert into public.requirement_templates (id, institution_id, course_id, course_modality_id, version, title, source_reference, status, is_demo)
values
  ('54000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001', 1, 'Template Fix A', 'Fictício Fix A', 'draft', true),
  ('54000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000002', '52000000-0000-4000-8000-000000000002', '53000000-0000-4000-8000-000000000002', 1, 'Template Fix B', 'Fictício Fix B', 'draft', true),
  ('54000000-0000-4000-8000-000000000003', '51000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000003', 1, 'Template Fix A2 Mod', 'Fictício Fix A2 Mod', 'draft', true),
  ('54000000-0000-4000-8000-000000000004', '51000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000003', '53000000-0000-4000-8000-000000000004', 1, 'Template Fix Cur A2', 'Fictício Fix Cur A2', 'draft', true);

insert into public.requirement_template_items (id, template_id, code, title, description, acceptance_criteria, is_required, display_order, is_demo)
values
  ('55000000-0000-4000-8000-000000000001', '54000000-0000-4000-8000-000000000001', 'FIX_REQ_ACTIVE', 'Documento Vigente Fix', 'Enviar PDF vigente', 'PDF válido', true, 1, true),
  ('55000000-0000-4000-8000-000000000002', '54000000-0000-4000-8000-000000000001', 'FIX_REQ_ARCH', 'Documento Arquivado Fix', 'Enviar PDF para teste archived', 'PDF válido', true, 2, true),
  ('55000000-0000-4000-8000-000000000003', '54000000-0000-4000-8000-000000000001', 'FIX_REQ_DEL', 'Documento Delete Marker Fix', 'Enviar PDF para teste delete marker', 'PDF válido', false, 3, true),
  ('55000000-0000-4000-8000-000000000004', '54000000-0000-4000-8000-000000000001', 'FIX_REQ_UNLINK', 'Documento Nao Finalizado Fix', 'Item para testar objeto órfão não vinculado', 'PDF válido', false, 4, true),
  ('55000000-0000-4000-8000-000000000005', '54000000-0000-4000-8000-000000000002', 'FIX_REQ_B', 'Outro Escopo Fix', 'Outro documento', 'PDF válido', true, 1, true),
  ('55000000-0000-4000-8000-000000000006', '54000000-0000-4000-8000-000000000003', 'FIX_REQ_A2_MOD', 'Documento Modalidade 2 Mesmo Curso Fix', 'PDF segunda modalidade do mesmo curso', 'PDF válido', true, 1, true),
  ('55000000-0000-4000-8000-000000000007', '54000000-0000-4000-8000-000000000004', 'FIX_REQ_CUR_A2', 'Documento Outro Curso Mesma Instituicao Fix', 'PDF outro curso na mesma instituicao', 'PDF válido', true, 1, true);

update public.requirement_templates
   set status = 'published'
 where id in (
   '54000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000002',
   '54000000-0000-4000-8000-000000000003',
   '54000000-0000-4000-8000-000000000004'
 );

-- R1, R3 e R4 no escopo FIX_MOD_A; R2 em FIX_MOD_B; R5_CURSO em todo FIX_CUR_A (course_modality_id NULL)
select public.admin_assign_reviewer_scope('c5000000-0000-4000-8000-000000000003', '51000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001', 'technical_automation', 'pgtap:00005', 'R1 Escopo A');
select public.admin_assign_reviewer_scope('d5000000-0000-4000-8000-000000000004', '51000000-0000-4000-8000-000000000002', '52000000-0000-4000-8000-000000000002', '53000000-0000-4000-8000-000000000002', 'technical_automation', 'pgtap:00005', 'R2 Escopo B');
select set_config(
  'estagio.e3_assign_r3',
  (public.admin_assign_reviewer_scope('e5000000-0000-4000-8000-000000000005', '51000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001', 'technical_automation', 'pgtap:00005', 'R3 Antes da Revogacao')).id::text,
  true
);
select public.admin_assign_reviewer_scope('f5000000-0000-4000-8000-000000000006', '51000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001', 'technical_automation', 'pgtap:00005', 'R4 Inativo com escopo ativo');
select set_config(
  'estagio.e3_assign_r5_curso',
  (public.admin_assign_reviewer_scope('05000000-0000-4000-8000-000000000007', '51000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000001', null, 'technical_automation', 'pgtap:00005', 'R5 Escopo de curso inteiro (course_modality_id NULL)')).id::text,
  true
);

-- Desativa perfil de R4 preservando seu assignment ativo para validar checagem de profiles.active
select set_config('estagio.privileged_op', 'on', true);
update public.profiles
   set active = false
 where id = 'f5000000-0000-4000-8000-000000000006';
select set_config('estagio.privileged_op', '', true);

-- Abrir processo para E1 no escopo FIX_MOD_A e preparar 4 cenários de objetos
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select set_config('estagio.e3_proc_id', (public.create_internship_process('53000000-0000-4000-8000-000000000001')).id::text, true);
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  v_proc_id uuid := current_setting('estagio.e3_proc_id')::uuid;
  v_req_active uuid;
  v_req_arch uuid;
  v_req_del uuid;
  v_req_unlink uuid;
  v_prep jsonb;
begin
  select id into v_req_active from public.process_requirements where process_id = v_proc_id and code = 'FIX_REQ_ACTIVE';
  select id into v_req_arch from public.process_requirements where process_id = v_proc_id and code = 'FIX_REQ_ARCH';
  select id into v_req_del from public.process_requirements where process_id = v_proc_id and code = 'FIX_REQ_DEL';
  select id into v_req_unlink from public.process_requirements where process_id = v_proc_id and code = 'FIX_REQ_UNLINK';

  -- 1) Objeto ativo e finalizado em document_submissions
  v_prep := public.prepare_document_submission(
    'a5000000-0000-4000-8000-000000000001', v_req_active, '50000000-0000-4000-8000-000000000001'::uuid,
    'ativo_v1.pdf', 1024, repeat('1', 64), 5242880
  );
  perform set_config('estagio.e3_path_active', v_prep ->> 'storage_path', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  perform set_config(
    'estagio.e3_sub_active',
    public.finalize_document_submission('a5000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid) -> 'submission' ->> 'id',
    true
  );

  -- 2) Objeto finalizado, posteriormente arquivado em storage.objects
  v_prep := public.prepare_document_submission(
    'a5000000-0000-4000-8000-000000000001', v_req_arch, '50000000-0000-4000-8000-000000000002'::uuid,
    'arquivado_v1.pdf', 1024, repeat('2', 64), 5242880
  );
  perform set_config('estagio.e3_path_archived', v_prep ->> 'storage_path', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  perform set_config(
    'estagio.e3_sub_archived',
    public.finalize_document_submission('a5000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid) -> 'submission' ->> 'id',
    true
  );
  update storage.objects set archived_at = now() where bucket_id = 'internship-documents' and name = v_prep ->> 'storage_path';

  -- 3) Objeto finalizado, posteriormente marcado com is_delete_marker = true em storage.objects
  v_prep := public.prepare_document_submission(
    'a5000000-0000-4000-8000-000000000001', v_req_del, '50000000-0000-4000-8000-000000000003'::uuid,
    'delete_marker_v1.pdf', 1024, repeat('3', 64), 5242880
  );
  perform set_config('estagio.e3_path_deleted', v_prep ->> 'storage_path', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  perform set_config(
    'estagio.e3_sub_deleted',
    public.finalize_document_submission('a5000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid) -> 'submission' ->> 'id',
    true
  );
  update storage.objects set is_delete_marker = true where bucket_id = 'internship-documents' and name = v_prep ->> 'storage_path';

  -- 4) Objeto presente em storage.objects mas não finalizado em document_submissions
  v_prep := public.prepare_document_submission(
    'a5000000-0000-4000-8000-000000000001', v_req_unlink, '50000000-0000-4000-8000-000000000004'::uuid,
    'nao_vinculado.pdf', 1024, repeat('4', 64), 5242880
  );
  perform set_config('estagio.e3_path_unlinked', v_prep ->> 'storage_path', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
end;
$$;

-- ============================================================================
-- 3. Operação ausente (NULL antes de qualquer set_config) e R3 pré/pós-revogação
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (
    select case
      when storage.operation() is null then (
        select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')
      )
      else -1
    end
  ),
  0,
  'Operação ausente (storage.operation() IS NULL) é bloqueada para E1'
);

select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (
    select case
      when storage.operation() is null then (
        select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')
      )
      else -1
    end
  ),
  0,
  'Operação ausente (storage.operation() IS NULL) é bloqueada para R1'
);

-- Verificar R3 ANTES da revogação: leitura direta em storage.objects bloqueada, mas gateway backend autoriza
select set_config('request.jwt.claims', '{"sub":"e5000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select set_config('storage.operation', 'storage.object.get_authenticated', true);

select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Revisor R3 antes da revogação é bloqueado em storage.objects com storage.object.get_authenticated'
);

select set_config('storage.operation', 'object.get_authenticated_info', true);

select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Revisor R3 antes da revogação é bloqueado em storage.objects com object.get_authenticated_info'
);

reset role;
select set_config('request.jwt.claims', '', true);
select set_config('storage.operation', '', true);

select is(
  (
    public.authorize_document_submission_download(
      'e5000000-0000-4000-8000-000000000005'::uuid,
      current_setting('estagio.e3_sub_active')::uuid,
      5242880
    ) ->> 'access_role'
  ),
  'reviewer',
  'Revisor R3 antes da revogação é autorizado pelo gateway server-side'
);

-- Revogar R3 imediatamente
select public.admin_revoke_reviewer_assignment(
  current_setting('estagio.e3_assign_r3')::uuid,
  'technical_automation',
  'pgtap:00005',
  'Revogacao imediata R3 para matriz negativa'
);

-- ============================================================================
-- 4. Matriz de operações autorizadas vs todos os 7 perfis de atores
-- ============================================================================

-- 4A) storage.object.get_authenticated (fluxo local / direto)
set local role authenticated;
select set_config('storage.operation', 'storage.object.get_authenticated', true);

select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated] Estudante proprietário E1 permanece bloqueado na leitura direta de storage.objects'
);

select set_config('request.jwt.claims', '{"sub":"b5000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated] Estudante não proprietário E2 é bloqueado mesmo conhecendo path exato'
);

select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated] Revisor atribuído R1 permanece bloqueado na leitura direta de storage.objects'
);

select set_config('request.jwt.claims', '{"sub":"d5000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated] Revisor fora do escopo R2 é bloqueado mesmo conhecendo path exato'
);

select set_config('request.jwt.claims', '{"sub":"e5000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated] Revisor revogado R3 perde acesso imediatamente'
);

select set_config('request.jwt.claims', '{"sub":"f5000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated] Revisor inativo R4 (com assignment ativo) é bloqueado'
);

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated] Usuário anônimo é bloqueado mesmo conhecendo path exato'
);

-- 4B) object.get_authenticated sem prefixo storage.
set local role authenticated;
select set_config('storage.operation', 'object.get_authenticated', true);

select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated unprefixed] Estudante proprietário E1 é bloqueado em storage.objects'
);

select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated unprefixed] Revisor atribuído R1 é bloqueado em storage.objects'
);

-- 4C) object.get_authenticated_info (fluxo Cloud Storage v1.96.4)
select set_config('storage.operation', 'object.get_authenticated_info', true);

select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated_info] Estudante proprietário E1 permanece bloqueado no Storage direto'
);

select set_config('request.jwt.claims', '{"sub":"b5000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated_info] Estudante não proprietário E2 é bloqueado mesmo conhecendo path exato'
);

select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated_info] Revisor atribuído R1 permanece bloqueado no Storage direto'
);

select set_config('request.jwt.claims', '{"sub":"d5000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated_info] Revisor fora do escopo R2 é bloqueado mesmo conhecendo path exato'
);

select set_config('request.jwt.claims', '{"sub":"e5000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated_info] Revisor revogado R3 é bloqueado no fluxo Cloud'
);

select set_config('request.jwt.claims', '{"sub":"f5000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated_info] Revisor inativo R4 (com assignment ativo) é bloqueado no fluxo Cloud'
);

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  '[object.get_authenticated_info] Usuário anônimo é bloqueado no fluxo Cloud'
);

-- ============================================================================
-- 5. Negativas preservadas de operações não autorizadas para E1 e R1 (path exato conhecido)
-- ============================================================================

set local role authenticated;

-- storage.object.sign
select set_config('storage.operation', 'storage.object.sign', true);
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Estudante proprietário E1 permanece bloqueado para storage.object.sign'
);
select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Revisor atribuído R1 permanece bloqueado para storage.object.sign'
);

-- storage.object.sign_many
select set_config('storage.operation', 'storage.object.sign_many', true);
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Estudante proprietário E1 permanece bloqueado para storage.object.sign_many'
);
select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Revisor atribuído R1 permanece bloqueado para storage.object.sign_many'
);

-- storage.object.list
select set_config('storage.operation', 'storage.object.list', true);
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Estudante proprietário E1 permanece bloqueado para storage.object.list'
);
select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Revisor atribuído R1 permanece bloqueado para storage.object.list'
);

-- storage.object.list_v2
select set_config('storage.operation', 'storage.object.list_v2', true);
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Estudante proprietário E1 permanece bloqueado para storage.object.list_v2'
);
select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Revisor atribuído R1 permanece bloqueado para storage.object.list_v2'
);

-- storage.object.get_public
select set_config('storage.operation', 'storage.object.get_public', true);
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Estudante proprietário E1 permanece bloqueado para storage.object.get_public'
);
select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Revisor atribuído R1 permanece bloqueado para storage.object.get_public'
);

-- object.head_authenticated_info (mantida fechada sem necessidade comprovada)
select set_config('storage.operation', 'object.head_authenticated_info', true);
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Estudante proprietário E1 permanece bloqueado para object.head_authenticated_info'
);
select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Revisor atribuído R1 permanece bloqueado para object.head_authenticated_info'
);

-- Outras operações não autorizadas (info_authenticated, delete, copy, move, render, sign_upload_url, custom)
select is(
  (
    select coalesce(sum(cnt), 0)::integer
    from unnest(array[
      'storage.object.info_authenticated',
      'storage.object.delete',
      'storage.object.copy',
      'storage.object.move',
      'storage.render.image_authenticated',
      'storage.object.sign_upload_url',
      'custom.unexpected.operation'
    ]) as op(name)
    cross join lateral (
      select count(*)::integer as cnt
      from storage.objects o
      where set_config('storage.operation', op.name, true) is not null
        and set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true) is not null
        and o.bucket_id = 'internship-documents'
        and o.name = current_setting('estagio.e3_path_active')
    ) q
  ),
  0,
  'Outras operações não autorizadas (info_authenticated/delete/copy/move/render/upload_sign/custom) são bloqueadas para E1'
);

select is(
  (
    select coalesce(sum(cnt), 0)::integer
    from unnest(array[
      'storage.object.info_authenticated',
      'storage.object.delete',
      'storage.object.copy',
      'storage.object.move',
      'storage.render.image_authenticated',
      'storage.object.sign_upload_url',
      'custom.unexpected.operation'
    ]) as op(name)
    cross join lateral (
      select count(*)::integer as cnt
      from storage.objects o
      where set_config('storage.operation', op.name, true) is not null
        and set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true) is not null
        and o.bucket_id = 'internship-documents'
        and o.name = current_setting('estagio.e3_path_active')
    ) q
  ),
  0,
  'Outras operações não autorizadas (info_authenticated/delete/copy/move/render/upload_sign/custom) são bloqueadas para R1'
);

-- Operação vazia '' e authenticated sem claim sub (auth.uid() IS NULL)
select set_config('storage.operation', '', true);
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where storage.operation() = '' and bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Operação vazia ("") é bloqueada para estudante proprietário E1'
);
select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where storage.operation() = '' and bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Operação vazia ("") é bloqueada para revisor atribuído R1'
);

select set_config('storage.operation', 'object.get_authenticated_info', true);
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'internship-documents' and name = current_setting('estagio.e3_path_active')),
  0,
  'Role authenticated sem sub (auth.uid() IS NULL) permanece bloqueada mesmo com object.get_authenticated_info'
);

-- ============================================================================
-- 6. Preservação das travas de arquivamento, delete marker e vínculo com document_submissions
-- ============================================================================

select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (
    select coalesce(sum(cnt), 0)::integer
    from unnest(array['storage.object.get_authenticated', 'object.get_authenticated_info']) as op(name)
    cross join lateral (
      select count(*)::integer as cnt
      from storage.objects o
      where set_config('storage.operation', op.name, true) is not null
        and o.bucket_id = 'internship-documents'
        and o.name = current_setting('estagio.e3_path_archived')
    ) q
  ),
  0,
  'Objeto arquivado (archived_at NOT NULL) continua oculto para E1 em ambas as operações'
);

select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (
    select coalesce(sum(cnt), 0)::integer
    from unnest(array['storage.object.get_authenticated', 'object.get_authenticated_info']) as op(name)
    cross join lateral (
      select count(*)::integer as cnt
      from storage.objects o
      where set_config('storage.operation', op.name, true) is not null
        and o.bucket_id = 'internship-documents'
        and o.name = current_setting('estagio.e3_path_archived')
    ) q
  ),
  0,
  'Objeto arquivado (archived_at NOT NULL) continua oculto para R1 em ambas as operações'
);

select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (
    select coalesce(sum(cnt), 0)::integer
    from unnest(array['storage.object.get_authenticated', 'object.get_authenticated_info']) as op(name)
    cross join lateral (
      select count(*)::integer as cnt
      from storage.objects o
      where set_config('storage.operation', op.name, true) is not null
        and o.bucket_id = 'internship-documents'
        and o.name = current_setting('estagio.e3_path_deleted')
    ) q
  ),
  0,
  'Objeto com is_delete_marker = true continua oculto para E1 em ambas as operações'
);

select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (
    select coalesce(sum(cnt), 0)::integer
    from unnest(array['storage.object.get_authenticated', 'object.get_authenticated_info']) as op(name)
    cross join lateral (
      select count(*)::integer as cnt
      from storage.objects o
      where set_config('storage.operation', op.name, true) is not null
        and o.bucket_id = 'internship-documents'
        and o.name = current_setting('estagio.e3_path_deleted')
    ) q
  ),
  0,
  'Objeto com is_delete_marker = true continua oculto para R1 em ambas as operações'
);

select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (
    select coalesce(sum(cnt), 0)::integer
    from unnest(array['storage.object.get_authenticated', 'object.get_authenticated_info']) as op(name)
    cross join lateral (
      select count(*)::integer as cnt
      from storage.objects o
      where set_config('storage.operation', op.name, true) is not null
        and o.bucket_id = 'internship-documents'
        and o.name = current_setting('estagio.e3_path_unlinked')
    ) q
  ),
  0,
  'Objeto sem registro vinculado em document_submissions continua oculto para E1 em ambas as operações'
);

select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (
    select coalesce(sum(cnt), 0)::integer
    from unnest(array['storage.object.get_authenticated', 'object.get_authenticated_info']) as op(name)
    cross join lateral (
      select count(*)::integer as cnt
      from storage.objects o
      where set_config('storage.operation', op.name, true) is not null
        and o.bucket_id = 'internship-documents'
        and o.name = current_setting('estagio.e3_path_unlinked')
    ) q
  ),
  0,
  'Objeto sem registro vinculado em document_submissions continua oculto para R1 em ambas as operações'
);

-- ============================================================================
-- 7. Verificação direta da normalização de storage.allow_any_operation(text[])
-- ============================================================================

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (
    select row(
      (select set_config('storage.operation', 'storage.object.get_authenticated', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info'])),
      (select set_config('storage.operation', 'object.get_authenticated', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info'])),
      (select set_config('storage.operation', 'object.get_authenticated_info', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info'])),
      (select set_config('storage.operation', 'storage.object.get_authenticated_info', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info'])),
      (select set_config('storage.operation', 'storage.object.sign', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info'])),
      (select set_config('storage.operation', 'storage.object.sign_many', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info'])),
      (select set_config('storage.operation', 'storage.object.list', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info'])),
      (select set_config('storage.operation', 'storage.object.list_v2', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info'])),
      (select set_config('storage.operation', 'storage.object.get_public', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info'])),
      (select set_config('storage.operation', 'object.head_authenticated_info', true) is not null
        and storage.allow_any_operation(array['object.get_authenticated', 'object.get_authenticated_info']))
    )::text
  ),
  row(true, true, true, true, false, false, false, false, false, false)::text,
  'storage.allow_any_operation normaliza prefixo e restringe estritamente às operações autorizadas'
);

select set_config('storage.operation', '', true);

-- ============================================================================
-- 8. Matriz de equivalência do gateway public.authorize_document_submission_download
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select public.authorize_document_submission_download(
       'a5000000-0000-4000-8000-000000000001'::uuid,
       current_setting('estagio.e3_sub_active')::uuid,
       5242880
     ) $$,
  '42501',
  null,
  'authenticated não pode chamar authorize_document_submission_download diretamente'
);

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok(
  $$ select public.authorize_document_submission_download(
       'a5000000-0000-4000-8000-000000000001'::uuid,
       current_setting('estagio.e3_sub_active')::uuid,
       5242880
     ) $$,
  '42501',
  null,
  'anon não pode chamar authorize_document_submission_download diretamente'
);

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  row(
    public.authorize_document_submission_download(
      'a5000000-0000-4000-8000-000000000001'::uuid,
      current_setting('estagio.e3_sub_active')::uuid,
      5242880
    ) ->> 'access_role',
    public.authorize_document_submission_download(
      'a5000000-0000-4000-8000-000000000001'::uuid,
      current_setting('estagio.e3_sub_active')::uuid,
      5242880
    ) ->> 'storage_path'
  )::text,
  row('owner'::text, current_setting('estagio.e3_path_active'))::text,
  '[gateway] Estudante proprietário ativo E1 recebe storage_path autoritativo'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'b5000000-0000-4000-8000-000000000002'::uuid,
       current_setting('estagio.e3_sub_active')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Estudante não proprietário E2 é bloqueado sem oracle de existência'
);

select is(
  row(
    public.authorize_document_submission_download(
      'c5000000-0000-4000-8000-000000000003'::uuid,
      current_setting('estagio.e3_sub_active')::uuid,
      5242880
    ) ->> 'access_role',
    public.authorize_document_submission_download(
      'c5000000-0000-4000-8000-000000000003'::uuid,
      current_setting('estagio.e3_sub_active')::uuid,
      5242880
    ) ->> 'storage_path'
  )::text,
  row('reviewer'::text, current_setting('estagio.e3_path_active'))::text,
  '[gateway] Revisor atribuído ativo R1 recebe storage_path autoritativo'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'd5000000-0000-4000-8000-000000000004'::uuid,
       current_setting('estagio.e3_sub_active')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Revisor fora do escopo R2 é bloqueado sem oracle'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'e5000000-0000-4000-8000-000000000005'::uuid,
       current_setting('estagio.e3_sub_active')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Revisor revogado R3 permanece bloqueado imediatamente'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'f5000000-0000-4000-8000-000000000006'::uuid,
       current_setting('estagio.e3_sub_active')::uuid,
       5242880
     ) $$,
  '42501',
  null,
  '[gateway] Revisor inativo R4 é bloqueado mesmo com assignment ativo'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'a5000000-0000-4000-8000-000000000001'::uuid,
       current_setting('estagio.e3_sub_archived')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Objeto arquivado (archived_at NOT NULL) permanece bloqueado para E1'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'a5000000-0000-4000-8000-000000000001'::uuid,
       current_setting('estagio.e3_sub_deleted')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Objeto marcado como delete_marker permanece bloqueado para E1'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'a5000000-0000-4000-8000-000000000001'::uuid,
       '00000000-0000-4000-8000-000000000999'::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] submission_id inexistente retorna P0002 seguro'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'a5000000-0000-4000-8000-000000000001'::uuid,
       current_setting('estagio.e3_sub_active')::uuid,
       500
     ) $$,
  '42501',
  null,
  '[gateway] Documento acima de p_max_size_bytes é bloqueado'
);

-- ============================================================================
-- 9. Regressão E3-GATEWAY-FIX-BE: Níveis institucional/curso/modalidade e histórico
-- ============================================================================

-- Regra existente: atribuição puramente institucional (course_id IS NULL) é estruturalmente proibida (NOT NULL)
select throws_ok(
  $$ select public.admin_assign_reviewer_scope(
       '05000000-0000-4000-8000-000000000007'::uuid,
       '51000000-0000-4000-8000-000000000001'::uuid,
       null,
       null,
       'technical_automation',
       'pgtap:00005',
       'Tentativa invalida sem course_id'
     ) $$,
  '23502',
  null,
  '[gateway] Regra institucional existente: reviewer_assignments exige course_id NOT NULL (sem curinga global de instituição)'
);

-- Criar submissões extras em FIX_MOD_A2 (mesmo curso), FIX_CUR_A2 (mesma instituição, outro curso) e FIX_MOD_B (outra instituição)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b5000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select set_config('estagio.e3_proc_mod2', (public.create_internship_process('53000000-0000-4000-8000-000000000003')).id::text, true);
select set_config('estagio.e3_proc_cur2', (public.create_internship_process('53000000-0000-4000-8000-000000000004')).id::text, true);
select set_config('estagio.e3_proc_inst2', (public.create_internship_process('53000000-0000-4000-8000-000000000002')).id::text, true);
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  v_req_mod2 uuid;
  v_req_cur2 uuid;
  v_req_inst2 uuid;
  v_req_active uuid;
  v_prep jsonb;
begin
  select id into v_req_mod2 from public.process_requirements where process_id = current_setting('estagio.e3_proc_mod2')::uuid and code = 'FIX_REQ_A2_MOD';
  select id into v_req_cur2 from public.process_requirements where process_id = current_setting('estagio.e3_proc_cur2')::uuid and code = 'FIX_REQ_CUR_A2';
  select id into v_req_inst2 from public.process_requirements where process_id = current_setting('estagio.e3_proc_inst2')::uuid and code = 'FIX_REQ_B';
  select id into v_req_active from public.process_requirements where process_id = current_setting('estagio.e3_proc_id')::uuid and code = 'FIX_REQ_ACTIVE';

  v_prep := public.prepare_document_submission(
    'b5000000-0000-4000-8000-000000000002', v_req_mod2, '50000000-0000-4000-8000-000000000010'::uuid,
    'mod_a2_v1.pdf', 1024, repeat('a', 64), 5242880
  );
  perform set_config('estagio.e3_path_mod2', v_prep ->> 'storage_path', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  perform set_config(
    'estagio.e3_sub_mod2',
    public.finalize_document_submission('b5000000-0000-4000-8000-000000000002', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid) -> 'submission' ->> 'id',
    true
  );

  v_prep := public.prepare_document_submission(
    'b5000000-0000-4000-8000-000000000002', v_req_cur2, '50000000-0000-4000-8000-000000000011'::uuid,
    'cur_a2_v1.pdf', 1024, repeat('b', 64), 5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  perform set_config(
    'estagio.e3_sub_cur2',
    public.finalize_document_submission('b5000000-0000-4000-8000-000000000002', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid) -> 'submission' ->> 'id',
    true
  );

  v_prep := public.prepare_document_submission(
    'b5000000-0000-4000-8000-000000000002', v_req_inst2, '50000000-0000-4000-8000-000000000012'::uuid,
    'inst_b_v1.pdf', 1024, repeat('c', 64), 5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  perform set_config(
    'estagio.e3_sub_inst2',
    public.finalize_document_submission('b5000000-0000-4000-8000-000000000002', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid) -> 'submission' ->> 'id',
    true
  );

  -- Transforma estagio.e3_sub_active em versão histórica v1 e cria v2 vigente no mesmo requisito
  perform set_config('request.jwt.claims', '{"sub":"05000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform public.review_submission(
    current_setting('estagio.e3_sub_active')::uuid,
    'correction_requested',
    'Ajuste necessario para gerar versao historica v1',
    '50000000-0000-4000-8000-000000000013'::uuid
  );
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  v_prep := public.prepare_document_submission(
    'a5000000-0000-4000-8000-000000000001', v_req_active, '50000000-0000-4000-8000-000000000014'::uuid,
    'ativo_v2.pdf', 2048, repeat('5', 64), 5242880
  );
  perform set_config('estagio.e3_path_active_v2', v_prep ->> 'storage_path', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 2048));
  perform set_config(
    'estagio.e3_sub_active_v2',
    public.finalize_document_submission('a5000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid) -> 'submission' ->> 'id',
    true
  );
end;
$$;

-- Paridade com RLS de document_submissions e is_assigned_reviewer para R5_CURSO e R1_MODALIDADE
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"05000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
select is(
  row(
    (select count(*)::integer from public.document_submissions where id = current_setting('estagio.e3_sub_active')::uuid),
    (select count(*)::integer from public.document_submissions where id = current_setting('estagio.e3_sub_active_v2')::uuid),
    (select count(*)::integer from public.document_submissions where id = current_setting('estagio.e3_sub_mod2')::uuid),
    (select count(*)::integer from public.document_submissions where id = current_setting('estagio.e3_sub_cur2')::uuid),
    (select count(*)::integer from public.document_submissions where id = current_setting('estagio.e3_sub_inst2')::uuid)
  )::text,
  row(1, 1, 1, 0, 0)::text,
  '[RLS] Revisor de curso (course_modality_id NULL) consulta v1/v2 de FIX_MOD_A e FIX_MOD_A2, mas não vê outro curso da mesma instituição nem outra instituição'
);

select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  row(
    (select count(*)::integer from public.document_submissions where id = current_setting('estagio.e3_sub_active')::uuid),
    (select count(*)::integer from public.document_submissions where id = current_setting('estagio.e3_sub_mod2')::uuid),
    (select count(*)::integer from public.document_submissions where id = current_setting('estagio.e3_sub_cur2')::uuid)
  )::text,
  row(1, 0, 0)::text,
  '[RLS] Revisor de modalidade (FIX_MOD_A) vê apenas FIX_MOD_A e não vê outra modalidade do mesmo curso nem outro curso da instituição'
);

reset role;
select set_config('request.jwt.claims', '', true);

-- Gateway autoriza Revisor de Curso (R5_CURSO) para MOD_A v2, MOD_A2 e versão histórica v1
select is(
  row(
    public.authorize_document_submission_download('05000000-0000-4000-8000-000000000007'::uuid, current_setting('estagio.e3_sub_active_v2')::uuid, 5242880) ->> 'access_role',
    public.authorize_document_submission_download('05000000-0000-4000-8000-000000000007'::uuid, current_setting('estagio.e3_sub_active_v2')::uuid, 5242880) ->> 'storage_path'
  )::text,
  row('reviewer'::text, current_setting('estagio.e3_path_active_v2'))::text,
  '[gateway] Revisor atribuído ao curso (course_modality_id NULL) recebe autorização em FIX_MOD_A (v2)'
);

select is(
  row(
    public.authorize_document_submission_download('05000000-0000-4000-8000-000000000007'::uuid, current_setting('estagio.e3_sub_mod2')::uuid, 5242880) ->> 'access_role',
    public.authorize_document_submission_download('05000000-0000-4000-8000-000000000007'::uuid, current_setting('estagio.e3_sub_mod2')::uuid, 5242880) ->> 'storage_path'
  )::text,
  row('reviewer'::text, current_setting('estagio.e3_path_mod2'))::text,
  '[gateway] Revisor atribuído ao curso (course_modality_id NULL) recebe autorização em FIX_MOD_A2 (segunda modalidade do curso)'
);

select is(
  row(
    public.authorize_document_submission_download('05000000-0000-4000-8000-000000000007'::uuid, current_setting('estagio.e3_sub_active')::uuid, 5242880) ->> 'access_role',
    public.authorize_document_submission_download('05000000-0000-4000-8000-000000000007'::uuid, current_setting('estagio.e3_sub_active')::uuid, 5242880) ->> 'storage_path'
  )::text,
  row('reviewer'::text, current_setting('estagio.e3_path_active'))::text,
  '[gateway] Revisor atribuído ao curso acessa versão histórica v1 (correction_requested) após v2'
);

-- Negativas preservadas para Revisor de Curso: outro curso da MESMA instituição e outra instituição
select throws_ok(
  $$ select public.authorize_document_submission_download(
       '05000000-0000-4000-8000-000000000007'::uuid,
       current_setting('estagio.e3_sub_cur2')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Revisor atribuído ao curso FIX_CUR_A é bloqueado em outro curso (FIX_CUR_A2) da mesma instituição'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       '05000000-0000-4000-8000-000000000007'::uuid,
       current_setting('estagio.e3_sub_inst2')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Revisor atribuído ao curso FIX_CUR_A é bloqueado em outra instituição (FIX_INST_B)'
);

-- Revisor de Modalidade (R1): histórico v1 liberado, outra modalidade do mesmo curso e outro curso da instituição bloqueados
select is(
  row(
    public.authorize_document_submission_download('c5000000-0000-4000-8000-000000000003'::uuid, current_setting('estagio.e3_sub_active')::uuid, 5242880) ->> 'access_role',
    public.authorize_document_submission_download('c5000000-0000-4000-8000-000000000003'::uuid, current_setting('estagio.e3_sub_active')::uuid, 5242880) ->> 'storage_path'
  )::text,
  row('reviewer'::text, current_setting('estagio.e3_path_active'))::text,
  '[gateway] Revisor de modalidade R1 acessa versão histórica v1 após v2'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'c5000000-0000-4000-8000-000000000003'::uuid,
       current_setting('estagio.e3_sub_mod2')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Revisor de modalidade R1 não recebe escopo ampliado para outra modalidade (FIX_MOD_A2) do mesmo curso'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'c5000000-0000-4000-8000-000000000003'::uuid,
       current_setting('estagio.e3_sub_cur2')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Revisor de modalidade R1 é bloqueado em outro curso (FIX_CUR_A2) da mesma instituição'
);

-- Proprietário E1 (ativo) acessa versão histórica v1 e v2 vigente
select is(
  row(
    public.authorize_document_submission_download('a5000000-0000-4000-8000-000000000001'::uuid, current_setting('estagio.e3_sub_active')::uuid, 5242880) ->> 'access_role',
    public.authorize_document_submission_download('a5000000-0000-4000-8000-000000000001'::uuid, current_setting('estagio.e3_sub_active_v2')::uuid, 5242880) ->> 'access_role'
  )::text,
  row('owner'::text, 'owner'::text)::text,
  '[gateway] Proprietário ativo E1 acessa tanto versão histórica v1 quanto v2 vigente'
);

-- Revogação do assignment de curso bloqueia imediatamente MOD_A, MOD_A2 e histórico v1
select public.admin_revoke_reviewer_assignment(
  current_setting('estagio.e3_assign_r5_curso')::uuid,
  'technical_automation',
  'pgtap:00005',
  'Revogacao imediata do escopo de curso R5'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       '05000000-0000-4000-8000-000000000007'::uuid,
       current_setting('estagio.e3_sub_active_v2')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Revogação de atribuição de curso bloqueia FIX_MOD_A imediatamente'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       '05000000-0000-4000-8000-000000000007'::uuid,
       current_setting('estagio.e3_sub_mod2')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Revogação de atribuição de curso bloqueia FIX_MOD_A2 imediatamente'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       '05000000-0000-4000-8000-000000000007'::uuid,
       current_setting('estagio.e3_sub_active')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  '[gateway] Revogação de atribuição de curso bloqueia versão histórica v1 imediatamente'
);

select set_config('estagio.privileged_op', 'admin_deactivate_e1', true);
update public.profiles
   set active = false
 where id = 'a5000000-0000-4000-8000-000000000001';
select set_config('estagio.privileged_op', '', true);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'a5000000-0000-4000-8000-000000000001'::uuid,
       current_setting('estagio.e3_sub_active')::uuid,
       5242880
     ) $$,
  '42501',
  null,
  '[gateway] Estudante proprietário E1 desativado (profiles.active = false) é bloqueado'
);

select * from finish();

rollback;
