begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(60);

-- ============================================================================
-- 1. ESP-13 / ESP-14: Bucket privado, RLS restritiva no Storage e privilégios
-- ============================================================================

select is(
  (select public from storage.buckets where id = 'internship-documents'),
  false,
  'Bucket internship-documents existe e está configurado como private (public = false)'
);

select is(
  (select file_size_limit from storage.buckets where id = 'internship-documents'),
  5242880::bigint,
  'Bucket internship-documents define limite máximo inicial de 5 MiB'
);

select is(
  (select allowed_mime_types from storage.buckets where id = 'internship-documents'),
  array['application/pdf']::text[],
  'Bucket internship-documents aceita exclusivamente application/pdf'
);

select is(
  (
    select (
      (
        select count(*)::integer
        from pg_policies
        where schemaname = 'storage'
          and tablename = 'objects'
          and cmd = 'SELECT'
          and (roles && array['anon'::name, 'authenticated'::name])
      ) = 0
      and (
        select c.relrowsecurity
        from pg_class as c
        where c.oid = 'storage.objects'::regclass
      ) = true
    )
  ),
  true,
  'Gateway server-side ativo: zero policies SELECT diretas para anon/authenticated em storage.objects com RLS habilitada'
);

select is(
  (
    select count(*)::integer
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      and (roles && array['anon'::name, 'authenticated'::name])
  ),
  0,
  'Nenhuma policy de escrita direta para anon/authenticated existe em storage.objects'
);

select is(
  (
    select c.relrowsecurity
    from pg_class as c
    where c.oid = 'public.document_submission_intents'::regclass
  ),
  true,
  'Tabela interna document_submission_intents possui RLS habilitada'
);

select is(
  (
    has_table_privilege('anon', 'public.document_submission_intents', 'SELECT')
    or has_table_privilege('authenticated', 'public.document_submission_intents', 'SELECT')
    or has_table_privilege('authenticated', 'public.document_submission_intents', 'INSERT')
    or has_table_privilege('authenticated', 'public.document_submission_intents', 'UPDATE')
    or has_table_privilege('authenticated', 'public.document_submission_intents', 'DELETE')
    or has_table_privilege('authenticated', 'public.document_submissions', 'INSERT')
    or has_table_privilege('authenticated', 'public.document_submissions', 'UPDATE')
    or has_table_privilege('authenticated', 'public.document_submissions', 'DELETE')
  ),
  false,
  'anon e authenticated não possuem privilégios diretos em intents nem escrita em document_submissions'
);

select is(
  (
    has_function_privilege('public', 'public.prepare_document_submission(uuid, uuid, uuid, text, bigint, text, bigint, integer)', 'EXECUTE')
    or has_function_privilege('anon', 'public.prepare_document_submission(uuid, uuid, uuid, text, bigint, text, bigint, integer)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.prepare_document_submission(uuid, uuid, uuid, text, bigint, text, bigint, integer)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.finalize_document_submission(uuid, uuid, uuid)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.release_document_submission_attempt(uuid, uuid, text, text)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.prepare_submission_orphan_cleanup(uuid, text, text)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.compensate_document_submission_intent(uuid, text, text, text)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.assert_submission_backend_caller()', 'EXECUTE')
    or has_function_privilege('public', 'public.authorize_document_submission_download(uuid, uuid, bigint)', 'EXECUTE')
    or has_function_privilege('anon', 'public.authorize_document_submission_download(uuid, uuid, bigint)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.authorize_document_submission_download(uuid, uuid, bigint)', 'EXECUTE')
  ),
  false,
  'PUBLIC, anon e authenticated não possuem EXECUTE nas RPCs internas de submissão nem no gateway de download'
);

select is(
  (
    select count(*)::integer
    from pg_proc as p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in (
        'assert_submission_backend_caller',
        'prepare_document_submission',
        'finalize_document_submission',
        'release_document_submission_attempt',
        'prepare_submission_orphan_cleanup',
        'compensate_document_submission_intent',
        'authorize_document_submission_download'
      )
      and p.prosecdef = true
      and p.proconfig @> array['search_path=""']
  ),
  7,
  'Todas as 7 funções de submissão/download são SECURITY DEFINER com search_path vazio'
);

-- ============================================================================
-- 2. Fixtures isoladas do Lote 3
-- ============================================================================

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  (
    '00000000-0000-4000-8000-000000000000',
    'a3000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'estudante.a.l3@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante A Lote 3"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'b3000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'estudante.b.l3@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante B Lote 3"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'c3000000-0000-4000-8000-000000000003',
    'authenticated',
    'authenticated',
    'estudante.inativo.l3@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante Inativo Lote 3"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'd3000000-0000-4000-8000-000000000004',
    'authenticated',
    'authenticated',
    'revisor.r1.l3@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R1 Atribuido Lote 3"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'e3000000-0000-4000-8000-000000000005',
    'authenticated',
    'authenticated',
    'revisor.r2.l3@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R2 Outro Escopo Lote 3"}'::jsonb,
    now(),
    now()
  );

select set_config('estagio.privileged_op', 'on', true);
update public.profiles
   set active = false
 where id = 'c3000000-0000-4000-8000-000000000003';
select set_config('estagio.privileged_op', '', true);

select public.admin_set_user_role(
  'd3000000-0000-4000-8000-000000000004',
  'reviewer',
  'technical_automation',
  'pgtap:00003',
  'Fixture Revisor R1 Lote 3'
);

select public.admin_set_user_role(
  'e3000000-0000-4000-8000-000000000005',
  'reviewer',
  'technical_automation',
  'pgtap:00003',
  'Fixture Revisor R2 Lote 3'
);

insert into public.institutions (id, code, name, is_demo, active)
values
  ('31000000-0000-4000-8000-000000000001', 'L3_INST_A', 'Instituicao Demo Lote 3 A', true, true),
  ('31000000-0000-4000-8000-000000000002', 'L3_INST_B', 'Instituicao Demo Lote 3 B', true, true);

insert into public.courses (id, institution_id, code, name, is_demo, active)
values
  ('32000000-0000-4000-8000-000000000001', '31000000-0000-4000-8000-000000000001', 'L3_CCO', 'Ciencia da Computacao L3', true, true),
  ('32000000-0000-4000-8000-000000000002', '31000000-0000-4000-8000-000000000002', 'L3_OUT', 'Outro Curso L3', true, true);

insert into public.course_modalities (id, course_id, code, name, is_mandatory, is_demo, active)
values
  ('33000000-0000-4000-8000-000000000001', '32000000-0000-4000-8000-000000000001', 'L3_OBR', 'Obrigatorio L3', true, true, true),
  ('33000000-0000-4000-8000-000000000002', '32000000-0000-4000-8000-000000000002', 'L3_OUT_OBR', 'Outro Obrigatorio L3', true, true, true);

insert into public.requirement_templates (
  id, institution_id, course_id, course_modality_id, version, title, source_reference, status, is_demo
)
values
  ('34000000-0000-4000-8000-000000000001', '31000000-0000-4000-8000-000000000001', '32000000-0000-4000-8000-000000000001', '33000000-0000-4000-8000-000000000001', 1, 'Template L3 A', 'Fonte fictícia L3 A', 'draft', true),
  ('34000000-0000-4000-8000-000000000002', '31000000-0000-4000-8000-000000000002', '32000000-0000-4000-8000-000000000002', '33000000-0000-4000-8000-000000000002', 1, 'Template L3 B', 'Fonte fictícia L3 B', 'draft', true);

insert into public.requirement_template_items (id, template_id, code, title, description, acceptance_criteria, is_required, display_order, is_demo)
values
  ('35000000-0000-4000-8000-000000000001', '34000000-0000-4000-8000-000000000001', 'L3_TCE', 'Termo de Compromisso', 'Enviar TCE assinado', 'PDF legivel e assinado', true, 1, true),
  ('35000000-0000-4000-8000-000000000002', '34000000-0000-4000-8000-000000000001', 'L3_PAE', 'Plano de Atividades', 'Enviar plano opcional', 'PDF legivel', false, 2, true),
  ('35000000-0000-4000-8000-000000000003', '34000000-0000-4000-8000-000000000002', 'L3_OUT_TCE', 'Outro Termo', 'Outro requisito', 'PDF valido', true, 1, true);

update public.requirement_templates
   set status = 'published'
 where id in (
   '34000000-0000-4000-8000-000000000001',
   '34000000-0000-4000-8000-000000000002'
 );

select public.admin_assign_reviewer_scope(
  'd3000000-0000-4000-8000-000000000004',
  '31000000-0000-4000-8000-000000000001',
  '32000000-0000-4000-8000-000000000001',
  '33000000-0000-4000-8000-000000000001',
  'technical_automation',
  'pgtap:00003',
  'Assignment R1 no escopo A'
);

select public.admin_assign_reviewer_scope(
  'e3000000-0000-4000-8000-000000000005',
  '31000000-0000-4000-8000-000000000002',
  '32000000-0000-4000-8000-000000000002',
  '33000000-0000-4000-8000-000000000002',
  'technical_automation',
  'pgtap:00003',
  'Assignment R2 apenas no escopo B'
);

-- Abrir processo para Estudante A3 via RPC oficial
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select set_config('estagio.test_proc_a3', (public.create_internship_process('33000000-0000-4000-8000-000000000001')).id::text, true);

-- Abrir processo para Estudante B3 via RPC oficial
select set_config('request.jwt.claims', '{"sub":"b3000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select set_config('estagio.test_proc_b3', (public.create_internship_process('33000000-0000-4000-8000-000000000001')).id::text, true);

-- Tentar executar prepare_document_submission diretamente como authenticated deve falhar (42501)
select throws_ok(
  $$ select public.prepare_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       (select id from public.process_requirements limit 1),
       null,
       'teste.pdf',
       1024,
       repeat('a', 64),
       5242880
     ) $$,
  '42501',
  null,
  'authenticated não pode executar prepare_document_submission diretamente'
);

reset role;
select set_config('request.jwt.claims', '', true);

select set_config(
  'estagio.test_req_a3_obr',
  (
    select id::text
    from public.process_requirements
    where process_id = current_setting('estagio.test_proc_a3')::uuid
      and code = 'L3_TCE'
  ),
  true
);

select set_config(
  'estagio.test_req_a3_opc',
  (
    select id::text
    from public.process_requirements
    where process_id = current_setting('estagio.test_proc_a3')::uuid
      and code = 'L3_PAE'
  ),
  true
);

-- ============================================================================
-- 3. ESP-14: Rejeições de posse, perfil e parâmetros antes do upload
-- ============================================================================

select throws_ok(
  $$ select public.prepare_document_submission(
       'b3000000-0000-4000-8000-000000000002',
       current_setting('estagio.test_req_a3_obr')::uuid,
       null,
       'invasao.pdf',
       1024,
       repeat('a', 64),
       5242880
     ) $$,
  '42501',
  null,
  'Estudante B3 não pode preparar submissão em requisito do processo de A3'
);

select throws_ok(
  $$ select public.prepare_document_submission(
       'd3000000-0000-4000-8000-000000000004',
       current_setting('estagio.test_req_a3_obr')::uuid,
       null,
       'revisor.pdf',
       1024,
       repeat('a', 64),
       5242880
     ) $$,
  '42501',
  null,
  'Revisor R1 não pode preparar submissão documental'
);

select throws_ok(
  $$ select public.prepare_document_submission(
       'c3000000-0000-4000-8000-000000000003',
       current_setting('estagio.test_req_a3_obr')::uuid,
       null,
       'inativo.pdf',
       1024,
       repeat('a', 64),
       5242880
     ) $$,
  '42501',
  null,
  'Usuário inativo não pode preparar submissão documental'
);

select throws_ok(
  $$ select public.prepare_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       current_setting('estagio.test_req_a3_obr')::uuid,
       null,
       'vazio.pdf',
       0,
       repeat('a', 64),
       5242880
     ) $$,
  '22023',
  null,
  'Arquivo com 0 bytes é rejeitado no backend'
);

select throws_ok(
  $$ select public.prepare_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       current_setting('estagio.test_req_a3_obr')::uuid,
       null,
       'gigante.pdf',
       5242881,
       repeat('a', 64),
       5242880
     ) $$,
  '22023',
  null,
  'Arquivo acima do limite máximo configurado é rejeitado no backend'
);

-- ============================================================================
-- 4. Preparação v1, verificações anti-TOCTOU de storage.objects e commit v1
-- ============================================================================

do $$
declare
  v_prep jsonb;
begin
  v_prep := public.prepare_document_submission(
    'a3000000-0000-4000-8000-000000000001',
    current_setting('estagio.test_req_a3_obr')::uuid,
    '11111111-1111-4111-8111-111111111111'::uuid,
    'termo_v1.pdf',
    2048,
    repeat('1', 64),
    5242880
  );
  perform set_config('estagio.test_intent_v1', v_prep ->> 'intent_id', true);
  perform set_config('estagio.test_path_v1', v_prep ->> 'storage_path', true);
end;
$$;

select ok(
  current_setting('estagio.test_path_v1') ~ ('^processes/' || current_setting('estagio.test_proc_a3') || '/requirements/' || current_setting('estagio.test_req_a3_obr') || '/submissions/[0-9a-f-]{36}\.pdf$')
  and position('estudante' in lower(current_setting('estagio.test_path_v1'))) = 0
  and position('demo' in lower(current_setting('estagio.test_path_v1'))) = 0,
  'Path gerado no backend é opaco, determinístico por UUIDs e sem PII'
);

-- Antes do objeto existir em storage.objects, finalize falha
select throws_ok(
  $$ select public.finalize_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       current_setting('estagio.test_intent_v1')::uuid
     ) $$,
  'P0002',
  null,
  'finalize_document_submission rejeita quando objeto não existe em storage.objects'
);

-- Inserir objeto no storage.objects com MIME errado -> finalize rejeita
insert into storage.objects (bucket_id, name, metadata)
values (
  'internship-documents',
  current_setting('estagio.test_path_v1'),
  jsonb_build_object('mimetype', 'text/plain', 'size', 2048)
);

select throws_ok(
  $$ select public.finalize_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       current_setting('estagio.test_intent_v1')::uuid
     ) $$,
  '22023',
  null,
  'finalize_document_submission rejeita objeto cujo MIME em storage.objects não é application/pdf'
);

-- Corrigir MIME mas deixar tamanho divergente -> finalize rejeita
update storage.objects
   set metadata = jsonb_build_object('mimetype', 'application/pdf', 'size', 999)
 where bucket_id = 'internship-documents'
   and name = current_setting('estagio.test_path_v1');

select throws_ok(
  $$ select public.finalize_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       current_setting('estagio.test_intent_v1')::uuid
     ) $$,
  '22023',
  null,
  'finalize_document_submission rejeita objeto com tamanho divergente do intent'
);

-- Antes da finalização bem-sucedida, objeto não vinculado é invisível até para A3
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select set_config('storage.operation', 'storage.object.get_authenticated', true);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'Objeto ainda não vinculado em document_submissions é invisível mesmo ao dono no Storage'
);

reset role;
select set_config('request.jwt.claims', '', true);
select set_config('storage.operation', '', true);

-- Ajustar metadata real válida e finalizar v1 com sucesso
update storage.objects
   set metadata = jsonb_build_object('mimetype', 'application/pdf', 'size', 2048)
 where bucket_id = 'internship-documents'
   and name = current_setting('estagio.test_path_v1');

do $$
declare
  v_fin jsonb;
begin
  v_fin := public.finalize_document_submission(
    'a3000000-0000-4000-8000-000000000001',
    current_setting('estagio.test_intent_v1')::uuid
  );
  perform set_config('estagio.test_sub_v1', v_fin -> 'submission' ->> 'id', true);
end;
$$;

select is(
  (
    select row(status, current_version, current_submission_id)::text
    from public.process_requirements
    where id = current_setting('estagio.test_req_a3_obr')::uuid
  ),
  row('under_review'::text, 1, current_setting('estagio.test_sub_v1')::uuid)::text,
  'Finalização v1 atualiza atomicamente process_requirements para under_review e version = 1'
);

select is(
  (
    select count(*)::integer
    from public.audit_events
    where entity_table = 'document_submissions'
      and entity_id = current_setting('estagio.test_sub_v1')::uuid
      and event_type = 'document_submitted'
  ),
  1,
  'Auditoria document_submitted registrada após submissão v1'
);

-- ============================================================================
-- 5. Idempotência e bloqueios de concorrência/estado
-- ============================================================================

select is(
  (
    select (
      public.prepare_document_submission(
        'a3000000-0000-4000-8000-000000000001',
        current_setting('estagio.test_req_a3_obr')::uuid,
        '11111111-1111-4111-8111-111111111111'::uuid,
        'termo_v1.pdf',
        2048,
        repeat('1', 64),
        5242880
      ) ->> 'outcome'
    )
  ),
  'already_committed',
  'Retry idempotente com mesma chave e payload retorna already_committed mesmo com requisito under_review'
);

select throws_ok(
  $$ select public.prepare_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       current_setting('estagio.test_req_a3_obr')::uuid,
       '11111111-1111-4111-8111-111111111111'::uuid,
       'termo_v1_alterado.pdf',
       2048,
       repeat('2', 64),
       5242880
     ) $$,
  '23505',
  null,
  'Reuso da mesma chave de idempotência com arquivo diferente é rejeitado'
);

select throws_ok(
  $$ select public.prepare_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       current_setting('estagio.test_req_a3_obr')::uuid,
       '22222222-2222-4222-8222-222222222222'::uuid,
       'segundo.pdf',
       2048,
       repeat('3', 64),
       5242880
     ) $$,
  '42501',
  null,
  'Novo envio com requisito em status under_review é bloqueado'
);

select is(
  (
    select public.prepare_submission_orphan_cleanup(
      current_setting('estagio.test_intent_v1')::uuid,
      'forced_test',
      'should not clean committed'
    ) ->> 'safe_to_delete'
  ),
  'false',
  'prepare_submission_orphan_cleanup nunca marca objeto já persistido para exclusão'
);

select throws_ok(
  $$ select public.compensate_document_submission_intent(
       current_setting('estagio.test_intent_v1')::uuid,
       'orphan_cleaned',
       'forced',
       'must fail'
     ) $$,
  '42501',
  null,
  'compensate_document_submission_intent bloqueia compensação sobre intent já committed'
);

-- ============================================================================
-- 6. ESP-13: RLS de leitura em storage.objects e document_submissions
-- ============================================================================

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'anon não enxerga nenhum objeto PDF em storage.objects por força da RLS'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select set_config('storage.operation', 'storage.object.get_authenticated', true);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name, metadata)
     values ('internship-documents', 'direto/sem-edge.pdf', '{"mimetype":"application/pdf","size":100}'::jsonb) $$,
  '42501',
  null,
  'authenticated não pode inserir diretamente em storage.objects burlando a Edge Function'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'Estudante A3 não acessa objeto PDF diretamente em storage.objects após fechamento pelo gateway server-side'
);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'a3000000-0000-4000-8000-000000000001'::uuid,
       current_setting('estagio.test_sub_v1')::uuid,
       5242880
     ) $$,
  '42501',
  null,
  'authenticated não pode executar public.authorize_document_submission_download diretamente'
);

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (
    public.authorize_document_submission_download(
      'a3000000-0000-4000-8000-000000000001'::uuid,
      current_setting('estagio.test_sub_v1')::uuid,
      5242880
    ) ->> 'access_role'
  ),
  'owner',
  'Gateway backend autoriza Estudante A3 dono do processo a baixar v1 via authorize_document_submission_download'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select set_config('storage.operation', 'storage.object.sign', true);
select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'C3-01: Estudante A3 não pode listar/selecionar objeto para criação de URL assinada (object.sign)'
);

select set_config('storage.operation', '', true);
select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'C3-01: Consulta sem operação storage.object.get_authenticated é bloqueada'
);

select set_config('storage.operation', 'storage.object.get_authenticated', true);
select set_config('request.jwt.claims', '{"sub":"b3000000-0000-4000-8000-000000000002","role":"authenticated"}', true);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'Estudante B3 não acessa objeto PDF de A3 mesmo conhecendo o storage_path exato'
);

select set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000004","role":"authenticated"}', true);

select set_config('storage.operation', 'storage.object.sign', true);
select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'C3-01: Revisor R1 atribuído não consegue selecionar objeto para criação de URL assinada'
);

select set_config('storage.operation', 'storage.object.get_authenticated', true);
select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'Revisor R1 com assignment ativo também é bloqueado na leitura direta de storage.objects'
);

reset role;
select set_config('request.jwt.claims', '', true);
select set_config('storage.operation', '', true);

select is(
  (
    public.authorize_document_submission_download(
      'd3000000-0000-4000-8000-000000000004'::uuid,
      current_setting('estagio.test_sub_v1')::uuid,
      5242880
    ) ->> 'access_role'
  ),
  'reviewer',
  'Gateway backend autoriza Revisor R1 com assignment ativo no escopo a baixar o PDF submetido'
);

set local role authenticated;
select set_config('storage.operation', 'storage.object.get_authenticated', true);

select set_config('request.jwt.claims', '{"sub":"e3000000-0000-4000-8000-000000000005","role":"authenticated"}', true);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'Revisor R2 de outro escopo não acessa PDF de A3 mesmo conhecendo o storage_path'
);

reset role;
select set_config('request.jwt.claims', '', true);
select set_config('storage.operation', '', true);

-- Revogar assignment de R1 deve bloquear novos acessos imediatamente
select public.admin_revoke_reviewer_assignment(
  (
    select id
    from public.reviewer_assignments
    where reviewer_id = 'd3000000-0000-4000-8000-000000000004'
      and active = true
  ),
  'technical_automation',
  'pgtap:00003',
  'Revogacao imediata R1 Lote 3'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"d3000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
select set_config('storage.operation', 'storage.object.get_authenticated', true);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name = current_setting('estagio.test_path_v1')
  ),
  0,
  'Revisor R1 revogado permanece bloqueado em storage.objects'
);

reset role;
select set_config('request.jwt.claims', '', true);
select set_config('storage.operation', '', true);

select throws_ok(
  $$ select public.authorize_document_submission_download(
       'd3000000-0000-4000-8000-000000000004'::uuid,
       current_setting('estagio.test_sub_v1')::uuid,
       5242880
     ) $$,
  'P0002',
  null,
  'Revisor R1 revogado perde imediatamente autorização no gateway backend'
);

-- ============================================================================
-- 7. ESP-15: Reenvio pós-correção (v2), preservação de v1, imutabilidade e bloqueio após approved
-- ============================================================================

-- Simular revisão solicitando correção na v1 (Lote 4 implementará a RPC de revisão)
insert into public.document_reviews (
  process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
) values (
  current_setting('estagio.test_proc_a3')::uuid,
  current_setting('estagio.test_req_a3_obr')::uuid,
  current_setting('estagio.test_sub_v1')::uuid,
  'd3000000-0000-4000-8000-000000000004',
  'correction_requested',
  'Assinatura ilegivél na ultima página.'
);

update public.document_submissions
   set status = 'correction_requested'
 where id = current_setting('estagio.test_sub_v1')::uuid;

update public.process_requirements
   set status = 'correction_requested'
 where id = current_setting('estagio.test_req_a3_obr')::uuid;

-- Preparar e enviar v2
do $$
declare
  v_prep2 jsonb;
  v_fin2 jsonb;
begin
  v_prep2 := public.prepare_document_submission(
    'a3000000-0000-4000-8000-000000000001',
    current_setting('estagio.test_req_a3_obr')::uuid,
    '33333333-3333-4333-8333-333333333333'::uuid,
    'termo_corrigido_v2.pdf',
    3072,
    repeat('4', 64),
    5242880
  );
  perform set_config('estagio.test_intent_v2', v_prep2 ->> 'intent_id', true);
  perform set_config('estagio.test_path_v2', v_prep2 ->> 'storage_path', true);

  insert into storage.objects (bucket_id, name, metadata)
  values (
    'internship-documents',
    current_setting('estagio.test_path_v2'),
    jsonb_build_object('mimetype', 'application/pdf', 'size', 3072)
  );

  v_fin2 := public.finalize_document_submission(
    'a3000000-0000-4000-8000-000000000001',
    current_setting('estagio.test_intent_v2')::uuid
  );
  perform set_config('estagio.test_sub_v2', v_fin2 -> 'submission' ->> 'id', true);
end;
$$;

select is(
  (
    select array_agg(version order by version desc)
    from public.document_submissions
    where process_requirement_id = current_setting('estagio.test_req_a3_obr')::uuid
  ),
  array[2, 1],
  'Reenvio após correction_requested cria versão 2 preservando integralmente a versão 1'
);

select is(
  current_setting('estagio.test_path_v1') <> current_setting('estagio.test_path_v2'),
  true,
  'Versão 2 utiliza novo storage_path único sem sobrescrever o objeto da versão 1'
);

select is(
  (
    select row(status, current_version, current_submission_id)::text
    from public.process_requirements
    where id = current_setting('estagio.test_req_a3_obr')::uuid
  ),
  row('under_review'::text, 2, current_setting('estagio.test_sub_v2')::uuid)::text,
  'process_requirements atualizado para current_version = 2, current_submission_id = v2 e under_review'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select set_config('storage.operation', 'storage.object.get_authenticated', true);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'internship-documents'
      and name in (current_setting('estagio.test_path_v1'), current_setting('estagio.test_path_v2'))
  ),
  0,
  'Estudante A3 não acessa v1/v2 diretamente em storage.objects após fechamento pelo gateway'
);

reset role;
select set_config('request.jwt.claims', '', true);
select set_config('storage.operation', '', true);

select is(
  row(
    public.authorize_document_submission_download(
      'a3000000-0000-4000-8000-000000000001'::uuid,
      current_setting('estagio.test_sub_v1')::uuid,
      5242880
    ) ->> 'storage_path',
    public.authorize_document_submission_download(
      'a3000000-0000-4000-8000-000000000001'::uuid,
      current_setting('estagio.test_sub_v2')::uuid,
      5242880
    ) ->> 'storage_path'
  )::text,
  row(
    current_setting('estagio.test_path_v1'),
    current_setting('estagio.test_path_v2')
  )::text,
  'Gateway autoriza Estudante A3 a acessar tanto a versão v1 histórica quanto a versão v2 vigente'
);

-- Imutabilidade: não pode apagar nem alterar metadados/versão/path de submissões ou intents
select throws_ok(
  $$ delete from public.document_submissions where id = current_setting('estagio.test_sub_v1')::uuid $$,
  '42501',
  null,
  'Não é permitido excluir linhas de document_submissions'
);

select throws_ok(
  $$ update public.document_submissions set storage_path = 'tampered/path.pdf' where id = current_setting('estagio.test_sub_v1')::uuid $$,
  '42501',
  null,
  'storage_path em document_submissions é imutável'
);

select throws_ok(
  $$ update public.document_submissions set version = 99 where id = current_setting('estagio.test_sub_v2')::uuid $$,
  '42501',
  null,
  'version em document_submissions é imutável'
);

select throws_ok(
  $$ delete from public.document_submission_intents where id = current_setting('estagio.test_intent_v1')::uuid $$,
  '42501',
  null,
  'Registros de document_submission_intents não podem ser excluídos'
);

-- Compensaçao de tentativa abortada / órfã no requisito OPCIONAL não afeta REQ_A3 nem v1/v2
do $$
declare
  v_prep_orphan jsonb;
begin
  v_prep_orphan := public.prepare_document_submission(
    'a3000000-0000-4000-8000-000000000001',
    current_setting('estagio.test_req_a3_opc')::uuid,
    null,
    'orfao.pdf',
    1024,
    repeat('5', 64),
    5242880
  );
  perform set_config('estagio.test_intent_orphan', v_prep_orphan ->> 'intent_id', true);
  perform set_config('estagio.test_path_orphan', v_prep_orphan ->> 'storage_path', true);

  insert into storage.objects (bucket_id, name, metadata)
  values (
    'internship-documents',
    current_setting('estagio.test_path_orphan'),
    jsonb_build_object('mimetype', 'application/pdf', 'size', 1024)
  );
end;
$$;

select is(
  (
    select row(
      (public.prepare_submission_orphan_cleanup(
        current_setting('estagio.test_intent_orphan')::uuid,
        'simulated_failure',
        'cleanup allowed for unreferenced path'
      ) ->> 'safe_to_delete'),
      (public.compensate_document_submission_intent(
        current_setting('estagio.test_intent_orphan')::uuid,
        'orphan_cleaned',
        'simulated_failure',
        'cleaned'
      ) ->> 'status')
    )::text
  ),
  row('true'::text, 'orphan_cleaned'::text)::text,
  'Compensação de intenção não persistida libera apenas o path órfão para limpeza'
);

select is(
  (
    select count(*)::integer
    from public.document_submissions
    where process_requirement_id = current_setting('estagio.test_req_a3_opc')::uuid
  ),
  0,
  'Tentativa compensada não gera registro em document_submissions'
);

-- Aprovação de v2 bloqueia definitivamente novos envios para REQ_A3
insert into public.document_reviews (
  process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
) values (
  current_setting('estagio.test_proc_a3')::uuid,
  current_setting('estagio.test_req_a3_obr')::uuid,
  current_setting('estagio.test_sub_v2')::uuid,
  'd3000000-0000-4000-8000-000000000004',
  'approved',
  null
);

update public.document_submissions
   set status = 'approved'
 where id = current_setting('estagio.test_sub_v2')::uuid;

update public.process_requirements
   set status = 'approved'
 where id = current_setting('estagio.test_req_a3_obr')::uuid;

select throws_ok(
  $$ select public.prepare_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       current_setting('estagio.test_req_a3_obr')::uuid,
       null,
       'pos_aprovacao.pdf',
       1024,
       repeat('6', 64),
       5242880
     ) $$,
  '42501',
  null,
  'Requisito em status approved rejeita novas submissões'
);

select is(
  (
    select row(required_total, required_approved, progress_status, progress_percentage)::text
    from public.process_progress_v
    where process_id = current_setting('estagio.test_proc_a3')::uuid
  ),
  row(1::bigint, 1::bigint, 'documentally_complete'::text, 100.00::numeric(5, 2))::text,
  'Progresso calculado reflete aprovação documental sem interferência do item opcional sem envio'
);

-- Processo cancelado bloqueia envio no requisito opcional restante
update public.internship_processes
   set status = 'cancelled',
       closed_at = now()
 where id = current_setting('estagio.test_proc_a3')::uuid;

select throws_ok(
  $$ select public.prepare_document_submission(
       'a3000000-0000-4000-8000-000000000001',
       current_setting('estagio.test_req_a3_opc')::uuid,
       null,
       'processo_cancelado.pdf',
       1024,
       repeat('7', 64),
       5242880
     ) $$,
  '42501',
  null,
  'Processo cancelado rejeita novas submissões em qualquer requisito'
);

-- ============================================================================
-- 8. C3-02: Lease e recuperação segura de tentativas interrompidas em uploading
-- ============================================================================

select set_config(
  'estagio.test_req_b3_obr',
  (
    select id::text
    from public.process_requirements
    where process_id = current_setting('estagio.test_proc_b3')::uuid
      and code = 'L3_TCE'
  ),
  true
);

do $$
declare
  v_prep jsonb;
begin
  v_prep := public.prepare_document_submission(
    'b3000000-0000-4000-8000-000000000002',
    current_setting('estagio.test_req_b3_obr')::uuid,
    '77777777-7777-4777-8777-777777777777'::uuid,
    'b3_recuperavel.pdf',
    1024,
    repeat('8', 64),
    5242880,
    15
  );
  perform set_config('estagio.test_b3_intent', v_prep ->> 'intent_id', true);
  perform set_config('estagio.test_b3_lease_1', v_prep ->> 'lease_token', true);
  perform set_config('estagio.test_b3_path', v_prep ->> 'storage_path', true);
end;
$$;

-- Tentativa concorrente enquanto lease ainda está ativo recebe 55P03 (submission_in_progress)
select throws_ok(
  $$ select public.prepare_document_submission(
       'b3000000-0000-4000-8000-000000000002',
       current_setting('estagio.test_req_b3_obr')::uuid,
       '77777777-7777-4777-8777-777777777777'::uuid,
       'b3_recuperavel.pdf',
       1024,
       repeat('8', 64),
       5242880,
       15
     ) $$,
  '55P03',
  null,
  'C3-02: Retry simultâneo com lease ativo retorna 55P03 sem concorrência duplicada'
);

-- Objeto chega ao Storage, mas resposta se perde -> release_document_submission_attempt libera o lease
insert into storage.objects (bucket_id, name, metadata)
values (
  'internship-documents',
  current_setting('estagio.test_b3_path'),
  jsonb_build_object('mimetype', 'application/pdf', 'size', 1024)
);

select public.release_document_submission_attempt(
  current_setting('estagio.test_b3_intent')::uuid,
  current_setting('estagio.test_b3_lease_1')::uuid,
  'finalize_transport_error',
  'Simulacao queda de resposta com objeto presente'
);

do $$
declare
  v_reclaim jsonb;
begin
  v_reclaim := public.prepare_document_submission(
    'b3000000-0000-4000-8000-000000000002',
    current_setting('estagio.test_req_b3_obr')::uuid,
    '77777777-7777-4777-8777-777777777777'::uuid,
    'b3_recuperavel.pdf',
    1024,
    repeat('8', 64),
    5242880,
    15
  );
  perform set_config('estagio.test_b3_reclaim_outcome', v_reclaim ->> 'outcome', true);
  perform set_config('estagio.test_b3_lease_2', v_reclaim ->> 'lease_token', true);
end;
$$;

select is(
  current_setting('estagio.test_b3_reclaim_outcome'),
  'ready_to_finalize',
  'C3-02: Retry após intenção liberada com objeto já no Storage recupera em ready_to_finalize'
);

-- Lease token antigo da tentativa zumbi não consegue finalizar
select throws_ok(
  $$ select public.finalize_document_submission(
       'b3000000-0000-4000-8000-000000000002',
       current_setting('estagio.test_b3_intent')::uuid,
       current_setting('estagio.test_b3_lease_1')::uuid
     ) $$,
  '42501',
  null,
  'C3-02: Worker antigo com lease_token expirado/substituído não finaliza tentativa recuperada'
);

select is(
  (
    public.finalize_document_submission(
      'b3000000-0000-4000-8000-000000000002',
      current_setting('estagio.test_b3_intent')::uuid,
      current_setting('estagio.test_b3_lease_2')::uuid
    ) -> 'submission' ->> 'version'
  )::integer,
  1,
  'C3-02: Finalização com lease_token recuperado persiste versão v1'
);

select is(
  (
    select count(*)::integer
    from public.document_submissions
    where process_requirement_id = current_setting('estagio.test_req_b3_obr')::uuid
  ),
  1,
  'C3-02: Recuperação bem-sucedida gera exatamente 1 submissão v1 sem duplicação'
);

select * from finish();

rollback;
