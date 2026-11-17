begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(106);

-- 1. Verificar existência das 12 tabelas de domínio e da view de progresso
select has_table('public', 'institutions', 'tabela institutions existe');
select has_table('public', 'courses', 'tabela courses existe');
select has_table('public', 'course_modalities', 'tabela course_modalities existe');
select has_table('public', 'profiles', 'tabela profiles existe');
select has_table('public', 'reviewer_assignments', 'tabela reviewer_assignments existe');
select has_table('public', 'requirement_templates', 'tabela requirement_templates existe');
select has_table('public', 'requirement_template_items', 'tabela requirement_template_items existe');
select has_table('public', 'internship_processes', 'tabela internship_processes existe');
select has_table('public', 'process_requirements', 'tabela process_requirements existe');
select has_table('public', 'document_submissions', 'tabela document_submissions existe');
select has_table('public', 'document_reviews', 'tabela document_reviews existe');
select has_table('public', 'audit_events', 'tabela audit_events existe');
select has_view('public', 'process_progress_v', 'view process_progress_v existe');

-- 2. Verificar RLS habilitado em todas as 12 tabelas e no storage
select is(
  (
    select count(*)::integer
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relrowsecurity = true
      and c.relname in (
        'institutions', 'courses', 'course_modalities', 'profiles',
        'reviewer_assignments', 'requirement_templates', 'requirement_template_items',
        'internship_processes', 'process_requirements', 'document_submissions',
        'document_reviews', 'audit_events'
      )
  ),
  12,
  'RLS habilitado em todas as 12 tabelas de domínio'
);

-- 3. C1-05: Verificar grants explícitos das funções administrativas e is_assigned_reviewer
select is(
  has_function_privilege('anon', 'public.admin_set_user_role(uuid, text, text, text, text)', 'EXECUTE'),
  false,
  'anon não possui EXECUTE em admin_set_user_role'
);

select is(
  has_function_privilege('authenticated', 'public.admin_set_user_role(uuid, text, text, text, text)', 'EXECUTE'),
  false,
  'authenticated não possui EXECUTE em admin_set_user_role'
);

select is(
  has_function_privilege('authenticated', 'public.admin_assign_reviewer_scope(uuid, uuid, uuid, uuid, text, text, text)', 'EXECUTE'),
  false,
  'authenticated não possui EXECUTE em admin_assign_reviewer_scope'
);

select is(
  has_function_privilege('authenticated', 'public.admin_revoke_reviewer_assignment(uuid, text, text, text)', 'EXECUTE'),
  false,
  'authenticated não possui EXECUTE em admin_revoke_reviewer_assignment'
);

select is(
  has_function_privilege('service_role', 'public.admin_set_user_role(uuid, text, text, text, text)', 'EXECUTE'),
  true,
  'service_role possui EXECUTE em admin_set_user_role'
);

select is(
  has_function_privilege('anon', 'public.is_assigned_reviewer(uuid, uuid, uuid)', 'EXECUTE'),
  false,
  'anon não possui EXECUTE em is_assigned_reviewer'
);

select is(
  has_function_privilege('authenticated', 'public.is_assigned_reviewer(uuid, uuid, uuid)', 'EXECUTE'),
  true,
  'authenticated possui EXECUTE em is_assigned_reviewer'
);

-- R1-03: Teste adversarial em transação confirmando que nova função em public não herda EXECUTE para PUBLIC/anon/authenticated
create function public._pgtap_probe_future_fn()
returns integer
language sql
as $$ select 1 $$;

select is(
  has_function_privilege('public', 'public._pgtap_probe_future_fn()', 'EXECUTE'),
  false,
  'R1-03: função futura criada em public não herda EXECUTE para PUBLIC'
);

select is(
  has_function_privilege('anon', 'public._pgtap_probe_future_fn()', 'EXECUTE'),
  false,
  'R1-03: função futura criada em public não herda EXECUTE para anon'
);

select is(
  has_function_privilege('authenticated', 'public._pgtap_probe_future_fn()', 'EXECUTE'),
  false,
  'R1-03: função futura criada em public não herda EXECUTE para authenticated'
);

select is(
  has_function_privilege('service_role', 'public._pgtap_probe_future_fn()', 'EXECUTE'),
  true,
  'R1-03: função futura criada em public preserva EXECUTE para service_role'
);

drop function public._pgtap_probe_future_fn();

-- Verificar catálogo inicial fictício do seed.sql (sem depender de unicidade global de outros ciclos)
select is(
  (select count(*)::integer from public.institutions where id = '10000000-0000-4000-8000-000000000001' and is_demo = true),
  1,
  'catálogo seed fictício presente'
);

-- 4. Preparar usuários fictícios isolados desta execução via auth.users (aciona handle_new_user)
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  (
    '00000000-0000-0000-0000-000000000000',
    'aaaaaaaa-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'estudante.a.pgtap@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante A Demo","role":"reviewer"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'bbbbbbbb-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'estudante.b.pgtap@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Estudante B Demo"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'cccccccc-0000-4000-8000-000000000003',
    'authenticated',
    'authenticated',
    'revisor.r1.pgtap@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R1 Demo"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000000',
    'dddddddd-0000-4000-8000-000000000004',
    'authenticated',
    'authenticated',
    'revisor.r2.pgtap@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Revisor R2 Demo"}'::jsonb,
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    'eeeeeeee-0000-4000-8000-000000000005',
    'authenticated',
    'authenticated',
    'operador.pgtap@demo.local',
    '$2a$10$demoHashNotUsedInSqlTests000000000000000000000000000000',
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Operador Verificado Demo"}'::jsonb,
    now(),
    now()
  );

-- Cenário 1 & 2: Cadastro público sempre gera student e grava operator_type = user_self_action
select is(
  (select role from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
  'student',
  'cadastro público com role=reviewer no metadata força papel student'
);

select is(
  (
    select operator_type || ':' || operator_identifier
    from public.audit_events
    where target_user_id = 'aaaaaaaa-0000-4000-8000-000000000001'
      and event_type = 'profile_created'
  ),
  'user_self_action:auth_signup',
  'auditoria de profile_created registra user_self_action:auth_signup'
);

-- 5. C1-06: Rejeitar operações administrativas sem identificação verificável de operador
select throws_ok(
  $$
    select public.admin_set_user_role(
      'cccccccc-0000-4000-8000-000000000003',
      'reviewer',
      '',
      'pgtap-suite',
      'Motivo válido para teste'
    )
  $$,
  '22023',
  null,
  'admin_set_user_role rejeita operator_type vazio'
);

select throws_ok(
  $$
    select public.admin_set_user_role(
      'cccccccc-0000-4000-8000-000000000003',
      'reviewer',
      'technical_automation',
      '',
      'Motivo válido para teste'
    )
  $$,
  '22023',
  null,
  'admin_set_user_role rejeita operator_identifier vazio'
);

select throws_ok(
  $$
    select public.admin_set_user_role(
      'cccccccc-0000-4000-8000-000000000003',
      'reviewer',
      'technical_automation',
      'pgtap-suite',
      'curt'
    )
  $$,
  '22023',
  null,
  'admin_set_user_role rejeita justificativa ausente ou curta'
);

select throws_ok(
  $$
    select public.admin_set_user_role(
      'cccccccc-0000-4000-8000-000000000003',
      'reviewer',
      'verified_human_operator',
      'eeeeeeee-0000-4000-8000-000000000005',
      'Tentativa sem sub autenticado'
    )
  $$,
  '42501',
  null,
  'verified_human_operator rejeita UUID passado sem auth.uid() verificado'
);

-- Testar operador humano verificado com sub real no contexto JWT privilegiado (service_role + sub)
select set_config(
  'request.jwt.claims',
  '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"service_role"}',
  true
);

select throws_ok(
  $$
    select public.admin_set_user_role(
      'cccccccc-0000-4000-8000-000000000003',
      'reviewer',
      'verified_human_operator',
      'aaaaaaaa-0000-4000-8000-000000000001',
      'Tentativa de falsificar identificador de outro perfil'
    )
  $$,
  '42501',
  null,
  'verified_human_operator rejeita identificador divergente do auth.uid()'
);

select public.admin_set_user_role(
  'cccccccc-0000-4000-8000-000000000003',
  'reviewer',
  'verified_human_operator',
  'eeeeeeee-0000-4000-8000-000000000005',
  'Provisionamento verificado por operador humano no pgTAP'
);

select set_config('request.jwt.claims', '', true);

select is(
  (
    select (actor_id = 'eeeeeeee-0000-4000-8000-000000000005'::uuid
            and operator_type = 'verified_human_operator'
            and operator_identifier = 'verified_profile:eeeeeeee-0000-4000-8000-000000000005')
    from public.audit_events
    where target_user_id = 'cccccccc-0000-4000-8000-000000000003'
      and event_type = 'user_role_changed'
  ),
  true,
  'auditoria de operador humano grava actor_id verificado e operator_type'
);

-- Provisionar R2 via technical_automation (actor_id deve permanecer NULL)
select public.admin_set_user_role(
  'dddddddd-0000-4000-8000-000000000004',
  'reviewer',
  'technical_automation',
  'pgtap:00001_domain_rls',
  'Provisionamento automático R2 para teste pgTAP'
);

select is(
  (
    select (actor_id is null
            and operator_type = 'technical_automation'
            and operator_identifier = 'pgtap:00001_domain_rls')
    from public.audit_events
    where target_user_id = 'dddddddd-0000-4000-8000-000000000004'
      and event_type = 'user_role_changed'
  ),
  true,
  'auditoria de automação técnica não forja actor_id e registra operator_identifier'
);

-- 6. C1-02: Criar catálogo isolado desta execução pgTAP (1 curso no escopo de R1, 1 curso fora do escopo)
insert into public.institutions (id, code, name, is_demo, active)
values (
  '11000000-0000-4000-8000-000000000001',
  'INST_PGTAP_ISO',
  'Instituição Fictícia Isolada pgTAP',
  true,
  true
);

insert into public.courses (id, institution_id, code, name, is_demo, active)
values
  (
    '21000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000001',
    'CURSO_PGTAP_1',
    'Curso Fictício 1 pgTAP',
    true,
    true
  ),
  (
    '21000000-0000-4000-8000-000000000002',
    '11000000-0000-4000-8000-000000000001',
    'CURSO_PGTAP_2',
    'Curso Fictício 2 pgTAP (Fora Escopo)',
    true,
    true
  );

insert into public.course_modalities (id, course_id, code, name, is_mandatory, is_demo, active)
values
  (
    '31000000-0000-4000-8000-000000000001',
    '21000000-0000-4000-8000-000000000001',
    'MOD_PGTAP_1',
    'Modalidade Fictícia 1 pgTAP',
    true,
    true,
    true
  ),
  (
    '31000000-0000-4000-8000-000000000002',
    '21000000-0000-4000-8000-000000000002',
    'MOD_PGTAP_2',
    'Modalidade Fictícia 2 pgTAP',
    true,
    true,
    true
  ),
  (
    '31000000-0000-4000-8000-000000000003',
    '21000000-0000-4000-8000-000000000002',
    'MOD_PGTAP_3',
    'Modalidade Fictícia 3 pgTAP (Arquivo/Transições)',
    true,
    true,
    true
  );

-- Criar templates em rascunho, inserir itens e publicar
insert into public.requirement_templates (
  id, institution_id, course_id, course_modality_id, version, title, source_reference, status, is_demo
)
values
  (
    '41000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000001',
    '21000000-0000-4000-8000-000000000001',
    '31000000-0000-4000-8000-000000000001',
    1,
    'Template Fictício 1 pgTAP',
    'Dados fictícios pgTAP 1',
    'draft',
    true
  ),
  (
    '41000000-0000-4000-8000-000000000002',
    '11000000-0000-4000-8000-000000000001',
    '21000000-0000-4000-8000-000000000002',
    '31000000-0000-4000-8000-000000000002',
    1,
    'Template Fictício 2 pgTAP (Sem Obrigatórios)',
    'Dados fictícios pgTAP 2',
    'draft',
    true
  ),
  (
    '41000000-0000-4000-8000-000000000003',
    '11000000-0000-4000-8000-000000000001',
    '21000000-0000-4000-8000-000000000001',
    '31000000-0000-4000-8000-000000000001',
    2,
    'Template Fictício 1 v2 (Rascunho)',
    'Dados fictícios pgTAP v2 draft',
    'draft',
    true
  ),
  (
    '41000000-0000-4000-8000-000000000004',
    '11000000-0000-4000-8000-000000000001',
    '21000000-0000-4000-8000-000000000002',
    '31000000-0000-4000-8000-000000000003',
    1,
    'Template Fictício 3 pgTAP (Arquivamento)',
    'Dados fictícios pgTAP archived',
    'draft',
    true
  ),
  (
    '41000000-0000-4000-8000-000000000005',
    '11000000-0000-4000-8000-000000000001',
    '21000000-0000-4000-8000-000000000002',
    '31000000-0000-4000-8000-000000000003',
    2,
    'Template Fictício 3 v2 (Rascunho)',
    'Dados fictícios pgTAP v2 mod3 draft',
    'draft',
    true
  );

insert into public.requirement_template_items (
  id, template_id, code, title, description, acceptance_criteria, is_required, display_order, is_demo
)
values
  (
    '51000000-0000-4000-8000-000000000001',
    '41000000-0000-4000-8000-000000000001',
    'PGTAP_REQ_OBRIG_01',
    '[Demonstração] Obrigatório 1 pgTAP',
    'Item obrigatório 1',
    'Critério 1',
    true,
    1,
    true
  ),
  (
    '51000000-0000-4000-8000-000000000002',
    '41000000-0000-4000-8000-000000000001',
    'PGTAP_REQ_OBRIG_02',
    '[Demonstração] Obrigatório 2 pgTAP',
    'Item obrigatório 2',
    'Critério 2',
    true,
    2,
    true
  ),
  (
    '51000000-0000-4000-8000-000000000003',
    '41000000-0000-4000-8000-000000000001',
    'PGTAP_REQ_OPC_01',
    '[Demonstração] Opcional pgTAP',
    'Item opcional',
    'Critério opcional',
    false,
    3,
    true
  ),
  (
    '51000000-0000-4000-8000-000000000005',
    '41000000-0000-4000-8000-000000000001',
    'PGTAP_REQ_OPC_02',
    '[Demonstração] Opcional Extra pgTAP',
    'Item opcional extra para teste FK',
    'Critério opcional extra',
    false,
    4,
    true
  ),
  (
    '51000000-0000-4000-8000-000000000004',
    '41000000-0000-4000-8000-000000000002',
    'PGTAP_ONLY_OPC',
    '[Demonstração] Único Opcional pgTAP',
    'Item único opcional',
    'Critério B',
    false,
    1,
    true
  ),
  (
    '51000000-0000-4000-8000-000000000006',
    '41000000-0000-4000-8000-000000000003',
    'PGTAP_DRAFT_ITEM_01',
    '[Demonstração] Item Draft Editável',
    'Item em rascunho',
    'Critério draft',
    true,
    1,
    true
  ),
  (
    '51000000-0000-4000-8000-000000000007',
    '41000000-0000-4000-8000-000000000004',
    'PGTAP_ARCH_ITEM_01',
    '[Demonstração] Item Arquivado',
    'Item para testar template archived',
    'Critério archived',
    true,
    1,
    true
  ),
  (
    '51000000-0000-4000-8000-000000000008',
    '41000000-0000-4000-8000-000000000005',
    'PGTAP_T3_ITEM_01',
    '[Demonstração] Item Transição Adversária',
    'Item para matriz R1-02',
    'Critério T3',
    true,
    1,
    true
  );

update public.requirement_templates
   set status = 'published'
 where id in (
   '41000000-0000-4000-8000-000000000001',
   '41000000-0000-4000-8000-000000000002',
   '41000000-0000-4000-8000-000000000004'
 );

update public.requirement_templates
   set status = 'archived'
 where id = '41000000-0000-4000-8000-000000000004';

update public.requirement_templates
   set status = 'published'
 where id = '41000000-0000-4000-8000-000000000005';

-- R1-01: edição legítima de item em template draft é permitida; movimentação de publicado/arquivado ou troca de template_id é rejeitada
select lives_ok(
  $$
    update public.requirement_template_items
       set title = '[Demonstração] Item Draft Editado Legitimamente'
     where id = '51000000-0000-4000-8000-000000000006'
  $$,
  'R1-01: permite editar item enquanto template permanece draft'
);

select throws_ok(
  $$
    update public.requirement_template_items
       set template_id = '41000000-0000-4000-8000-000000000003'
     where id = '51000000-0000-4000-8000-000000000001'
  $$,
  '42501',
  null,
  'R1-01: rejeita transferência de item publicado para draft sem alterar conteúdo'
);

select throws_ok(
  $$
    update public.requirement_template_items
       set template_id = '41000000-0000-4000-8000-000000000003',
           title = 'Conteúdo adulterado via troca para draft'
     where id = '51000000-0000-4000-8000-000000000001'
  $$,
  '42501',
  null,
  'R1-01: rejeita transferência de item publicado para draft alterando conteúdo'
);

select throws_ok(
  $$
    update public.requirement_template_items
       set template_id = '41000000-0000-4000-8000-000000000003'
     where id = '51000000-0000-4000-8000-000000000007'
  $$,
  '42501',
  null,
  'R1-01: rejeita transferência de item arquivado para draft'
);

-- Criar segundo draft temporário apenas para tentar troca draft -> draft
insert into public.requirement_templates (
  id, institution_id, course_id, course_modality_id, version, title, source_reference, status, is_demo
)
values (
  '41000000-0000-4000-8000-000000000006',
  '11000000-0000-4000-8000-000000000001',
  '21000000-0000-4000-8000-000000000001',
  '31000000-0000-4000-8000-000000000001',
  3,
  'Template Fictício Draft Extra',
  'Dados fictícios pgTAP v3 draft',
  'draft',
  true
);

select throws_ok(
  $$
    update public.requirement_template_items
       set template_id = '41000000-0000-4000-8000-000000000006'
     where id = '51000000-0000-4000-8000-000000000006'
  $$,
  '42501',
  null,
  'R1-01: rejeita alteração de template_id mesmo entre templates draft'
);

-- Atribuir R1 somente ao curso/modalidade isolado 1 via local_demo_provisioning
select is(
  (
    select (public.admin_assign_reviewer_scope(
      'cccccccc-0000-4000-8000-000000000003',
      '11000000-0000-4000-8000-000000000001',
      '21000000-0000-4000-8000-000000000001',
      '31000000-0000-4000-8000-000000000001',
      'local_demo_provisioning',
      'pgtap:local_demo',
      'Atribuição isolada pgTAP R1'
    )).active
  ),
  true,
  'atribuição privilegiada via local_demo_provisioning retorna assignment ativo'
);

-- 7. C1-03: Rejeitar associação de processo a template de modalidade incompatível ou em rascunho
select throws_ok(
  $$
    insert into public.internship_processes (
      owner_id, institution_id, course_id, course_modality_id, template_id, template_version, status
    ) values (
      'aaaaaaaa-0000-4000-8000-000000000001',
      '11000000-0000-4000-8000-000000000001',
      '21000000-0000-4000-8000-000000000001',
      '31000000-0000-4000-8000-000000000001',
      '41000000-0000-4000-8000-000000000002',
      1,
      'in_progress'
    )
  $$,
  '23503',
  null,
  'C1-03: impede processo associado a template de outra modalidade/curso'
);

select throws_ok(
  $$
    insert into public.internship_processes (
      owner_id, institution_id, course_id, course_modality_id, template_id, template_version, status
    ) values (
      'aaaaaaaa-0000-4000-8000-000000000001',
      '11000000-0000-4000-8000-000000000001',
      '21000000-0000-4000-8000-000000000001',
      '31000000-0000-4000-8000-000000000001',
      '41000000-0000-4000-8000-000000000003',
      2,
      'in_progress'
    )
  $$,
  '23514',
  null,
  'C1-03: impede abrir processo com template em status draft'
);

-- Criar processos válidos para A (escopo R1) e B (fora do escopo R1)
insert into public.internship_processes (
  id, owner_id, institution_id, course_id, course_modality_id, template_id, template_version, status
)
values
  (
    '61000000-0000-4000-8000-000000000001',
    'aaaaaaaa-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000001',
    '21000000-0000-4000-8000-000000000001',
    '31000000-0000-4000-8000-000000000001',
    '41000000-0000-4000-8000-000000000001',
    1,
    'in_progress'
  ),
  (
    '61000000-0000-4000-8000-000000000002',
    'bbbbbbbb-0000-4000-8000-000000000002',
    '11000000-0000-4000-8000-000000000001',
    '21000000-0000-4000-8000-000000000002',
    '31000000-0000-4000-8000-000000000002',
    '41000000-0000-4000-8000-000000000002',
    1,
    'in_progress'
  );

-- Impedir duplicidade de processo ativo para mesmo estudante/curso/modalidade
select throws_ok(
  $$
    insert into public.internship_processes (
      owner_id, institution_id, course_id, course_modality_id, template_id, template_version, status
    ) values (
      'aaaaaaaa-0000-4000-8000-000000000001',
      '11000000-0000-4000-8000-000000000001',
      '21000000-0000-4000-8000-000000000001',
      '31000000-0000-4000-8000-000000000001',
      '41000000-0000-4000-8000-000000000001',
      1,
      'in_progress'
    )
  $$,
  '23505',
  null,
  'impede duplicidade de processo ativo para mesmo estudante/curso/modalidade'
);

-- C1-03: Rejeitar snapshot apontando para item de outro template
select throws_ok(
  $$
    insert into public.process_requirements (
      process_id, template_item_id, code, title, description, acceptance_criteria, is_required, display_order, status
    ) values (
      '61000000-0000-4000-8000-000000000001',
      '51000000-0000-4000-8000-000000000004',
      'FORJADO',
      'Item de outro template',
      'Desc',
      'Crit',
      false,
      9,
      'not_submitted'
    )
  $$,
  '23514',
  null,
  'C1-03: impede snapshot de requisito cuja origem pertence a outro template'
);

insert into public.process_requirements (
  id, process_id, template_item_id, code, title, description, acceptance_criteria, is_required, display_order, status
)
values
  (
    '71000000-0000-4000-8000-000000000001',
    '61000000-0000-4000-8000-000000000001',
    '51000000-0000-4000-8000-000000000001',
    'PGTAP_REQ_OBRIG_01',
    '[Demonstração] Obrigatório 1 pgTAP',
    'Item obrigatório 1',
    'Critério 1',
    true,
    1,
    'not_submitted'
  ),
  (
    '71000000-0000-4000-8000-000000000002',
    '61000000-0000-4000-8000-000000000001',
    '51000000-0000-4000-8000-000000000002',
    'PGTAP_REQ_OBRIG_02',
    '[Demonstração] Obrigatório 2 pgTAP',
    'Item obrigatório 2',
    'Critério 2',
    true,
    2,
    'not_submitted'
  ),
  (
    '71000000-0000-4000-8000-000000000003',
    '61000000-0000-4000-8000-000000000001',
    '51000000-0000-4000-8000-000000000003',
    'PGTAP_REQ_OPC_01',
    '[Demonstração] Opcional pgTAP',
    'Item opcional',
    'Critério opcional',
    false,
    3,
    'not_submitted'
  ),
  (
    '71000000-0000-4000-8000-000000000004',
    '61000000-0000-4000-8000-000000000002',
    '51000000-0000-4000-8000-000000000004',
    'PGTAP_ONLY_OPC',
    '[Demonstração] Único Opcional pgTAP',
    'Item único opcional',
    'Critério B',
    false,
    1,
    'not_submitted'
  );

-- Fluxo legítimo v1: not_submitted -> under_review -> correction_requested -> v2 under_review -> approved
insert into public.document_submissions (
  id, process_id, process_requirement_id, submitted_by, version, storage_path, mime_type, size_bytes, sha256_checksum, status
)
values (
  '81000000-0000-4000-8000-000000000001',
  '61000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000001',
  'aaaaaaaa-0000-4000-8000-000000000001',
  1,
  'demo/proc-pgtap-1/req-1/v1.pdf',
  'application/pdf',
  1024,
  'abc123v1',
  'under_review'
);

-- C1-03: Rejeitar divergência entre current_submission_id (v1) e current_version (2) tanto pelo trigger quanto pela FK composta
select throws_ok(
  $$
    update public.process_requirements
       set current_submission_id = '81000000-0000-4000-8000-000000000001',
           current_version = 2,
           status = 'under_review'
     where id = '71000000-0000-4000-8000-000000000001'
  $$,
  '42501',
  null,
  'C1-03: trigger impede transição com versão divergente'
);

set constraints public.fk_process_requirements_current_submission immediate;

select throws_ok(
  $$
    insert into public.process_requirements (
      id, process_id, template_item_id, code, title, description, acceptance_criteria, is_required, display_order,
      status, current_submission_id, current_version
    ) values (
      '71000000-0000-4000-8000-000000000099',
      '61000000-0000-4000-8000-000000000001',
      '51000000-0000-4000-8000-000000000005',
      'PGTAP_MISMATCH_FK',
      'Snapshot teste',
      'Desc',
      'Crit',
      true,
      99,
      'under_review',
      '81000000-0000-4000-8000-000000000001',
      2
    )
  $$,
  '23503',
  null,
  'C1-03: FK composta impede current_submission_id com versão divergente de current_version'
);

set constraints public.fk_process_requirements_current_submission deferred;

-- Transição legítima para under_review (v1)
update public.process_requirements
   set current_submission_id = '81000000-0000-4000-8000-000000000001',
       current_version = 1,
       status = 'under_review'
 where id = '71000000-0000-4000-8000-000000000001';

-- Impedir correção sem justificativa
select throws_ok(
  $$
    insert into public.document_reviews (
      process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
    ) values (
      '61000000-0000-4000-8000-000000000001',
      '71000000-0000-4000-8000-000000000001',
      '81000000-0000-4000-8000-000000000001',
      'cccccccc-0000-4000-8000-000000000003',
      'correction_requested',
      '   '
    )
  $$,
  '23514',
  null,
  'impede solicitação de correção sem motivo válido'
);

-- Revisão v1: solicitar correção
insert into public.document_reviews (
  id, process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
)
values (
  '91000000-0000-4000-8000-000000000001',
  '61000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000001',
  '81000000-0000-4000-8000-000000000001',
  'cccccccc-0000-4000-8000-000000000003',
  'correction_requested',
  'Falta assinatura fictícia de demonstração.'
);

update public.document_submissions
   set status = 'correction_requested'
 where id = '81000000-0000-4000-8000-000000000001';

update public.process_requirements
   set status = 'correction_requested'
 where id = '71000000-0000-4000-8000-000000000001';

-- Impedir revisão duplicada para a mesma versão v1
select throws_ok(
  $$
    insert into public.document_reviews (
      process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
    ) values (
      '61000000-0000-4000-8000-000000000001',
      '71000000-0000-4000-8000-000000000001',
      '81000000-0000-4000-8000-000000000001',
      'cccccccc-0000-4000-8000-000000000003',
      'approved',
      null
    )
  $$,
  '23505',
  null,
  'impede revisão duplicada para a mesma versão de submissão'
);

-- Reenvio legítimo v2 -> under_review -> approved
insert into public.document_submissions (
  id, process_id, process_requirement_id, submitted_by, version, storage_path, mime_type, size_bytes, sha256_checksum, status
)
values (
  '81000000-0000-4000-8000-000000000002',
  '61000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000001',
  'aaaaaaaa-0000-4000-8000-000000000001',
  2,
  'demo/proc-pgtap-1/req-1/v2.pdf',
  'application/pdf',
  2048,
  'def456v2',
  'under_review'
);

select lives_ok(
  $$
    update public.process_requirements
       set current_submission_id = '81000000-0000-4000-8000-000000000002',
           current_version = 2,
           status = 'under_review'
     where id = '71000000-0000-4000-8000-000000000001'
  $$,
  'C1-04: permite transição legítima de reenvio para versão 2 em análise'
);

insert into public.document_reviews (
  id, process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
)
values (
  '91000000-0000-4000-8000-000000000002',
  '61000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000001',
  '81000000-0000-4000-8000-000000000002',
  'cccccccc-0000-4000-8000-000000000003',
  'approved',
  null
);

select lives_ok(
  $$
    update public.document_submissions
       set status = 'approved'
     where id = '81000000-0000-4000-8000-000000000002';
    update public.process_requirements
       set status = 'approved'
     where id = '71000000-0000-4000-8000-000000000001';
  $$,
  'C1-04: permite transição legítima de revisão para approved'
);

-- R1-01 e R1-02: Verificar preservação de snapshot e histórico de versões/revisões após tentativas inválidas
select is(
  (
    select (pr.template_item_id = '51000000-0000-4000-8000-000000000001'::uuid
            and rti.template_id = '41000000-0000-4000-8000-000000000001'::uuid)
    from public.process_requirements as pr
    join public.requirement_template_items as rti on rti.id = pr.template_item_id
    where pr.id = '71000000-0000-4000-8000-000000000001'
  ),
  true,
  'R1-01: snapshot de requisito mantém vínculo íntegro com item e template originais'
);

select is(
  (
    select count(*)::integer
    from public.document_submissions
    where process_requirement_id = '71000000-0000-4000-8000-000000000001'
  ),
  2,
  'R1-02: histórico preserva ambas as versões (v1 e v2) da submissão'
);

select is(
  (
    select count(*)::integer
    from public.document_reviews
    where process_requirement_id = '71000000-0000-4000-8000-000000000001'
  ),
  2,
  'R1-02: histórico preserva ambas as revisões (v1 e v2)'
);

-- Matriz adversarial R1-02 em processo isolado fora do escopo de Estudante A/B e Revisor R1
insert into public.internship_processes (
  id, owner_id, institution_id, course_id, course_modality_id, template_id, template_version, status
)
values (
  '61000000-0000-4000-8000-000000000003',
  'eeeeeeee-0000-4000-8000-000000000005',
  '11000000-0000-4000-8000-000000000001',
  '21000000-0000-4000-8000-000000000002',
  '31000000-0000-4000-8000-000000000003',
  '41000000-0000-4000-8000-000000000005',
  2,
  'in_progress'
);

insert into public.process_requirements (
  id, process_id, template_item_id, code, title, description, acceptance_criteria, is_required, display_order, status
)
values (
  '71000000-0000-4000-8000-000000000005',
  '61000000-0000-4000-8000-000000000003',
  '51000000-0000-4000-8000-000000000008',
  'PGTAP_T3_ITEM_01',
  '[Demonstração] Item Transição Adversária',
  'Item para matriz R1-02',
  'Critério T3',
  true,
  1,
  'not_submitted'
);

select throws_ok(
  $$
    update public.process_requirements
       set status = 'approved'
     where id = '71000000-0000-4000-8000-000000000005'
  $$,
  '42501',
  null,
  'R1-02: bloqueia transição direta not_submitted -> approved'
);

insert into public.document_submissions (
  id, process_id, process_requirement_id, submitted_by, version, storage_path, mime_type, size_bytes, sha256_checksum, status
)
values (
  '81000000-0000-4000-8000-000000000003',
  '61000000-0000-4000-8000-000000000003',
  '71000000-0000-4000-8000-000000000005',
  'eeeeeeee-0000-4000-8000-000000000005',
  1,
  'demo/proc-pgtap-3/req-5/v1.pdf',
  'application/pdf',
  1024,
  'r102hashv1',
  'under_review'
);

select lives_ok(
  $$
    update public.process_requirements
       set current_submission_id = '81000000-0000-4000-8000-000000000003',
           current_version = 1,
           status = 'under_review'
     where id = '71000000-0000-4000-8000-000000000005'
  $$,
  'R1-02: primeira submissão legítima not_submitted -> under_review permitida'
);

insert into public.document_submissions (
  id, process_id, process_requirement_id, submitted_by, version, storage_path, mime_type, size_bytes, sha256_checksum, status
)
values (
  '81000000-0000-4000-8000-000000000004',
  '61000000-0000-4000-8000-000000000003',
  '71000000-0000-4000-8000-000000000005',
  'eeeeeeee-0000-4000-8000-000000000005',
  2,
  'demo/proc-pgtap-3/req-5/v2.pdf',
  'application/pdf',
  2048,
  'r102hashv2',
  'under_review'
);

select throws_ok(
  $$
    update public.process_requirements
       set current_version = 2
     where id = '71000000-0000-4000-8000-000000000005'
  $$,
  '42501',
  null,
  'R1-02: bloqueia incremento de current_version mantendo under_review'
);

select throws_ok(
  $$
    update public.process_requirements
       set current_submission_id = '81000000-0000-4000-8000-000000000004',
           current_version = 2,
           status = 'under_review'
     where id = '71000000-0000-4000-8000-000000000005'
  $$,
  '42501',
  null,
  'R1-02: bloqueia substituição de current_submission_id mantendo under_review'
);

select throws_ok(
  $$
    update public.process_requirements
       set current_submission_id = '81000000-0000-4000-8000-000000000004',
           current_version = 2,
           status = 'approved'
     where id = '71000000-0000-4000-8000-000000000005'
  $$,
  '42501',
  null,
  'R1-02: bloqueia decisão under_review -> approved com alteração de ponteiro/versão'
);

update public.document_submissions
   set status = 'correction_requested'
 where id = '81000000-0000-4000-8000-000000000003';

update public.process_requirements
   set status = 'correction_requested'
 where id = '71000000-0000-4000-8000-000000000005';

select throws_ok(
  $$
    update public.process_requirements
       set current_submission_id = '81000000-0000-4000-8000-000000000004',
           current_version = 2,
           status = 'correction_requested'
     where id = '71000000-0000-4000-8000-000000000005'
  $$,
  '42501',
  null,
  'R1-02: bloqueia substituição de ponteiro/versão mantendo correction_requested'
);

select throws_ok(
  $$
    update public.process_requirements
       set status = 'approved'
     where id = '71000000-0000-4000-8000-000000000005'
  $$,
  '42501',
  null,
  'R1-02: bloqueia transição direta correction_requested -> approved'
);

update public.process_requirements
   set current_submission_id = '81000000-0000-4000-8000-000000000004',
       current_version = 2,
       status = 'under_review'
 where id = '71000000-0000-4000-8000-000000000005';

select throws_ok(
  $$
    insert into public.document_reviews (
      process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
    ) values (
      '61000000-0000-4000-8000-000000000003',
      '71000000-0000-4000-8000-000000000005',
      '81000000-0000-4000-8000-000000000003',
      'cccccccc-0000-4000-8000-000000000003',
      'approved',
      null
    )
  $$,
  '42501',
  null,
  'R1-02: bloqueia revisão de versão antiga v1 quando v2 está vigente'
);

insert into public.document_reviews (
  id, process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
)
values (
  '91000000-0000-4000-8000-000000000003',
  '61000000-0000-4000-8000-000000000003',
  '71000000-0000-4000-8000-000000000005',
  '81000000-0000-4000-8000-000000000004',
  'cccccccc-0000-4000-8000-000000000003',
  'approved',
  null
);

update public.document_submissions
   set status = 'approved'
 where id = '81000000-0000-4000-8000-000000000004';

update public.process_requirements
   set status = 'approved'
 where id = '71000000-0000-4000-8000-000000000005';

select throws_ok(
  $$
    insert into public.document_reviews (
      process_id, process_requirement_id, submission_id, reviewer_id, decision, reason
    ) values (
      '61000000-0000-4000-8000-000000000003',
      '71000000-0000-4000-8000-000000000005',
      '81000000-0000-4000-8000-000000000004',
      'cccccccc-0000-4000-8000-000000000003',
      'correction_requested',
      'Tentativa após aprovado'
    )
  $$,
  '23505',
  null,
  'R1-02: bloqueia segunda revisão em submissão já aprovada'
);

select throws_ok(
  $$
    update public.process_requirements
       set status = 'correction_requested'
     where id = '71000000-0000-4000-8000-000000000005'
  $$,
  '42501',
  null,
  'R1-02: bloqueia alteração arbitrária de requisito já approved'
);

-- 8. C1-04: Comprovar bloqueio de mutação histórica mesmo em contexto privilegiado (postgres)
select throws_ok(
  $$ update public.requirement_templates set title = 'Alterado indevidamente' where id = '41000000-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'C1-04: bloqueia alteração de conteúdo de template publicado'
);

select throws_ok(
  $$ update public.requirement_template_items set title = 'Alterado' where id = '51000000-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'C1-04: bloqueia alteração de item de template publicado'
);

select throws_ok(
  $$
    insert into public.requirement_template_items (
      template_id, code, title, description, acceptance_criteria, is_required, display_order, is_demo
    ) values (
      '41000000-0000-4000-8000-000000000001', 'NOVO', 'Novo item', 'Desc', 'Crit', true, 99, true
    )
  $$,
  '42501',
  null,
  'C1-04: bloqueia inserção de item em template publicado'
);

select throws_ok(
  $$ delete from public.requirement_template_items where id = '51000000-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'C1-04: bloqueia exclusão de item de template publicado'
);

select throws_ok(
  $$ update public.process_requirements set title = 'Snapshot alterado', is_required = false where id = '71000000-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'C1-04: bloqueia alteração de conteúdo do snapshot em process_requirements'
);

select throws_ok(
  $$ update public.internship_processes set template_version = 2 where id = '61000000-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'C1-04: bloqueia alteração de template_version em internship_processes'
);

select throws_ok(
  $$ update public.document_submissions set storage_path = 'adulterado.pdf' where id = '81000000-0000-4000-8000-000000000002' $$,
  '42501',
  null,
  'C1-04: bloqueia alteração de storage_path em submissão registrada'
);

select throws_ok(
  $$ update public.document_submissions set sha256_checksum = 'adulterado' where id = '81000000-0000-4000-8000-000000000002' $$,
  '42501',
  null,
  'C1-04: bloqueia alteração de sha256_checksum em submissão registrada'
);

select throws_ok(
  $$ update public.document_submissions set submitted_by = 'bbbbbbbb-0000-4000-8000-000000000002' where id = '81000000-0000-4000-8000-000000000002' $$,
  '42501',
  null,
  'C1-04: bloqueia alteração de autoria histórica em submissão registrada'
);

select throws_ok(
  $$ update public.document_submissions set status = 'correction_requested' where id = '81000000-0000-4000-8000-000000000002' $$,
  '42501',
  null,
  'C1-04: bloqueia reversão de decisão em submissão já decidida'
);

insert into public.audit_events (
  event_type, actor_id, actor_role, operator_type, operator_identifier, target_user_id, process_id, entity_table, entity_id, metadata
)
values
  (
    'process_opened',
    'aaaaaaaa-0000-4000-8000-000000000001',
    'student',
    'user_self_action',
    'pgtap:process_open',
    'aaaaaaaa-0000-4000-8000-000000000001',
    '61000000-0000-4000-8000-000000000001',
    'internship_processes',
    '61000000-0000-4000-8000-000000000001',
    '{}'::jsonb
  ),
  (
    'process_opened',
    'bbbbbbbb-0000-4000-8000-000000000002',
    'student',
    'user_self_action',
    'pgtap:process_open',
    'bbbbbbbb-0000-4000-8000-000000000002',
    '61000000-0000-4000-8000-000000000002',
    'internship_processes',
    '61000000-0000-4000-8000-000000000002',
    '{}'::jsonb
  );

-- Progresso calculado: processo A tem 1/2 obrigatórios = 50.00; processo B com 0 obrigatórios = indeterminate e NULL (nunca 100%)
select is(
  (select progress_percentage from public.process_progress_v where process_id = '61000000-0000-4000-8000-000000000001'),
  50.00::numeric(5, 2),
  'progresso conta somente obrigatórios aprovados (1/2 = 50%)'
);

select is(
  (select progress_status from public.process_progress_v where process_id = '61000000-0000-4000-8000-000000000002'),
  'indeterminate',
  'processo sem requisitos obrigatórios fica indeterminado'
);

select is(
  (select progress_percentage from public.process_progress_v where process_id = '61000000-0000-4000-8000-000000000002'),
  null::numeric(5, 2),
  'processo sem requisitos obrigatórios nunca gera 100%'
);

-- Nenhuma exclusão de evidências, reviews ou histórico
select throws_ok(
  $$ delete from public.document_submissions where id = '81000000-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'document_submissions não pode ser excluída'
);

select throws_ok(
  $$ update public.document_reviews set decision = 'correction_requested', reason = 'adulterado' where id = '91000000-0000-4000-8000-000000000002' $$,
  '42501',
  null,
  'document_reviews é imutável contra UPDATE'
);

select throws_ok(
  $$ delete from public.audit_events where process_id = '61000000-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'audit_events não pode ser excluída'
);

select throws_ok(
  $$ delete from auth.users where id = 'aaaaaaaa-0000-4000-8000-000000000001' $$,
  '23503',
  null,
  'exclusão de usuário com registros é bloqueada (sem cascade de evidências)'
);

-- 9. Testar anon (sem sessão) -> zero acesso
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select throws_ok(
  $$ select count(*) from public.profiles $$,
  '42501',
  null,
  'anon não possui permissão de leitura em profiles'
);

select throws_ok(
  $$ select count(*) from public.internship_processes $$,
  '42501',
  null,
  'anon não possui permissão de leitura em internship_processes'
);

select throws_ok(
  $$ select public.admin_set_user_role('aaaaaaaa-0000-4000-8000-000000000001', 'reviewer', 'technical_automation', 'anon-attempt', 'Bloqueio anon') $$,
  '42501',
  null,
  'anon não pode executar admin_set_user_role'
);

reset role;

-- 10. Testar Estudante A (authenticated) - valida isolamento mesmo havendo outros processos no banco
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);

select is(
  (select count(*)::integer from public.profiles),
  1,
  'estudante A enxerga somente seu próprio perfil'
);

select is(
  (select count(*)::integer from public.internship_processes),
  1,
  'estudante A enxerga somente seu próprio processo mesmo com outros ciclos no banco'
);

select is(
  (select count(*)::integer from public.internship_processes where owner_id <> 'aaaaaaaa-0000-4000-8000-000000000001'),
  0,
  'estudante A não acessa processo de terceiros'
);

select is(
  (select count(*)::integer from public.audit_events where process_id = '61000000-0000-4000-8000-000000000002'),
  0,
  'estudante A não acessa trilha de auditoria do estudante B'
);

select throws_ok(
  $$ update public.profiles set role = 'reviewer' where id = 'aaaaaaaa-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'estudante A não pode alterar seu próprio role para reviewer'
);

select throws_ok(
  $$ update public.internship_processes set status = 'documentally_complete' where id = '61000000-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'estudante A não pode alterar status do processo diretamente'
);

select throws_ok(
  $$ insert into public.reviewer_assignments (reviewer_id, institution_id, course_id) values ('aaaaaaaa-0000-4000-8000-000000000001', '11000000-0000-4000-8000-000000000001', '21000000-0000-4000-8000-000000000001') $$,
  '42501',
  null,
  'estudante A não pode criar reviewer_assignments'
);

select throws_ok(
  $$ select public.admin_set_user_role('aaaaaaaa-0000-4000-8000-000000000001', 'reviewer', 'technical_automation', 'student-attempt', 'Bloqueio student') $$,
  '42501',
  null,
  'usuário autenticado comum não pode executar admin_set_user_role'
);

reset role;

-- 11. Testar Revisor R2 (role=reviewer, porém SEM atribuição)
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"dddddddd-0000-4000-8000-000000000004","role":"authenticated"}',
  true
);

select is(
  (select count(*)::integer from public.internship_processes),
  0,
  'revisor R2 sem atribuição vê zero processos em todo o banco'
);

select is(
  (select count(*)::integer from public.process_requirements),
  0,
  'revisor R2 sem atribuição vê zero requisitos'
);

select is(
  (select count(*)::integer from public.document_submissions),
  0,
  'revisor R2 sem atribuição vê zero submissões'
);

select is(
  (select count(*)::integer from public.audit_events where process_id is not null),
  0,
  'revisor R2 sem atribuição vê zero eventos de processos'
);

reset role;

-- 12. Testar Revisor R1 (atribuído somente ao curso/modalidade isolado 1)
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cccccccc-0000-4000-8000-000000000003","role":"authenticated"}',
  true
);

select is(
  (select count(*)::integer from public.internship_processes),
  1,
  'revisor R1 vê apenas o processo dentro de seu escopo atribuído'
);

select is(
  (select count(*)::integer from public.internship_processes where id = '61000000-0000-4000-8000-000000000002'),
  0,
  'revisor R1 não vê processo fora de seu escopo atribuído'
);

select is(
  (select count(*)::integer from public.document_submissions where process_id = '61000000-0000-4000-8000-000000000001'),
  2,
  'revisor R1 visualiza ambas as versões preservadas do processo em seu escopo'
);

reset role;
select set_config('request.jwt.claims', '', true);

-- 13. Revogar atribuição de R1 e confirmar bloqueio imediato + trilha de auditoria
select is(
  (
    select (public.admin_revoke_reviewer_assignment(
      (
        select id
        from public.reviewer_assignments
        where reviewer_id = 'cccccccc-0000-4000-8000-000000000003'
          and active = true
        limit 1
      ),
      'technical_automation',
      'pgtap:00001_domain_rls',
      'Teste de revogação pgTAP'
    )).active
  ),
  false,
  'revogação privilegiada desativa atribuição'
);

select is(
  (
    select count(*)::integer
    from public.audit_events
    where target_user_id = 'cccccccc-0000-4000-8000-000000000003'
      and event_type = 'reviewer_assignment_revoked'
      and operator_type = 'technical_automation'
  ),
  1,
  'revogação de assignment gera evento de auditoria com operator_type'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cccccccc-0000-4000-8000-000000000003","role":"authenticated"}',
  true
);

select is(
  (select count(*)::integer from public.internship_processes),
  0,
  'após revogação, revisor R1 perde imediatamente acesso aos processos do escopo'
);

select is(
  (select count(*)::integer from public.document_submissions),
  0,
  'após revogação, revisor R1 perde imediatamente acesso às submissões'
);

reset role;
select set_config('request.jwt.claims', '', true);

-- 14. Rebaixar R2 para student via RPC privilegiada e checar atualização de full_name pelo próprio estudante
select is(
  (
    select (public.admin_set_user_role(
      'dddddddd-0000-4000-8000-000000000004',
      'student',
      'technical_automation',
      'pgtap:00001_domain_rls',
      'Rebaixamento pgTAP para validar auditoria'
    )).role
  ),
  'student',
  'admin_set_user_role permite retornar papel para student com auditoria'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);

select lives_ok(
  $$ update public.profiles set full_name = 'Estudante A Atualizado' where id = 'aaaaaaaa-0000-4000-8000-000000000001' $$,
  'estudante A pode atualizar apenas seu próprio full_name'
);

select throws_ok(
  $$ update public.profiles set email = 'forjado@demo.local' where id = 'aaaaaaaa-0000-4000-8000-000000000001' $$,
  '42501',
  null,
  'estudante A não pode alterar seu próprio email em profiles'
);

reset role;
select set_config('request.jwt.claims', '', true);

select * from finish();

rollback;
