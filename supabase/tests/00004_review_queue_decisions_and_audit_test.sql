begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(60);

-- ============================================================================
-- 1. Privilégios, security_invoker e SECURITY DEFINER (ESP-18 / ESP-20 / ESP-21)
-- ============================================================================

select has_view('public', 'reviewer_queue_v', 'view reviewer_queue_v existe');
select has_view('public', 'process_audit_timeline_v', 'view process_audit_timeline_v existe');

select is(
  (
    select count(*)::integer
    from pg_class as c
    join pg_namespace as n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('reviewer_queue_v', 'process_audit_timeline_v')
      and c.relkind = 'v'
      and c.reloptions @> array['security_invoker=true']
  ),
  2,
  'reviewer_queue_v e process_audit_timeline_v usam security_invoker = true'
);

select is(
  (
    has_table_privilege('public', 'public.reviewer_queue_v', 'SELECT')
    or has_table_privilege('anon', 'public.reviewer_queue_v', 'SELECT')
    or has_table_privilege('public', 'public.process_audit_timeline_v', 'SELECT')
    or has_table_privilege('anon', 'public.process_audit_timeline_v', 'SELECT')
  ),
  false,
  'PUBLIC e anon não possuem SELECT em reviewer_queue_v nem process_audit_timeline_v'
);

select is(
  (
    has_table_privilege('authenticated', 'public.reviewer_queue_v', 'SELECT')
    and has_table_privilege('authenticated', 'public.process_audit_timeline_v', 'SELECT')
  ),
  true,
  'authenticated possui SELECT em reviewer_queue_v e process_audit_timeline_v'
);

select is(
  (
    select (p.prosecdef = true and p.proconfig @> array['search_path=""'])
    from pg_proc as p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'review_submission'
  ),
  true,
  'review_submission é SECURITY DEFINER com search_path vazio'
);

select is(
  (
    select (p.prosecdef = true and p.proconfig @> array['search_path=""'])
    from pg_proc as p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'get_scoped_actor_display_name'
  ),
  true,
  'get_scoped_actor_display_name é SECURITY DEFINER com search_path vazio'
);

select is(
  (
    has_function_privilege('public', 'public.review_submission(uuid, text, text, uuid)', 'EXECUTE')
    or has_function_privilege('anon', 'public.review_submission(uuid, text, text, uuid)', 'EXECUTE')
    or has_function_privilege('public', 'public.get_scoped_actor_display_name(uuid, uuid, text)', 'EXECUTE')
    or has_function_privilege('anon', 'public.get_scoped_actor_display_name(uuid, uuid, text)', 'EXECUTE')
  ),
  false,
  'PUBLIC e anon não possuem EXECUTE em review_submission nem get_scoped_actor_display_name'
);

select is(
  (
    has_function_privilege('authenticated', 'public.review_submission(uuid, text, text, uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.get_scoped_actor_display_name(uuid, uuid, text)', 'EXECUTE')
  ),
  true,
  'authenticated possui EXECUTE em review_submission e get_scoped_actor_display_name'
);

select is(
  (
    has_table_privilege('authenticated', 'public.document_reviews', 'INSERT')
    or has_table_privilege('authenticated', 'public.document_reviews', 'UPDATE')
    or has_table_privilege('authenticated', 'public.document_reviews', 'DELETE')
    or has_table_privilege('authenticated', 'public.audit_events', 'INSERT')
    or has_table_privilege('authenticated', 'public.audit_events', 'UPDATE')
    or has_table_privilege('authenticated', 'public.audit_events', 'DELETE')
    or has_table_privilege('authenticated', 'public.document_submissions', 'UPDATE')
    or has_table_privilege('authenticated', 'public.process_requirements', 'UPDATE')
    or has_table_privilege('authenticated', 'public.internship_processes', 'UPDATE')
  ),
  false,
  'authenticated não possui escrita direta em revisões, auditoria, submissões, requisitos ou processos'
);

-- ============================================================================
-- 2. Fixtures isoladas do Lote 4 (usuários, escopos, processos e submissões)
-- ============================================================================

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  (
    '00000000-0000-0000-0000-000000000000',
    'a4000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'estudante.a4.l4@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante A4 L4"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'b4000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'estudante.b4.l4@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante B4 L4"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'c4000000-0000-4000-8000-000000000003',
    'authenticated',
    'authenticated',
    'revisor.r1.l4@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R1 L4"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'd4000000-0000-4000-8000-000000000004',
    'authenticated',
    'authenticated',
    'revisor.r2.l4@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R2 Curso L4"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'e4000000-0000-4000-8000-000000000005',
    'authenticated',
    'authenticated',
    'revisor.r3.l4@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R3 Outro L4"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'f4000000-0000-4000-8000-000000000006',
    'authenticated',
    'authenticated',
    'revisor.r4.l4@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R4 Sem Escopo L4"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '14000000-0000-4000-8000-000000000007',
    'authenticated',
    'authenticated',
    'revisor.r5.inativo.l4@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R5 Inativo L4"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '24000000-0000-4000-8000-000000000008',
    'authenticated',
    'authenticated',
    'revisor.r6.gemeo.l4@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R6 Gemeo L4"}'::jsonb,
    now(),
    now()
  );

select public.admin_set_user_role('c4000000-0000-4000-8000-000000000003', 'reviewer', 'technical_automation', 'pgtap:00004', 'Fixture R1 L4');
select public.admin_set_user_role('d4000000-0000-4000-8000-000000000004', 'reviewer', 'technical_automation', 'pgtap:00004', 'Fixture R2 L4');
select public.admin_set_user_role('e4000000-0000-4000-8000-000000000005', 'reviewer', 'technical_automation', 'pgtap:00004', 'Fixture R3 L4');
select public.admin_set_user_role('f4000000-0000-4000-8000-000000000006', 'reviewer', 'technical_automation', 'pgtap:00004', 'Fixture R4 L4');
select public.admin_set_user_role('14000000-0000-4000-8000-000000000007', 'reviewer', 'technical_automation', 'pgtap:00004', 'Fixture R5 L4');
select public.admin_set_user_role('24000000-0000-4000-8000-000000000008', 'reviewer', 'technical_automation', 'pgtap:00004', 'Fixture R6 L4');

insert into public.institutions (id, code, name, is_demo, active)
values
  ('41000000-0000-4000-8000-000000000001', 'L4_INST_A', 'Instituicao Demo L4 A', true, true),
  ('41000000-0000-4000-8000-000000000002', 'L4_INST_B', 'Instituicao Demo L4 B', true, true);

insert into public.courses (id, institution_id, code, name, is_demo, active)
values
  ('42000000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-000000000001', 'L4_CUR_1', 'Curso Piloto L4 1', true, true),
  ('42000000-0000-4000-8000-000000000002', '41000000-0000-4000-8000-000000000002', 'L4_CUR_2', 'Curso Outro L4 2', true, true);

insert into public.course_modalities (id, course_id, code, name, is_mandatory, is_demo, active)
values
  ('43000000-0000-4000-8000-000000000001', '42000000-0000-4000-8000-000000000001', 'L4_MOD_1A', 'Obrigatorio L4 1A', true, true, true),
  ('43000000-0000-4000-8000-000000000002', '42000000-0000-4000-8000-000000000001', 'L4_MOD_1B', 'Somente Opcional L4 1B', false, true, true),
  ('43000000-0000-4000-8000-000000000003', '42000000-0000-4000-8000-000000000002', 'L4_MOD_2', 'Obrigatorio L4 2', true, true, true);

insert into public.requirement_templates (
  id, institution_id, course_id, course_modality_id, version, title, source_reference, status, is_demo
)
values
  ('44000000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-000000000001', '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000001', 1, 'Template L4 1A', 'Dados fictícios L4 1A', 'draft', true),
  ('44000000-0000-4000-8000-000000000002', '41000000-0000-4000-8000-000000000001', '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000002', 1, 'Template L4 1B', 'Dados fictícios L4 1B', 'draft', true),
  ('44000000-0000-4000-8000-000000000003', '41000000-0000-4000-8000-000000000002', '42000000-0000-4000-8000-000000000002', '43000000-0000-4000-8000-000000000003', 1, 'Template L4 2', 'Dados fictícios L4 2', 'draft', true);

insert into public.requirement_template_items (id, template_id, code, title, description, acceptance_criteria, is_required, display_order, is_demo)
values
  ('45000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000001', 'L4_OBR_1', '[Demo L4] Termo Obrigatorio 1', 'Enviar termo', 'PDF assinado', true, 1, true),
  ('45000000-0000-4000-8000-000000000002', '44000000-0000-4000-8000-000000000001', 'L4_OBR_2', '[Demo L4] Plano Obrigatorio 2', 'Enviar plano', 'PDF completo', true, 2, true),
  ('45000000-0000-4000-8000-000000000003', '44000000-0000-4000-8000-000000000001', 'L4_OPC_1', '[Demo L4] Opcional 1', 'Enviar opcional 1', 'PDF legivel', false, 3, true),
  ('45000000-0000-4000-8000-000000000004', '44000000-0000-4000-8000-000000000001', 'L4_OPC_2', '[Demo L4] Opcional 2', 'Enviar opcional 2', 'PDF legivel', false, 4, true),
  ('45000000-0000-4000-8000-000000000005', '44000000-0000-4000-8000-000000000002', 'L4_ONLY_OPC', '[Demo L4] Unico Opcional', 'Somente opcional', 'PDF legivel', false, 1, true),
  ('45000000-0000-4000-8000-000000000006', '44000000-0000-4000-8000-000000000003', 'L4_OUT_1', '[Demo L4] Outro Curso', 'Outro documento', 'PDF valido', true, 1, true);

update public.requirement_templates
   set status = 'published'
 where id in (
   '44000000-0000-4000-8000-000000000001',
   '44000000-0000-4000-8000-000000000002',
   '44000000-0000-4000-8000-000000000003'
 );

-- Assignments: R1/R5/R6 -> MOD_L4_1A, R2 -> todo CUR_L4_1 (NULL), R3 -> MOD_L4_2
select set_config(
  'estagio.l4_assign_r1',
  (public.admin_assign_reviewer_scope(
    'c4000000-0000-4000-8000-000000000003',
    '41000000-0000-4000-8000-000000000001',
    '42000000-0000-4000-8000-000000000001',
    '43000000-0000-4000-8000-000000000001',
    'technical_automation',
    'pgtap:00004',
    'Escopo R1 apenas MOD_L4_1A'
  )).id::text,
  true
);

select public.admin_assign_reviewer_scope(
  'd4000000-0000-4000-8000-000000000004',
  '41000000-0000-4000-8000-000000000001',
  '42000000-0000-4000-8000-000000000001',
  null,
  'technical_automation',
  'pgtap:00004',
  'Escopo R2 para todo curso CUR_L4_1'
);

select public.admin_assign_reviewer_scope(
  'e4000000-0000-4000-8000-000000000005',
  '41000000-0000-4000-8000-000000000002',
  '42000000-0000-4000-8000-000000000002',
  '43000000-0000-4000-8000-000000000003',
  'technical_automation',
  'pgtap:00004',
  'Escopo R3 apenas MOD_L4_2'
);

select public.admin_assign_reviewer_scope(
  '14000000-0000-4000-8000-000000000007',
  '41000000-0000-4000-8000-000000000001',
  '42000000-0000-4000-8000-000000000001',
  '43000000-0000-4000-8000-000000000001',
  'technical_automation',
  'pgtap:00004',
  'Escopo R5 antes da desativacao'
);

select public.admin_assign_reviewer_scope(
  '24000000-0000-4000-8000-000000000008',
  '41000000-0000-4000-8000-000000000001',
  '42000000-0000-4000-8000-000000000001',
  '43000000-0000-4000-8000-000000000001',
  'technical_automation',
  'pgtap:00004',
  'Escopo R6 gemeo MOD_L4_1A'
);

-- Desativar R5 mantendo assignment ativo para comprovar checagem de profiles.active
select set_config('estagio.privileged_op', 'on', true);
update public.profiles
   set active = false
 where id = '14000000-0000-4000-8000-000000000007';
select set_config('estagio.privileged_op', '', true);

-- Abrir processos para A4 e B4
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select set_config('estagio.l4_proc_a4_1a', (public.create_internship_process('43000000-0000-4000-8000-000000000001')).id::text, true);
select set_config('estagio.l4_proc_a4_1b', (public.create_internship_process('43000000-0000-4000-8000-000000000002')).id::text, true);

select set_config('request.jwt.claims', '{"sub":"b4000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select set_config('estagio.l4_proc_b4_1a', (public.create_internship_process('43000000-0000-4000-8000-000000000001')).id::text, true);
select set_config('estagio.l4_proc_b4_2', (public.create_internship_process('43000000-0000-4000-8000-000000000003')).id::text, true);

reset role;
select set_config('request.jwt.claims', '', true);

select set_config('estagio.l4_req_a4_obr1', (select id::text from public.process_requirements where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid and code = 'L4_OBR_1'), true);
select set_config('estagio.l4_req_a4_obr2', (select id::text from public.process_requirements where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid and code = 'L4_OBR_2'), true);
select set_config('estagio.l4_req_a4_opc1', (select id::text from public.process_requirements where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid and code = 'L4_OPC_1'), true);
select set_config('estagio.l4_req_a4_opc2', (select id::text from public.process_requirements where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid and code = 'L4_OPC_2'), true);
select set_config('estagio.l4_req_a4_only_opt', (select id::text from public.process_requirements where process_id = current_setting('estagio.l4_proc_a4_1b')::uuid and code = 'L4_ONLY_OPC'), true);
select set_config('estagio.l4_req_b4_cancel', (select id::text from public.process_requirements where process_id = current_setting('estagio.l4_proc_b4_1a')::uuid and code = 'L4_OBR_1'), true);
select set_config('estagio.l4_req_b4_out', (select id::text from public.process_requirements where process_id = current_setting('estagio.l4_proc_b4_2')::uuid and code = 'L4_OUT_1'), true);

-- Submeter PDFs iniciais via fluxo oficial prepare + storage.objects + finalize
do $$
declare
  v_prep jsonb;
  v_fin jsonb;
begin
  -- A4 OBR1 v1
  v_prep := public.prepare_document_submission(
    'a4000000-0000-4000-8000-000000000001',
    current_setting('estagio.l4_req_a4_obr1')::uuid,
    'a4010000-0000-4000-8000-000000000001'::uuid,
    'a4_obr1_v1.pdf',
    1024,
    repeat('a', 64),
    5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  v_fin := public.finalize_document_submission('a4000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid);
  perform set_config('estagio.l4_sub_a4_obr1_v1', v_fin -> 'submission' ->> 'id', true);

  -- A4 OBR2 v1
  v_prep := public.prepare_document_submission(
    'a4000000-0000-4000-8000-000000000001',
    current_setting('estagio.l4_req_a4_obr2')::uuid,
    'a4020000-0000-4000-8000-000000000001'::uuid,
    'a4_obr2_v1.pdf',
    1024,
    repeat('b', 64),
    5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  v_fin := public.finalize_document_submission('a4000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid);
  perform set_config('estagio.l4_sub_a4_obr2_v1', v_fin -> 'submission' ->> 'id', true);

  -- A4 ONLY_OPC v1
  v_prep := public.prepare_document_submission(
    'a4000000-0000-4000-8000-000000000001',
    current_setting('estagio.l4_req_a4_only_opt')::uuid,
    'a4030000-0000-4000-8000-000000000001'::uuid,
    'a4_opt_only_v1.pdf',
    1024,
    repeat('c', 64),
    5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  v_fin := public.finalize_document_submission('a4000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid);
  perform set_config('estagio.l4_sub_a4_opt_only_v1', v_fin -> 'submission' ->> 'id', true);

  -- B4 processo que será cancelado após upload under_review
  v_prep := public.prepare_document_submission(
    'b4000000-0000-4000-8000-000000000002',
    current_setting('estagio.l4_req_b4_cancel')::uuid,
    'b4010000-0000-4000-8000-000000000001'::uuid,
    'b4_cancel_v1.pdf',
    1024,
    repeat('d', 64),
    5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  v_fin := public.finalize_document_submission('b4000000-0000-4000-8000-000000000002', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid);
  perform set_config('estagio.l4_sub_b4_cancel_v1', v_fin -> 'submission' ->> 'id', true);

  -- B4 outro curso (escopo R3)
  v_prep := public.prepare_document_submission(
    'b4000000-0000-4000-8000-000000000002',
    current_setting('estagio.l4_req_b4_out')::uuid,
    'b4020000-0000-4000-8000-000000000001'::uuid,
    'b4_out_v1.pdf',
    1024,
    repeat('e', 64),
    5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  v_fin := public.finalize_document_submission('b4000000-0000-4000-8000-000000000002', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid);
  perform set_config('estagio.l4_sub_b4_out_v1', v_fin -> 'submission' ->> 'id', true);
end;
$$;

-- Cancelar proc_b4_1a mantendo submissão under_review para testar exclusão absoluta da fila e bloqueio de revisão
update public.internship_processes
   set status = 'cancelled',
       closed_at = now()
 where id = current_setting('estagio.l4_proc_b4_1a')::uuid;

-- ============================================================================
-- 3. ESP-18: Isolamento, exclusão de cancelados, filtros e paginação na fila
-- ============================================================================

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select throws_ok(
  $$ select count(*) from public.reviewer_queue_v $$,
  '42501',
  null,
  'anon não pode consultar reviewer_queue_v'
);

set local role authenticated;

select set_config('request.jwt.claims', '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*)::integer from public.reviewer_queue_v),
  0,
  'estudante A4 vê zero itens na fila reviewer_queue_v mesmo tendo submissões próprias em análise'
);

select set_config('request.jwt.claims', '{"sub":"f4000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
select is(
  (select count(*)::integer from public.reviewer_queue_v),
  0,
  'revisor R4 sem atribuição vê zero itens na fila'
);

select set_config('request.jwt.claims', '{"sub":"14000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
select is(
  (select count(*)::integer from public.reviewer_queue_v),
  0,
  'revisor R5 com perfil inativo vê zero itens na fila mesmo com assignment ativo'
);

select set_config('request.jwt.claims', '{"sub":"c4000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (select count(*)::integer from public.reviewer_queue_v),
  2,
  'revisor R1 atribuído a MOD_L4_1A vê apenas os 2 itens não cancelados do seu escopo'
);

select is(
  (
    select count(*)::integer
    from public.reviewer_queue_v
    where process_id = current_setting('estagio.l4_proc_b4_1a')::uuid
  ),
  0,
  'processo cancelado com submissão under_review nunca aparece na fila do revisor'
);

select set_config('request.jwt.claims', '{"sub":"d4000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
select is(
  (select count(*)::integer from public.reviewer_queue_v),
  3,
  'revisor R2 com escopo de curso (course_modality_id NULL) vê itens de MOD_L4_1A e MOD_L4_1B, mas não CUR_L4_2'
);

select set_config('request.jwt.claims', '{"sub":"e4000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select is(
  (select count(*)::integer from public.reviewer_queue_v),
  1,
  'revisor R3 vê exclusivamente o item do seu escopo MOD_L4_2'
);

select set_config('request.jwt.claims', '{"sub":"d4000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
select is(
  (
    select count(*)::integer
    from public.reviewer_queue_v
    where course_modality_id = '43000000-0000-4000-8000-000000000001'
      and requirement_code = 'L4_OBR_2'
  ),
  1,
  'fila suporta filtragem combinada por modalidade e código de requisito'
);

select is(
  (
    with p1 as (
      select submission_id
      from public.reviewer_queue_v
      order by submitted_at asc, submission_id asc
      limit 1 offset 0
    ),
    p2 as (
      select submission_id
      from public.reviewer_queue_v
      order by submitted_at asc, submission_id asc
      limit 1 offset 1
    )
    select ((select submission_id from p1) is distinct from (select submission_id from p2)
            and (select count(*) from p1) = 1
            and (select count(*) from p2) = 1)
  ),
  true,
  'paginação determinística na fila (limit/offset) retorna itens distintos sem sobreposição'
);

select set_config('request.jwt.claims', '{"sub":"c4000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select is(
  (
    select student_name
    from public.reviewer_queue_v
    where submission_id = current_setting('estagio.l4_sub_a4_obr1_v1')::uuid
  ),
  'Estudante A4 L4',
  'reviewer_queue_v exibe student_name legível para o revisor autorizado'
);

-- ============================================================================
-- 4. ESP-20: Rejeições de autenticação, papel, escopo, cancelamento e validação
-- ============================================================================

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'approved', null, null) $$,
  '42501',
  null,
  'anon não pode executar review_submission'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'approved', null, null) $$,
  '42501',
  null,
  'authenticated sem sub no JWT não pode executar review_submission'
);

select set_config('request.jwt.claims', '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'approved', null, null) $$,
  '42501',
  null,
  'estudante A4 não pode aprovar nem revisar submissão'
);

select set_config('request.jwt.claims', '{"sub":"14000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'approved', null, null) $$,
  '42501',
  null,
  'revisor inativo R5 não pode revisar submissão'
);

select set_config('request.jwt.claims', '{"sub":"f4000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'approved', null, null) $$,
  '42501',
  null,
  'revisor R4 sem atribuição não pode revisar submissão'
);

select set_config('request.jwt.claims', '{"sub":"e4000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'approved', null, null) $$,
  '42501',
  null,
  'revisor R3 de outro escopo não pode revisar submissão fora do seu assignment'
);

select set_config('request.jwt.claims', '{"sub":"c4000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_b4_cancel_v1')::uuid, 'approved', null, null) $$,
  '42501',
  null,
  'processo cancelado não permite decisão mesmo para revisor do escopo'
);

select throws_ok(
  $$ select public.review_submission('99999999-9999-4999-8999-999999999999'::uuid, 'approved', null, null) $$,
  'P0002',
  null,
  'submissão inexistente retorna P0002'
);

select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'published', null, null) $$,
  '22023',
  null,
  'decisão fora de approved/correction_requested é rejeitada'
);

select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'correction_requested', null, null) $$,
  '22023',
  null,
  'correction_requested com motivo NULL é rejeitado'
);

select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'correction_requested', E'  \n\t  ', null) $$,
  '22023',
  null,
  'correction_requested com motivo contendo apenas espaços/quebras de linha é rejeitado'
);

select throws_ok(
  $$ select public.review_submission(current_setting('estagio.l4_sub_a4_obr1_v1')::uuid, 'correction_requested', repeat('x', 2001), null) $$,
  '22023',
  null,
  'justificativa acima de 2000 caracteres é rejeitada'
);

-- Processo sem itens obrigatórios (somente opcional): aprovar opcional não gera documentally_complete nem 100%
select set_config('request.jwt.claims', '{"sub":"d4000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
select is(
  (
    with res as (
      select public.review_submission(
        current_setting('estagio.l4_sub_a4_opt_only_v1')::uuid,
        'approved',
        null,
        'd4010000-0000-4000-8000-000000000001'::uuid
      ) as payload
    )
    select row(
      payload -> 'process' ->> 'status',
      payload -> 'progress' ->> 'progress_status',
      payload -> 'progress' ->> 'progress_percentage'
    )::text
    from res
  ),
  row('in_progress'::text, 'indeterminate'::text, null::text)::text,
  'aprovação de item opcional em processo sem obrigatórios mantém status in_progress e progresso indeterminate (nunca 100%)'
);

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (
    select count(*)::integer
    from public.document_reviews
    where submission_id = current_setting('estagio.l4_sub_a4_obr1_v1')::uuid
  ),
  0,
  'nenhuma tentativa negativa gerou registro parcial em document_reviews'
);

-- ============================================================================
-- 5. ESP-20: Decisão correction_requested, idempotência, concorrência lógica,
--    bloqueio de dupla decisão/versão obsoleta e reenvio v2 -> aprovação
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c4000000-0000-4000-8000-000000000003","role":"authenticated"}', true);

select is(
  (
    with res as (
      select public.review_submission(
        current_setting('estagio.l4_sub_a4_obr1_v1')::uuid,
        'correction_requested',
        '  Assinatura ausente na página 2.  ',
        '11111111-4444-4111-8111-111111111111'::uuid
      ) as payload
    )
    select row(
      (payload ->> 'ok')::boolean,
      (payload ->> 'idempotent_replay')::boolean,
      payload -> 'review' ->> 'decision',
      payload -> 'review' ->> 'reason',
      payload -> 'requirement' ->> 'status'
    )::text
    from res
  ),
  row(true, false, 'correction_requested'::text, 'Assinatura ausente na página 2.'::text, 'correction_requested'::text)::text,
  'review_submission registra correction_requested com motivo sanitizado atomicamente'
);

select is(
  (
    select row(ds.status, pr.status, pr.current_version)::text
    from public.document_submissions as ds
    join public.process_requirements as pr on pr.id = ds.process_requirement_id
    where ds.id = current_setting('estagio.l4_sub_a4_obr1_v1')::uuid
  ),
  row('correction_requested'::text, 'correction_requested'::text, 1)::text,
  'submissão v1 e requisito atualizados para correction_requested mantendo current_version = 1'
);

select is(
  (select count(*)::integer from public.reviewer_queue_v),
  1,
  'item decidido sai imediatamente da fila reviewer_queue_v de R1'
);

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (
    select count(*)::integer
    from public.audit_events
    where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid
      and entity_table = 'document_reviews'
      and event_type = 'document_correction_requested'
      and actor_id = 'c4000000-0000-4000-8000-000000000003'::uuid
      and target_user_id = 'a4000000-0000-4000-8000-000000000001'::uuid
      and metadata ->> 'reason' = 'Assinatura ausente na página 2.'
  ),
  1,
  'decisão correction_requested gera exatamente 1 audit_event com autor, alvo e justificativa'
);

-- Retry idempotente com mesma chave e payload retorna idempotent_replay=true sem duplicar
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c4000000-0000-4000-8000-000000000003","role":"authenticated"}', true);

select is(
  (
    with res as (
      select public.review_submission(
        current_setting('estagio.l4_sub_a4_obr1_v1')::uuid,
        'correction_requested',
        'Assinatura ausente na página 2.',
        '11111111-4444-4111-8111-111111111111'::uuid
      ) as payload
    )
    select row(
      (payload ->> 'idempotent_replay')::boolean,
      (select count(*)::integer from public.document_reviews where submission_id = current_setting('estagio.l4_sub_a4_obr1_v1')::uuid),
      (select count(*)::integer from public.audit_events where entity_table = 'document_reviews' and entity_id = (payload -> 'review' ->> 'id')::uuid)
    )::text
    from res
  ),
  row(true, 1, 1)::text,
  'retry idempotente retorna idempotent_replay=true sem duplicar review ou audit_event'
);

-- Reuso de chave de idempotência com decisão/conteúdo distinto falha com 23505
select throws_ok(
  $$ select public.review_submission(
       current_setting('estagio.l4_sub_a4_obr1_v1')::uuid,
       'approved',
       null,
       '11111111-4444-4111-8111-111111111111'::uuid
     ) $$,
  '23505',
  null,
  'reuso de idempotency_key com decisão divergente é rejeitado com 23505'
);

-- Outro revisor (R6) tentando decidir a mesma versão v1 é bloqueado com 23505
select set_config('request.jwt.claims', '{"sub":"24000000-0000-4000-8000-000000000008","role":"authenticated"}', true);
select throws_ok(
  $$ select public.review_submission(
       current_setting('estagio.l4_sub_a4_obr1_v1')::uuid,
       'approved',
       null,
       '22222222-4444-4222-8222-222222222222'::uuid
     ) $$,
  '23505',
  null,
  'dupla decisão por outro revisor na mesma versão v1 é bloqueada com 23505'
);

-- Reenvio v2 pelo estudante A4 volta à fila como is_resubmission=true e preserva v1
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  v_prep jsonb;
  v_fin jsonb;
begin
  v_prep := public.prepare_document_submission(
    'a4000000-0000-4000-8000-000000000001',
    current_setting('estagio.l4_req_a4_obr1')::uuid,
    'a4010000-0000-4000-8000-000000000002'::uuid,
    'a4_obr1_v2_corrigido.pdf',
    2048,
    repeat('f', 64),
    5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 2048));
  v_fin := public.finalize_document_submission('a4000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid);
  perform set_config('estagio.l4_sub_a4_obr1_v2', v_fin -> 'submission' ->> 'id', true);
end;
$$;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c4000000-0000-4000-8000-000000000003","role":"authenticated"}', true);

select is(
  (
    select row(
      count(*)::integer,
      bool_and(submission_id = current_setting('estagio.l4_sub_a4_obr1_v2')::uuid),
      bool_and(submission_version = 2 and is_resubmission = true)
    )::text
    from public.reviewer_queue_v
    where process_requirement_id = current_setting('estagio.l4_req_a4_obr1')::uuid
  ),
  row(1, true, true)::text,
  'reenvio v2 aparece na fila como is_resubmission=true e v1 permanece fora da fila'
);

-- Decidir v1 obsoleta (mesmo após v2 existir) é bloqueado
select throws_ok(
  $$ select public.review_submission(
       current_setting('estagio.l4_sub_a4_obr1_v1')::uuid,
       'approved',
       null,
       '33333333-4444-4333-8333-333333333333'::uuid
     ) $$,
  '23505',
  null,
  'decisão sobre versão obsoleta v1 quando v2 está vigente é bloqueada'
);

-- Aprovar OBR1 v2 -> progresso 50%, processo permanece in_progress
select is(
  (
    with res as (
      select public.review_submission(
        current_setting('estagio.l4_sub_a4_obr1_v2')::uuid,
        'approved',
        'Assinatura conferida.',
        '44444444-4444-4444-8444-444444444444'::uuid
      ) as payload
    )
    select row(
      payload -> 'process' ->> 'status',
      (payload -> 'progress' ->> 'required_approved')::integer,
      (payload -> 'progress' ->> 'progress_percentage')::numeric(5, 2)
    )::text
    from res
  ),
  row('in_progress'::text, 1, 50.00::numeric(5, 2))::text,
  'aprovação do primeiro obrigatório atualiza progresso para 50.00% e mantém processo in_progress'
);

-- Aprovar OBR2 v1 -> progresso 100%, processo transiciona para documentally_complete
select is(
  (
    with res as (
      select public.review_submission(
        current_setting('estagio.l4_sub_a4_obr2_v1')::uuid,
        'approved',
        null,
        '55555555-4444-4555-8555-555555555555'::uuid
      ) as payload
    )
    select row(
      payload -> 'process' ->> 'status',
      payload -> 'progress' ->> 'progress_status',
      (payload -> 'progress' ->> 'progress_percentage')::numeric(5, 2)
    )::text
    from res
  ),
  row('documentally_complete'::text, 'documentally_complete'::text, 100.00::numeric(5, 2))::text,
  'aprovação de todos os obrigatórios atualiza processo para documentally_complete e progresso para 100.00%'
);

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (
    select (
      count(*) = 1
      and bool_and((metadata ->> 'not_official_internship_authorization')::boolean = true)
    )
    from public.audit_events
    where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid
      and event_type = 'process_documentally_completed'
  ),
  true,
  'conclusão documental gera 1 evento process_documentally_completed com disclaimer de não autorização oficial'
);

-- Submeter e aprovar item opcional L4_OPC_1 em processo já documentally_complete não duplica evento de conclusão
do $$
declare
  v_prep jsonb;
  v_fin jsonb;
begin
  v_prep := public.prepare_document_submission(
    'a4000000-0000-4000-8000-000000000001',
    current_setting('estagio.l4_req_a4_opc1')::uuid,
    'a4040000-0000-4000-8000-000000000001'::uuid,
    'a4_opc1_v1.pdf',
    1024,
    repeat('1', 64),
    5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  v_fin := public.finalize_document_submission('a4000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid);
  perform set_config('estagio.l4_sub_a4_opc1_v1', v_fin -> 'submission' ->> 'id', true);
end;
$$;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c4000000-0000-4000-8000-000000000003","role":"authenticated"}', true);

select is(
  (
    with res as (
      select public.review_submission(
        current_setting('estagio.l4_sub_a4_opc1_v1')::uuid,
        'approved',
        null,
        '66666666-4444-4666-8666-666666666666'::uuid
      ) as payload
    )
    select (
      (payload ->> 'ok')::boolean
      and (
        select count(*)::integer
        from public.audit_events
        where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid
          and event_type = 'process_documentally_completed'
      ) = 1
    )
    from res
  ),
  true,
  'aprovação posterior de item opcional é permitida e não duplica evento process_documentally_completed'
);

reset role;
select set_config('request.jwt.claims', '', true);

-- Índice único estrutural impede duplicidade de evento para o mesmo registro em document_reviews
select throws_ok(
  $$
    insert into public.audit_events (
      event_type, actor_id, actor_role, operator_type, operator_identifier,
      target_user_id, process_id, entity_table, entity_id, metadata
    )
    select
      event_type, actor_id, actor_role, operator_type, operator_identifier,
      target_user_id, process_id, entity_table, entity_id, metadata
    from public.audit_events
    where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid
      and entity_table = 'document_reviews'
    limit 1
  $$,
  '23505',
  null,
  'índice único estrutural impede evento duplicado em audit_events para a mesma revisão'
);

select throws_ok(
  $$ delete from public.document_reviews where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid $$,
  '42501',
  null,
  'document_reviews permanece estritamente append-only e imutável'
);

-- ============================================================================
-- 6. ESP-21: Timeline imutável, resolução segura de autor, paginação e revogação
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select is(
  (
    select row(
      count(*)::integer,
      bool_or(event_type = 'document_correction_requested' and actor_display_name = 'Revisor R1 L4' and reason = 'Assinatura ausente na página 2.' and submission_version = 1),
      bool_or(event_type = 'document_approved' and actor_display_name = 'Revisor R1 L4' and submission_version = 2)
    )::text
    from public.process_audit_timeline_v
    where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid
  ),
  row(10, true, true)::text,
  'estudante A4 visualiza timeline completa do processo preservando autor, versão e justificativa'
);

select set_config('request.jwt.claims', '{"sub":"b4000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select is(
  (
    select count(*)::integer
    from public.process_audit_timeline_v
    where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid
  ),
  0,
  'estudante B4 não acessa timeline de auditoria de A4'
);

select set_config('request.jwt.claims', '{"sub":"e4000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select is(
  (
    select count(*)::integer
    from public.process_audit_timeline_v
    where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid
  ),
  0,
  'revisor R3 de outro escopo não acessa timeline de processo fora do seu assignment'
);

select is(
  public.get_scoped_actor_display_name(
    current_setting('estagio.l4_proc_a4_1a')::uuid,
    'c4000000-0000-4000-8000-000000000003'::uuid,
    'reviewer'
  ),
  null,
  'get_scoped_actor_display_name retorna NULL para usuário sem acesso ao processo'
);

select set_config('request.jwt.claims', '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (
    with page1 as (
      select event_id
      from public.process_audit_timeline_v
      where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid
      order by occurred_at desc, event_id desc
      limit 5 offset 0
    ),
    page2 as (
      select event_id
      from public.process_audit_timeline_v
      where process_id = current_setting('estagio.l4_proc_a4_1a')::uuid
      order by occurred_at desc, event_id desc
      limit 5 offset 5
    ),
    combined as (
      select event_id from page1
      union
      select event_id from page2
    )
    select (
      (select count(*)::integer from page1) = 5
      and (select count(*)::integer from page2) = 5
      and (select count(*)::integer from combined) = 10
    )
  ),
  true,
  'paginação da timeline (occurred_at desc, event_id desc) percorre os 10 eventos sem duplicação ou lacuna'
);

-- Submeter L4_OPC_2 e revogar R1: bloqueio imediato em fila, decisão, retry e auditoria
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  v_prep jsonb;
  v_fin jsonb;
begin
  v_prep := public.prepare_document_submission(
    'a4000000-0000-4000-8000-000000000001',
    current_setting('estagio.l4_req_a4_opc2')::uuid,
    'a4050000-0000-4000-8000-000000000001'::uuid,
    'a4_opc2_v1.pdf',
    1024,
    repeat('2', 64),
    5242880
  );
  insert into storage.objects (bucket_id, name, metadata)
  values ('internship-documents', v_prep ->> 'storage_path', jsonb_build_object('mimetype', 'application/pdf', 'size', 1024));
  v_fin := public.finalize_document_submission('a4000000-0000-4000-8000-000000000001', (v_prep ->> 'intent_id')::uuid, (v_prep ->> 'lease_token')::uuid);
  perform set_config('estagio.l4_sub_a4_opc2_v1', v_fin -> 'submission' ->> 'id', true);
end;
$$;

select public.admin_revoke_reviewer_assignment(
  current_setting('estagio.l4_assign_r1')::uuid,
  'technical_automation',
  'pgtap:00004',
  'Revogacao imediata R1 no Lote 4'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c4000000-0000-4000-8000-000000000003","role":"authenticated"}', true);

select is(
  (select count(*)::integer from public.reviewer_queue_v),
  0,
  'após revogação, revisor R1 vê zero itens na fila imediatamente'
);

select throws_ok(
  $$ select public.review_submission(
       current_setting('estagio.l4_sub_a4_opc2_v1')::uuid,
       'approved',
       null,
       '77777777-4444-4777-8777-777777777777'::uuid
     ) $$,
  '42501',
  null,
  'após revogação, revisor R1 é imediatamente bloqueado em review_submission'
);

select throws_ok(
  $$ select public.review_submission(
       current_setting('estagio.l4_sub_a4_obr1_v1')::uuid,
       'correction_requested',
       'Assinatura ausente na página 2.',
       '11111111-4444-4111-8111-111111111111'::uuid
     ) $$,
  '42501',
  null,
  'após revogação, até retry idempotente de decisão anterior por R1 é bloqueado'
);

select is(
  (
    select (
      (select count(*)::integer from public.process_audit_timeline_v) = 0
      and (select count(*)::integer from public.audit_events where process_id is not null) = 0
    )
  ),
  true,
  'após revogação, revisor R1 perde imediatamente leitura de process_audit_timeline_v e audit_events de processos'
);

-- Revisor R6 (ainda com assignment ativo em MOD_L4_1A) continua apto a ver na fila e aprovar L4_OPC_2
select set_config('request.jwt.claims', '{"sub":"24000000-0000-4000-8000-000000000008","role":"authenticated"}', true);

select is(
  (
    with res as (
      select public.review_submission(
        current_setting('estagio.l4_sub_a4_opc2_v1')::uuid,
        'approved',
        null,
        '88888888-4444-4888-8888-888888888888'::uuid
      ) as payload
    )
    select (payload -> 'review' ->> 'decision')
    from res
  ),
  'approved',
  'revogação de R1 não afeta outro revisor R6 com assignment ativo no mesmo escopo'
);

reset role;
select set_config('request.jwt.claims', '', true);

select * from finish();

rollback;
