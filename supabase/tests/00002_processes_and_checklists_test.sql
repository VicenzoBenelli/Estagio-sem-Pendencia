begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(60);

-- ============================================================================
-- 1. Privilégios, SECURITY DEFINER e proteção contra execução anônima/admin (15, 16)
-- ============================================================================
select is(
  has_function_privilege('public', 'public.create_internship_process(uuid)', 'EXECUTE'),
  false,
  'PUBLIC não possui EXECUTE em create_internship_process'
);

select is(
  has_function_privilege('anon', 'public.create_internship_process(uuid)', 'EXECUTE'),
  false,
  'anon não possui EXECUTE em create_internship_process'
);

select is(
  has_function_privilege('authenticated', 'public.create_internship_process(uuid)', 'EXECUTE'),
  true,
  'authenticated possui EXECUTE em create_internship_process'
);

select is(
  (
    select (p.prosecdef = true and p.proconfig @> array['search_path=""'])
    from pg_proc as p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'create_internship_process'
  ),
  true,
  'create_internship_process é SECURITY DEFINER com search_path vazio'
);

select is(
  (
    has_table_privilege('authenticated', 'public.internship_processes', 'INSERT')
    or has_table_privilege('authenticated', 'public.internship_processes', 'UPDATE')
    or has_table_privilege('authenticated', 'public.internship_processes', 'DELETE')
    or has_table_privilege('authenticated', 'public.process_requirements', 'INSERT')
    or has_table_privilege('authenticated', 'public.process_requirements', 'UPDATE')
    or has_table_privilege('authenticated', 'public.process_requirements', 'DELETE')
    or has_table_privilege('authenticated', 'public.audit_events', 'INSERT')
  ),
  false,
  'authenticated não possui escrita direta em processos, snapshots ou auditoria'
);

select is(
  (
    has_function_privilege('authenticated', 'public.admin_set_user_role(uuid, text, text, text, text)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.admin_assign_reviewer_scope(uuid, uuid, uuid, uuid, text, text, text)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.admin_revoke_reviewer_assignment(uuid, text, text, text)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public._resolve_privileged_operator(text, text, text)', 'EXECUTE')
  ),
  false,
  'authenticated não recebe permissões administrativas'
);

-- ============================================================================
-- 2. Fixtures isoladas desta execução (usuários e catálogos fictícios)
-- ============================================================================
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  (
    '00000000-0000-0000-0000-000000000000',
    'a2000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'estudante.a.l2@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante A Lote 2"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'b2000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'estudante.b.l2@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante B Lote 2"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'c2000000-0000-4000-8000-000000000003',
    'authenticated',
    'authenticated',
    'estudante.inativo.l2@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante Inativo Lote 2"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'd2000000-0000-4000-8000-000000000004',
    'authenticated',
    'authenticated',
    'revisor.r1.l2@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R1 Lote 2"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'e2000000-0000-4000-8000-000000000005',
    'authenticated',
    'authenticated',
    'revisor.r2.l2@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R2 Sem Escopo Lote 2"}'::jsonb,
    now(),
    now()
  );

-- Desativar C2 e promover R1 e R2
select set_config('estagio.privileged_op', 'on', true);
update public.profiles
   set active = false
 where id = 'c2000000-0000-4000-8000-000000000003';
select set_config('estagio.privileged_op', 'off', true);

select public.admin_set_user_role(
  'd2000000-0000-4000-8000-000000000004',
  'reviewer',
  'technical_automation',
  'pgtap:00002_l2',
  'Provisionamento R1 Lote 2'
);

select public.admin_set_user_role(
  'e2000000-0000-4000-8000-000000000005',
  'reviewer',
  'technical_automation',
  'pgtap:00002_l2',
  'Provisionamento R2 Lote 2'
);

-- Catálogo isolado (instituições, cursos, modalidades, templates)
insert into public.institutions (id, code, name, is_demo, active)
values
  ('12000000-0000-4000-8000-000000000001', 'INST_T2_ATIV', 'Instituição Fictícia Lote 2', true, true),
  ('12000000-0000-4000-8000-000000000002', 'INST_T2_INAT', 'Instituição Inativa Lote 2', true, false);

insert into public.courses (id, institution_id, code, name, is_demo, active)
values
  ('22000000-0000-4000-8000-000000000001', '12000000-0000-4000-8000-000000000001', 'CUR_T2_A', 'Curso Piloto A Lote 2', true, true),
  ('22000000-0000-4000-8000-000000000002', '12000000-0000-4000-8000-000000000001', 'CUR_T2_B', 'Curso Piloto B Lote 2', true, true),
  ('22000000-0000-4000-8000-000000000003', '12000000-0000-4000-8000-000000000001', 'CUR_T2_INAT', 'Curso Inativo Lote 2', true, false),
  ('22000000-0000-4000-8000-000000000004', '12000000-0000-4000-8000-000000000002', 'CUR_T2_INST_INAT', 'Curso Sob Inst Inativa', true, true);

insert into public.course_modalities (id, course_id, code, name, is_mandatory, is_demo, active)
values
  ('32000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000001', 'MOD_T2_A', 'Modalidade Principal A', true, true, true),
  ('32000000-0000-4000-8000-000000000002', '22000000-0000-4000-8000-000000000002', 'MOD_T2_OPT', 'Modalidade Apenas Opcionais', false, true, true),
  ('32000000-0000-4000-8000-000000000003', '22000000-0000-4000-8000-000000000002', 'MOD_T2_NOTPL', 'Modalidade Sem Template', true, true, true),
  ('32000000-0000-4000-8000-000000000004', '22000000-0000-4000-8000-000000000002', 'MOD_T2_DRAFT', 'Modalidade Apenas Draft', true, true, true),
  ('32000000-0000-4000-8000-000000000005', '22000000-0000-4000-8000-000000000002', 'MOD_T2_ARCH', 'Modalidade Apenas Archived', true, true, true),
  ('32000000-0000-4000-8000-000000000006', '22000000-0000-4000-8000-000000000001', 'MOD_T2_INAT', 'Modalidade Inativa', true, true, false),
  ('32000000-0000-4000-8000-000000000007', '22000000-0000-4000-8000-000000000003', 'MOD_T2_CURINAT', 'Modalidade em Curso Inativo', true, true, true),
  ('32000000-0000-4000-8000-000000000008', '22000000-0000-4000-8000-000000000004', 'MOD_T2_INSTINAT', 'Modalidade em Inst Inativa', true, true, true),
  ('32000000-0000-4000-8000-000000000009', '22000000-0000-4000-8000-000000000002', 'MOD_T2_EMPTYPUB', 'Modalidade Template Sem Itens', true, true, true),
  ('32000000-0000-4000-8000-000000000010', '22000000-0000-4000-8000-000000000002', 'MOD_T2_ROLLBACK', 'Modalidade Falha Snapshot', true, true, true);

-- Templates em draft para popular itens e publicar adequadamente
insert into public.requirement_templates (
  id, institution_id, course_id, course_modality_id, version, title, source_reference, status, is_demo
)
values
  ('42000000-0000-4000-8000-000000000001', '12000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000001', '32000000-0000-4000-8000-000000000001', 1, 'Checklist MOD_T2_A v1', 'Fonte fictícia v1', 'draft', true),
  ('42000000-0000-4000-8000-000000000002', '12000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000001', '32000000-0000-4000-8000-000000000001', 2, 'Checklist MOD_T2_A v2 (Draft Inicial)', 'Fonte fictícia v2', 'draft', true),
  ('42000000-0000-4000-8000-000000000003', '12000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000002', '32000000-0000-4000-8000-000000000002', 1, 'Checklist Apenas Opcional', 'Fonte fictícia opt', 'draft', true),
  ('42000000-0000-4000-8000-000000000004', '12000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000002', '32000000-0000-4000-8000-000000000004', 1, 'Checklist Draft Only', 'Fonte fictícia draft', 'draft', true),
  ('42000000-0000-4000-8000-000000000005', '12000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000002', '32000000-0000-4000-8000-000000000005', 1, 'Checklist Archived Only', 'Fonte fictícia arch', 'draft', true),
  ('42000000-0000-4000-8000-000000000006', '12000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000001', '32000000-0000-4000-8000-000000000006', 1, 'Checklist Mod Inativa', 'Fonte fictícia mod inat', 'draft', true),
  ('42000000-0000-4000-8000-000000000007', '12000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000003', '32000000-0000-4000-8000-000000000007', 1, 'Checklist Curso Inativo', 'Fonte fictícia cur inat', 'draft', true),
  ('42000000-0000-4000-8000-000000000008', '12000000-0000-4000-8000-000000000002', '22000000-0000-4000-8000-000000000004', '32000000-0000-4000-8000-000000000008', 1, 'Checklist Inst Inativa', 'Fonte fictícia inst inat', 'draft', true),
  -- Inserido diretamente como published sem itens para validar rollback/recusa na RPC
  ('42000000-0000-4000-8000-000000000009', '12000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000002', '32000000-0000-4000-8000-000000000009', 1, 'Checklist Publicado Vazio', 'Fonte fictícia empty pub', 'published', true),
  ('42000000-0000-4000-8000-000000000010', '12000000-0000-4000-8000-000000000001', '22000000-0000-4000-8000-000000000002', '32000000-0000-4000-8000-000000000010', 1, 'Checklist Rollback Snapshot', 'Fonte fictícia rollback', 'draft', true);

insert into public.requirement_template_items (
  id, template_id, code, title, description, acceptance_criteria, is_required, display_order, is_demo
)
values
  ('52000000-0000-4000-8000-000000000001', '42000000-0000-4000-8000-000000000001', 'T2_A_OBR_1', 'Termo V1 Fictício', 'Desc obr 1 v1', 'Crit obr 1 v1', true, 1, true),
  ('52000000-0000-4000-8000-000000000002', '42000000-0000-4000-8000-000000000001', 'T2_A_OBR_2', 'Plano V1 Fictício', 'Desc obr 2 v1', 'Crit obr 2 v1', true, 2, true),
  ('52000000-0000-4000-8000-000000000003', '42000000-0000-4000-8000-000000000001', 'T2_A_OPC_3', 'Opcional V1 Fictício', 'Desc opc 3 v1', 'Crit opc 3 v1', false, 3, true),
  -- Itens da v2 (inicialmente draft)
  ('52000000-0000-4000-8000-000000000004', '42000000-0000-4000-8000-000000000002', 'T2_A_V2_NOVO_1', 'Novo Termo V2 Fictício', 'Desc novo v2', 'Crit novo v2', true, 1, true),
  ('52000000-0000-4000-8000-000000000005', '42000000-0000-4000-8000-000000000002', 'T2_A_V2_OPC_2', 'Novo Opcional V2 Fictício', 'Desc opc v2', 'Crit opc v2', false, 2, true),
  -- Demais templates
  ('52000000-0000-4000-8000-000000000006', '42000000-0000-4000-8000-000000000003', 'T2_OPT_ONLY', 'Único Opcional T2', 'Desc opt only', 'Crit opt only', false, 1, true),
  ('52000000-0000-4000-8000-000000000007', '42000000-0000-4000-8000-000000000004', 'T2_DRAFT_ONLY', 'Item Draft Only', 'Desc draft', 'Crit draft', true, 1, true),
  ('52000000-0000-4000-8000-000000000008', '42000000-0000-4000-8000-000000000005', 'T2_ARCH_ONLY', 'Item Archived Only', 'Desc arch', 'Crit arch', true, 1, true),
  ('52000000-0000-4000-8000-000000000009', '42000000-0000-4000-8000-000000000006', 'T2_MOD_INAT', 'Item Mod Inativa', 'Desc mod inat', 'Crit mod inat', true, 1, true),
  ('52000000-0000-4000-8000-000000000010', '42000000-0000-4000-8000-000000000007', 'T2_CUR_INAT', 'Item Cur Inativo', 'Desc cur inat', 'Crit cur inat', true, 1, true),
  ('52000000-0000-4000-8000-000000000011', '42000000-0000-4000-8000-000000000008', 'T2_INST_INAT', 'Item Inst Inativa', 'Desc inst inat', 'Crit inst inat', true, 1, true),
  ('52000000-0000-4000-8000-000000000012', '42000000-0000-4000-8000-000000000010', 'T2_RB_ITEM_01', 'Item Rollback Snapshot', 'Desc rollback', 'Crit rollback', true, 1, true);

-- Publicar templates ativos (deixando #2 em draft e #5 transitando para archived)
update public.requirement_templates
   set status = 'published'
 where id in (
   '42000000-0000-4000-8000-000000000001',
   '42000000-0000-4000-8000-000000000003',
   '42000000-0000-4000-8000-000000000005',
   '42000000-0000-4000-8000-000000000006',
   '42000000-0000-4000-8000-000000000007',
   '42000000-0000-4000-8000-000000000008',
   '42000000-0000-4000-8000-000000000010'
 );

update public.requirement_templates
   set status = 'archived'
 where id = '42000000-0000-4000-8000-000000000005';

-- Atribuir Revisor R1_2 exclusivamente a MOD_T2_A
select public.admin_assign_reviewer_scope(
  'd2000000-0000-4000-8000-000000000004',
  '12000000-0000-4000-8000-000000000001',
  '22000000-0000-4000-8000-000000000001',
  '32000000-0000-4000-8000-000000000001',
  'technical_automation',
  'pgtap:00002_l2',
  'Atribuição R1 apenas MOD_T2_A'
);

-- ============================================================================
-- 3. Tentativas bloqueadas por papel/sessão (15, 16)
-- ============================================================================
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000001') $$,
  '42501',
  null,
  'anon não pode executar create_internship_process'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000001') $$,
  '42501',
  null,
  'authenticated sem sub no JWT não pode executar create_internship_process'
);

select set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000001') $$,
  '42501',
  null,
  'usuário com papel reviewer não pode abrir processo via create_internship_process'
);

select set_config('request.jwt.claims', '{"sub":"c2000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000001') $$,
  '42501',
  null,
  'estudante inativo não pode abrir processo via create_internship_process'
);

-- ============================================================================
-- 4. Estudante A2 abre processo + snapshot + owner JWT + auditoria + progresso (1, 2, 3, 12, 14, 18)
-- ============================================================================
select set_config('request.jwt.claims', '{"sub":"a2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

-- Deve filtrar catálogo ativo corretamente (enxerga INST_T2_ATIV, não INST_T2_INAT; enxerga MOD_T2_A, não MOD_T2_INAT)
select is(
  (
    select count(*)::integer
    from public.course_modalities as cm
    join public.courses as c on c.id = cm.course_id
    join public.institutions as i on i.id = c.institution_id
    where cm.id in ('32000000-0000-4000-8000-000000000001', '32000000-0000-4000-8000-000000000006', '32000000-0000-4000-8000-000000000007', '32000000-0000-4000-8000-000000000008')
  ),
  1,
  'catálogo RLS exibe apenas hierarquia ativa (instituição, curso e modalidade ativos)'
);

-- Abertura bem-sucedida derivando owner/escopo/template v1 published (ignorando v2 draft)
select is(
  (
    select row(
      p.owner_id,
      p.institution_id,
      p.course_id,
      p.course_modality_id,
      p.template_id,
      p.template_version,
      p.status
    )::text
    from public.create_internship_process('32000000-0000-4000-8000-000000000001') as p
  ),
  '(a2000000-0000-4000-8000-000000000001,12000000-0000-4000-8000-000000000001,22000000-0000-4000-8000-000000000001,32000000-0000-4000-8000-000000000001,42000000-0000-4000-8000-000000000001,1,in_progress)',
  'Estudante A2 abre processo derivando owner_id do JWT, escopo do catálogo e template published v1 (não draft v2)'
);

-- Verificar snapshot completo ordenado por display_order
select is(
  (
    select count(*)::integer
    from public.process_requirements as pr
    join public.internship_processes as ip on ip.id = pr.process_id
    where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
      and pr.status = 'not_submitted'
      and pr.current_version = 0
      and pr.current_submission_id is null
  ),
  3,
  'snapshot inicial possui exatamente os 3 itens com status=not_submitted, current_version=0 e current_submission_id=NULL'
);

select is(
  (
    select string_agg(
      pr.display_order::text || ':' || pr.code || ':' || pr.title || ':' || pr.description || ':' || pr.acceptance_criteria || ':' || pr.is_required::text,
      '|'
      order by pr.display_order asc
    )
    from public.process_requirements as pr
    join public.internship_processes as ip on ip.id = pr.process_id
    where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  '1:T2_A_OBR_1:Termo V1 Fictício:Desc obr 1 v1:Crit obr 1 v1:true|2:T2_A_OBR_2:Plano V1 Fictício:Desc obr 2 v1:Crit obr 2 v1:true|3:T2_A_OPC_3:Opcional V1 Fictício:Desc opc 3 v1:Crit opc 3 v1:false',
  'snapshot copia fielmente códigos, títulos, descrições, critérios, obrigatoriedade e ordem estável'
);

-- Verificar vínculo exato de template_item_id
select is(
  (
    select count(*)::integer
    from public.process_requirements as pr
    join public.internship_processes as ip on ip.id = pr.process_id
    join public.requirement_template_items as rti on rti.id = pr.template_item_id
    where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
      and rti.template_id = '42000000-0000-4000-8000-000000000001'
  ),
  3,
  'snapshot preserva template_item_id vinculado ao template v1 publicado'
);

-- Verificar evento de auditoria process_created
select is(
  (
    select (
      ae.event_type = 'process_created'
      and ae.actor_id = 'a2000000-0000-4000-8000-000000000001'::uuid
      and ae.actor_role = 'student'
      and ae.operator_type = 'user_self_action'
      and ae.operator_identifier = 'rpc:create_internship_process'
      and ae.entity_table = 'internship_processes'
      and ae.entity_id = ip.id
      and ae.metadata ->> 'template_version' = '1'
      and ae.metadata ->> 'snapshot_item_count' = '3'
      and ae.metadata ->> 'required_item_count' = '2'
    )
    from public.audit_events as ae
    join public.internship_processes as ip on ip.id = ae.process_id
    where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  true,
  'abertura registra audit_event process_created com metadados completos e autoria do JWT'
);

-- Verificar cálculo inicial na process_progress_v (2 obrigatórios, 1 opcional não interfere)
select is(
  (
    select row(pv.required_total, pv.required_approved, pv.progress_status, pv.progress_percentage)::text
    from public.process_progress_v as pv
    join public.internship_processes as ip on ip.id = pv.process_id
    where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  '(2,0,in_progress,0.00)',
  'process_progress_v contabiliza apenas os 2 itens obrigatórios (opcional excluído do denominador)'
);

-- ============================================================================
-- 5. Processo somente opcional = indeterminado & opcional aprovado não altera % (14)
-- ============================================================================
select lives_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000002') $$,
  'Estudante A2 abre processo em modalidade com checklist apenas opcional'
);

select is(
  (
    select row(pv.required_total, pv.required_approved, pv.progress_status, pv.progress_percentage)::text
    from public.process_progress_v as pv
    join public.internship_processes as ip on ip.id = pv.process_id
    where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000002'
  ),
  '(0,0,indeterminate,)',
  'processo sem itens obrigatórios retorna progress_status=indeterminate e progress_percentage=NULL (nunca 100%)'
);

-- Simular aprovação do item opcional de procA (usando papel postgres apenas no setup de evidência)
reset role;
with target_req as (
  select pr.id, pr.process_id
  from public.process_requirements as pr
  join public.internship_processes as ip on ip.id = pr.process_id
  where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
    and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
    and pr.code = 'T2_A_OPC_3'
),
inserted_sub as (
  insert into public.document_submissions (
    process_id, process_requirement_id, submitted_by, version, storage_path, mime_type, size_bytes, sha256_checksum, status
  )
  select
    tr.process_id,
    tr.id,
    'a2000000-0000-4000-8000-000000000001',
    1,
    'demo/t2-opt/v1.pdf',
    'application/pdf',
    1024,
    'opt_hash_v1',
    'under_review'
  from target_req as tr
  returning id, process_id, process_requirement_id
)
update public.process_requirements as pr
   set current_submission_id = s.id,
       current_version = 1,
       status = 'under_review'
  from inserted_sub as s
 where pr.id = s.process_requirement_id;

insert into public.document_reviews (
  process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
)
select
  pr.process_id,
  pr.id,
  pr.current_submission_id,
  'd2000000-0000-4000-8000-000000000004',
  'approved',
  null
from public.process_requirements as pr
join public.internship_processes as ip on ip.id = pr.process_id
where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
  and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  and pr.code = 'T2_A_OPC_3';

update public.document_submissions as ds
   set status = 'approved'
  from public.process_requirements as pr
  join public.internship_processes as ip on ip.id = pr.process_id
 where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
   and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
   and pr.code = 'T2_A_OPC_3'
   and ds.id = pr.current_submission_id;

update public.process_requirements as pr
   set status = 'approved'
  from public.internship_processes as ip
 where ip.id = pr.process_id
   and ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
   and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
   and pr.code = 'T2_A_OPC_3';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select is(
  (
    select row(pv.required_total, pv.required_approved, pv.progress_status, pv.progress_percentage)::text
    from public.process_progress_v as pv
    join public.internship_processes as ip on ip.id = pv.process_id
    where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  '(2,0,in_progress,0.00)',
  'aprovação do item opcional não incrementa required_approved nem altera o percentual dos obrigatórios'
);

-- ============================================================================
-- 6. Bloqueio de escrita direta, duplicata, inativos, sem template, draft/archived (4, 8, 10, 11, 12, 18)
-- ============================================================================
select throws_ok(
  $$
    insert into public.internship_processes (
      owner_id, institution_id, course_id, course_modality_id, template_id, template_version, status
    ) values (
      'b2000000-0000-4000-8000-000000000002',
      '12000000-0000-4000-8000-000000000001',
      '22000000-0000-4000-8000-000000000001',
      '32000000-0000-4000-8000-000000000001',
      '42000000-0000-4000-8000-000000000001',
      1,
      'in_progress'
    )
  $$,
  '42501',
  null,
  'estudante A2 não pode inserir processo diretamente informando owner_id de B2'
);

select throws_ok(
  $$
    insert into public.process_requirements (
      process_id, template_item_id, code, title, description, acceptance_criteria, is_required, display_order
    ) values (
      (select id from public.internship_processes where owner_id = 'a2000000-0000-4000-8000-000000000001' and course_modality_id = '32000000-0000-4000-8000-000000000001'),
      '52000000-0000-4000-8000-000000000001',
      'FORJADO',
      'Forjado',
      'Desc',
      'Crit',
      true,
      99
    )
  $$,
  '42501',
  null,
  'estudante A2 não pode inserir process_requirements diretamente'
);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000001') $$,
  '23505',
  null,
  'duplicata ativa na mesma modalidade é rejeitada com 23505'
);

select throws_ok(
  $$ select public.create_internship_process(null::uuid) $$,
  '22023',
  null,
  'modalidade nula é rejeitada com 22023'
);

select throws_ok(
  $$ select public.create_internship_process('32999999-9999-4999-8999-999999999999') $$,
  'P0002',
  null,
  'modalidade inexistente é rejeitada com P0002'
);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000006') $$,
  '23514',
  null,
  'modalidade inativa (active=false) é rejeitada'
);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000007') $$,
  '23514',
  null,
  'modalidade cujo curso está inativo é rejeitada'
);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000008') $$,
  '23514',
  null,
  'modalidade cuja instituição está inativa é rejeitada'
);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000003') $$,
  '23514',
  null,
  'ausência de template publicado gera erro compreensível'
);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000004') $$,
  '23514',
  null,
  'template exclusivamente draft não é utilizado para abertura'
);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000005') $$,
  '23514',
  null,
  'template exclusivamente archived não é utilizado para abertura'
);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000009') $$,
  '23514',
  null,
  'template publicado sem nenhum item provoca erro e rollback sem abrir processo'
);

-- Confirmar que nenhuma falha anterior criou processo ou audit_event
reset role;
select is(
  (
    select count(*)::integer
    from public.internship_processes
    where owner_id = 'a2000000-0000-4000-8000-000000000001'
  ),
  2,
  'nenhuma tentativa rejeitada criou processo parcial para Estudante A2'
);

select is(
  (
    select count(*)::integer
    from public.audit_events
    where event_type = 'process_created'
      and actor_id = 'a2000000-0000-4000-8000-000000000001'
  ),
  2,
  'audit_event process_created existe apenas para os 2 processos concluídos com sucesso'
);

-- ============================================================================
-- 7. Rollback atômico quando a criação de snapshot falha no meio do INSERT (17, 18)
-- ============================================================================
create or replace function public._pgtap_fail_snapshot_trigger()
returns trigger
language plpgsql
as $$
begin
  if new.code = 'T2_RB_ITEM_01' then
    raise exception 'Falha simulada durante gravação do snapshot'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger trg_pgtap_fail_snapshot
  before insert on public.process_requirements
  for each row execute function public._pgtap_fail_snapshot_trigger();

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select throws_ok(
  $$ select public.create_internship_process('32000000-0000-4000-8000-000000000010') $$,
  'P0001',
  'Falha simulada durante gravação do snapshot',
  'falha durante inserção do snapshot propaga exceção'
);

reset role;
drop trigger trg_pgtap_fail_snapshot on public.process_requirements;
drop function public._pgtap_fail_snapshot_trigger();

select is(
  (
    select count(*)::integer
    from public.internship_processes
    where owner_id = 'a2000000-0000-4000-8000-000000000001'
      and course_modality_id = '32000000-0000-4000-8000-000000000010'
  ),
  0,
  'falha no snapshot provoca rollback integral do processo em internship_processes'
);

select is(
  (
    select count(*)::integer
    from public.audit_events
    where event_type = 'process_created'
      and actor_id = 'a2000000-0000-4000-8000-000000000001'
  ),
  2,
  'falha no snapshot não grava evento de auditoria process_created'
);

-- ============================================================================
-- 8. Isolamento de leitura por ID e por papel (5, 6, 7)
-- ============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);

select is(
  (
    select count(*)::integer
    from public.internship_processes
    where owner_id = 'a2000000-0000-4000-8000-000000000001'
  ),
  0,
  'Estudante B2 não lista nem acessa por filtro processos de A2'
);

select is(
  (
    select count(*)::integer
    from public.process_requirements
    where code in ('T2_A_OBR_1', 'T2_A_OBR_2', 'T2_A_OPC_3')
  ),
  0,
  'Estudante B2 não acessa snapshot de requisitos de A2'
);

select is(
  (
    select count(*)::integer
    from public.process_progress_v
    where owner_id = 'a2000000-0000-4000-8000-000000000001'
  ),
  0,
  'Estudante B2 não acessa progresso de A2 em process_progress_v'
);

select is(
  (
    select count(*)::integer
    from public.audit_events
    where target_user_id = 'a2000000-0000-4000-8000-000000000001'
  ),
  0,
  'Estudante B2 não acessa eventos de auditoria de A2'
);

-- Revisor R2_2 sem assignment: zero visibilidade
select set_config('request.jwt.claims', '{"sub":"e2000000-0000-4000-8000-000000000005","role":"authenticated"}', true);

select is(
  (select count(*)::integer from public.internship_processes),
  0,
  'Revisor R2 sem atribuição vê zero processos'
);

select is(
  (select count(*)::integer from public.process_requirements),
  0,
  'Revisor R2 sem atribuição vê zero requisitos'
);

select is(
  (select count(*)::integer from public.process_progress_v),
  0,
  'Revisor R2 sem atribuição vê zero linhas em process_progress_v'
);

-- Revisor R1_2 atribuído a MOD_T2_A: vê procA (MOD_T2_A), NÃO vê procOpt (MOD_T2_OPT)
select set_config('request.jwt.claims', '{"sub":"d2000000-0000-4000-8000-000000000004","role":"authenticated"}', true);

select is(
  (select count(*)::integer from public.internship_processes where course_modality_id = '32000000-0000-4000-8000-000000000001'),
  1,
  'Revisor R1 atribuído visualiza processo da modalidade em seu escopo'
);

select is(
  (select count(*)::integer from public.process_requirements where code in ('T2_A_OBR_1', 'T2_A_OBR_2', 'T2_A_OPC_3')),
  3,
  'Revisor R1 atribuído visualiza os requisitos ordenados do processo em seu escopo'
);

select is(
  (
    select count(*)::integer
    from public.process_progress_v as pv
    join public.internship_processes as ip on ip.id = pv.process_id
    where ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  1,
  'Revisor R1 atribuído visualiza o progresso do processo em seu escopo'
);

select is(
  (select count(*)::integer from public.internship_processes where course_modality_id = '32000000-0000-4000-8000-000000000002'),
  0,
  'Revisor R1 não visualiza processo fora de seu escopo atribuído'
);

-- ============================================================================
-- 9. Publicação de template v2 não altera snapshot v1; v2 é usado em novas aberturas (13)
-- ============================================================================
reset role;
select set_config('request.jwt.claims', '', true);

update public.requirement_templates
   set status = 'archived'
 where id = '42000000-0000-4000-8000-000000000001';

update public.requirement_template_items
   set title = 'Novo Termo V2 Atualizado antes de Publicar'
 where id = '52000000-0000-4000-8000-000000000004';

update public.requirement_templates
   set status = 'published'
 where id = '42000000-0000-4000-8000-000000000002';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);

select is(
  (
    select row(p.owner_id, p.template_id, p.template_version)::text
    from public.create_internship_process('32000000-0000-4000-8000-000000000001') as p
  ),
  '(b2000000-0000-4000-8000-000000000002,42000000-0000-4000-8000-000000000002,2)',
  'após publicar v2, Estudante B2 abre novo processo com template_version=2'
);

select is(
  (
    select string_agg(pr.display_order::text || ':' || pr.code || ':' || pr.title || ':' || pr.is_required::text, '|' order by pr.display_order asc)
    from public.process_requirements as pr
    join public.internship_processes as ip on ip.id = pr.process_id
    where ip.owner_id = 'b2000000-0000-4000-8000-000000000002'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  '1:T2_A_V2_NOVO_1:Novo Termo V2 Atualizado antes de Publicar:true|2:T2_A_V2_OPC_2:Novo Opcional V2 Fictício:false',
  'snapshot do processo de B2 reflete exatamente os itens da v2 publicada'
);

select is(
  (
    select row(pv.required_total, pv.required_approved, pv.progress_percentage)::text
    from public.process_progress_v as pv
    join public.internship_processes as ip on ip.id = pv.process_id
    where ip.owner_id = 'b2000000-0000-4000-8000-000000000002'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  '(1,0,0.00)',
  'progresso do processo v2 de B2 considera apenas o 1 item obrigatório da v2'
);

-- Confirmar que o processo e snapshot v1 do Estudante A2 permaneceram intactos
select set_config('request.jwt.claims', '{"sub":"a2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select is(
  (
    select row(ip.template_id, ip.template_version)::text
    from public.internship_processes as ip
    where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  '(42000000-0000-4000-8000-000000000001,1)',
  'publicação da v2 não altera template_id nem template_version do processo v1 de A2'
);

select is(
  (
    select string_agg(pr.display_order::text || ':' || pr.code || ':' || pr.title || ':' || pr.is_required::text, '|' order by pr.display_order asc)
    from public.process_requirements as pr
    join public.internship_processes as ip on ip.id = pr.process_id
    where ip.owner_id = 'a2000000-0000-4000-8000-000000000001'
      and ip.course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  '1:T2_A_OBR_1:Termo V1 Fictício:true|2:T2_A_OBR_2:Plano V1 Fictício:true|3:T2_A_OPC_3:Opcional V1 Fictício:false',
  'publicação da v2 não modifica os requisitos snapshot v1 de A2'
);

-- Estudante A2 continua podendo ler metadados do template v1 (agora archived) porque faz parte de seu processo
select is(
  (
    select status
    from public.requirement_templates
    where id = '42000000-0000-4000-8000-000000000001'
  ),
  'archived',
  'Estudante A2 continua podendo ler metadados do template histórico v1 vinculado ao seu processo'
);

-- Estudante A2 não vê templates draft/archived alheios sem processo dele
select is(
  (
    select count(*)::integer
    from public.requirement_templates
    where id in ('42000000-0000-4000-8000-000000000004', '42000000-0000-4000-8000-000000000005')
  ),
  0,
  'usuário comum não enxerga templates draft ou archived não vinculados ao seu processo'
);

-- ============================================================================
-- 10. Cancelamento de processo permite nova abertura na mesma modalidade mantendo histórico
-- ============================================================================
reset role;
select set_config('request.jwt.claims', '', true);

update public.internship_processes
   set status = 'cancelled',
       closed_at = now()
 where owner_id = 'b2000000-0000-4000-8000-000000000002'
   and course_modality_id = '32000000-0000-4000-8000-000000000001';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b2000000-0000-4000-8000-000000000002","role":"authenticated"}', true);

select is(
  (
    select (public.create_internship_process('32000000-0000-4000-8000-000000000001')).status
  ),
  'in_progress',
  'após cancelamento do processo anterior, estudante B2 pode abrir novo processo na modalidade'
);

select is(
  (
    select count(*)::integer
    from public.internship_processes
    where owner_id = 'b2000000-0000-4000-8000-000000000002'
      and course_modality_id = '32000000-0000-4000-8000-000000000001'
  ),
  2,
  'histórico preserva o processo cancelado e o novo processo ativo'
);

-- ============================================================================
-- 11. Consultas diretas por ID e proteção anon sobre leitura de processos/catálogo
-- ============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select is(
  (
    select count(*)::integer
    from public.internship_processes
    where id = (
      select id
      from public.internship_processes
      where owner_id = 'a2000000-0000-4000-8000-000000000001'
        and course_modality_id = '32000000-0000-4000-8000-000000000001'
    )
  ),
  1,
  'Estudante A2 consulta detalhes do próprio processo pelo ID'
);

select is(
  (
    select count(*)::integer
    from public.process_progress_v
    where owner_id = 'a2000000-0000-4000-8000-000000000001'
  ),
  2,
  'Estudante A2 visualiza o progresso calculado de ambos os próprios processos'
);

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select throws_ok(
  $$ select count(*) from public.course_modalities $$,
  '42501',
  null,
  'anon não possui acesso de leitura ao catálogo de modalidades'
);

reset role;
select set_config('request.jwt.claims', '', true);

select * from finish();

rollback;
