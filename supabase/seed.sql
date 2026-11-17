-- Seed fictício de demonstração do catálogo inicial (ESP-07).
-- IMPORTANTE: Todos os dados abaixo são fictícios e de demonstração.
-- NÃO representam normas oficiais do UNIPÊ nem de nenhuma instituição real.

insert into public.institutions (id, code, name, is_demo, active)
values (
  '10000000-0000-4000-8000-000000000001',
  'INST_DEMO',
  'Instituição Fictícia de Demonstração (MVP)',
  true,
  true
)
on conflict (id) do nothing;

insert into public.courses (id, institution_id, code, name, is_demo, active)
values (
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  'TEC_DEMO',
  'Curso Piloto de Tecnologia Fictício (Demonstração)',
  true,
  true
)
on conflict (id) do nothing;

insert into public.course_modalities (id, course_id, code, name, is_mandatory, is_demo, active)
values (
  '30000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001',
  'ESTAGIO_OBRIG_DEMO',
  'Estágio Curricular Obrigatório Fictício (Demonstração)',
  true,
  true,
  true
)
on conflict (id) do nothing;

-- Cria como rascunho para inserir os itens e publicar ao final (respeitando imutabilidade de publicados)
insert into public.requirement_templates (
  id,
  institution_id,
  course_id,
  course_modality_id,
  version,
  title,
  source_reference,
  status,
  is_demo,
  published_at
)
values (
  '40000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001',
  '30000000-0000-4000-8000-000000000001',
  1,
  'Checklist Fictício de Demonstração v1 (Não Oficial)',
  'Catálogo fictício de demonstração do MVP; não representa norma oficial do UNIPÊ.',
  'draft',
  true,
  null
)
on conflict (id) do nothing;

insert into public.requirement_template_items (
  id,
  template_id,
  code,
  title,
  description,
  acceptance_criteria,
  is_required,
  display_order,
  is_demo
)
select
  item.id,
  item.template_id,
  item.code,
  item.title,
  item.description,
  item.acceptance_criteria,
  item.is_required,
  item.display_order,
  item.is_demo
from (
  values
    (
      '50000000-0000-4000-8000-000000000001'::uuid,
      '40000000-0000-4000-8000-000000000001'::uuid,
      'DEMO_REQ_OBRIG_01',
      '[Demonstração] Termo de Compromisso Fictício',
      'Item fictício obrigatório para demonstração do MVP. Não representa regra oficial do UNIPÊ.',
      'PDF fictício legível para validação de fluxo de demonstração.',
      true,
      1,
      true
    ),
    (
      '50000000-0000-4000-8000-000000000002'::uuid,
      '40000000-0000-4000-8000-000000000001'::uuid,
      'DEMO_REQ_OBRIG_02',
      '[Demonstração] Plano de Atividades Fictício',
      'Segundo item fictício obrigatório para demonstração do MVP. Não representa regra oficial do UNIPÊ.',
      'PDF fictício legível com plano exemplificativo de demonstração.',
      true,
      2,
      true
    ),
    (
      '50000000-0000-4000-8000-000000000003'::uuid,
      '40000000-0000-4000-8000-000000000001'::uuid,
      'DEMO_REQ_OPC_01',
      '[Demonstração] Documento Complementar Opcional Fictício',
      'Item fictício opcional para demonstrar que requisitos opcionais não bloqueiam o progresso documental.',
      'PDF fictício opcional de demonstração.',
      false,
      3,
      true
    )
) as item(id, template_id, code, title, description, acceptance_criteria, is_required, display_order, is_demo)
where exists (
  select 1
  from public.requirement_templates rt
  where rt.id = item.template_id
    and rt.status = 'draft'
)
on conflict (id) do nothing;

update public.requirement_templates
   set status = 'published',
       published_at = coalesce(published_at, now())
 where id = '40000000-0000-4000-8000-000000000001'
   and status = 'draft';
