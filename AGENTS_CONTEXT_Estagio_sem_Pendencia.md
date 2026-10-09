# ESTÁGIO SEM PENDÊNCIA — CONTEXTO CANÔNICO PARA AGENTES DE IA

> **Status:** planejamento, não código pronto. **Atualizado:** 09/10/2026. **Fonte de verdade para trabalho:** Trello (ESP-01 a ESP-32), este arquivo e decisões documentadas no repositório. O PDF do time espelha esta especificação.

## 0. Instruções mandatórias para agentes de IA

1. Leia este documento **antes** de propor arquitetura, gerar código, migrações ou executar tarefas. Leia também README, migrations, código atual e card ESP correspondente. **Não presuma que o repositório implementa esta especificação**.
2. **Nunca invente regras institucionais**: curso piloto, documentos obrigatórios, prazos, responsável oficial e fluxo real de estágio dependem de validação. Proponha placeholders configuráveis, marcados como fictícios.
3. **Não há protótipo Figma atualmente**; sua criação é trabalho futuro da ESP-05. Não afirme existência de telas, deploys, integrações ou testes realizados sem evidência.
4. Este produto **não autoriza oficialmente estágios**: “sem pendências documentais” significa apenas que os requisitos obrigatórios aplicáveis foram aprovados *dentro do MVP*.
5. **Autorização nunca apenas na UI**. Aplicar RLS no PostgreSQL e Storage privado; operações privilegiadas exigem validação no backend. Não colocar `service_role` nem credenciais secretas em Flutter ou Web.
6. Dados reais de estágio, PDFs de alunos e identificadores pessoais não devem ser usados em seeds, demos, prompts ou testes. Minimizar coleta e seguir princípios da LGPD.
7. **Não executar tarefas de outra sprint sem justificar dependências.** Priorizar ciclo crítico completo até Sprint 4. Não introduzir OCR, IA de aprovação, assinaturas jurídicas ou integrações privadas no MVP.
8. Ao implementar um card, entregar: análise do estado atual, arquivos alterados, migração necessária, RN aplicadas, testes positivos e negativos, riscos, evidências e critérios de aceite verificados. Nunca declarar tarefa concluída sem rodar os testes pertinentes.
9. Se este documento divergir do Trello ou do código, **não resolver silenciosamente**: documentar divergência, apresentar impacto e pedir decisão quando a regra for de negócio.
10. Todos os identificadores `ESP-01` a `ESP-32` são estáveis. A fonte anexada antiga possui numeração diferente (ESP-01 a ESP-30); **não reutilizar a numeração antiga**.

## 1. Visão, fronteiras e atores

**Problema:** estudantes de estágio curricular obrigatório de cursos de tecnologia podem ter dificuldade em descobrir exigências, enviar PDFs, acompanhar revisões e corrigir pendências. O MVP centraliza acompanhamento documental com clareza de status.

**Piloto:** um curso de tecnologia e uma modalidade de estágio, ambos a confirmar. O UNIPÊ não está declarado como parceiro, aprovador ou integrador do produto.

**Atores:** estudante autenticado (dono dos processos), revisor autenticado e explicitamente atribuído ao escopo de análise, e operador de provisionamento de revisor (operação protegida; não requer painel administrativo completo no MVP).

**P0:** login, perfis, processo, checklist versionado, upload privado, fila de revisão, decisão com justificativa, reenvio, progresso e controle de acesso. **P1:** notificações, prazos, métricas e refinamentos. **Fora do escopo:** assinatura digital com valor jurídico, autorização oficial, OCR, IA decisória, chat, integração com sistemas institucionais privados.

## 2. Arquitetura alvo

- **Cliente aluno:** Flutter/Dart para Android, com estados loading/empty/error e acessibilidade.
- **Cliente revisor:** Flutter Web responsivo; nunca expor acesso administrativo no bundle.
- **Identidade:** Supabase Auth; usuário público nasce como estudante. Provisionamento de revisor apenas por operação privilegiada auditável.
- **Persistência:** PostgreSQL com migrations SQL versionadas, constraints, índices e Row Level Security (deny by default).
- **Documentos:** Supabase Storage em bucket **privado**, paths opacos, downloads autenticados ou links temporários autorizados.
- **Transições críticas:** funções SQL/RPC transacionais (ou Edge Functions com checagem backend equivalente) para revisão, versionamento e eventos.
- **Infra de trabalho:** GitHub com PR e CI (format/analyze/test), Trello para acompanhamento, Figma **a criar** na Sprint 1.
- **Arquitetura:** monólito modular, módulos de autenticação, processos, requisitos, documentos, revisão, notificações e auditoria; evitar microserviços.

### Entidades conceituais

`institutions`, `courses`, `profiles`, `internship_processes`, `requirement_templates`, `process_requirements`, `document_submissions`, `document_reviews`, `reviewer_assignments`, `notifications`, `audit_events`.

**Integridade fundamental:** `owner_id` de processo é derivado de `auth.uid()`; `reviewer_assignments` define escopo; template possui versão; `process_requirements` preserva snapshot da regra vigente; cada submissão é uma versão imutável; decisão associa revisor + versão atual; evento de auditoria acompanha mutação relevante.

## 3. Fluxos lógicos e invariantes

### Jornada do estudante

1. Autenticar-se. Abrir processo com curso e modalidade permitidos.
2. Backend identifica template validado e gera checklist/snapshot aplicável. Se não existir, sinaliza configuração pendente; **não mostrar 100%**.
3. Estudante seleciona requisito do próprio processo, anexa PDF e recebe confirmação **apenas após** arquivo + metadados persistirem corretamente.
4. Última submissão fica **em análise**; revisor autorizado visualiza e decide.
5. Se houver **correção solicitada**, estudante lê justificativa, cria **nova versão** sem sobrescrever a antiga, e nova versão volta a **em análise**.
6. Se **aprovado**, item passa a contar no progresso. Quando **todos os requisitos obrigatórios aplicáveis** estiverem aprovados, exibir **sem pendências documentais** com aviso de que não é autorização oficial.

### Máquina de estados por requisito

```text
NÃO ENVIADO --upload confirmado--> EM ANÁLISE
EM ANÁLISE --revisor autorizado aprova--> APROVADO
EM ANÁLISE --revisor autorizado solicita correção com motivo--> CORREÇÃO SOLICITADA
CORREÇÃO SOLICITADA --novo PDF/versão--> EM ANÁLISE
```

**Proibido:** aluno aprovar; revisar versão antiga; decidir duas vezes a mesma versão; sobrescrever PDF histórico; mudar de status por atualização direta do cliente; reenvio de aprovado sem regra explícita; abrir documento de terceiro; aceitar motivo vazio para correção.

### Progresso

`aprovados_obrigatórios / total_obrigatórios_aplicáveis`. `em análise` e `correção solicitada` não contam como aprovados. Requisito opcional não bloqueia. Denominador zero ou template não configurado exige estado **indeterminado**, não 100%.

### Concorrência, privacidade e erros

- Transições de revisão e incremento de versão precisam ser **atômicas** e condicionadas ao estado vigente.
- Usar constraints/locks ou controle de concorrência para impedir submissão ou decisão duplicada.
- Se upload falhar, não registrar submissão como entregue; tratar objetos órfãos e repetição idempotente.
- RLS também para `storage.objects`, histórico, métricas e notificações; testar com aluno A, aluno B, revisor atribuído e não atribuído.
- Links de arquivo curtos e emitidos após autorização; não incluir nomes/CPF no path ou segredos em logs.

## 4. Plano de execução por sprint

**Cadência:** seis sprints de duas semanas. Planejamento, sincronizações, PR com revisão, demo e retrospectiva. **Marco P0 ao final da Sprint 4:** aluno envia → revisor solicita correção → aluno reenvia → revisor aprova → progresso atualiza.

**Definition of Done:** PR revisado; CI verde; migrations reproduzíveis; RN verificadas; testes positivos e negativos (especialmente autorização); loading/erro/sucesso tratados; demo e documentação atualizados; dados fictícios; sem falhas críticas conhecidas.

### Sprint 1 — Descoberta e fundação (semanas 1–2)

**Objetivo/gate:** Validar curso piloto, regras e fluxo real; criar primeiro protótipo e base técnica.

#### ESP-01 — Confirmar curso piloto de tecnologia com estágio obrigatório
**Responsável sugerido:** D1 Jackson | **Estimativa:** 3 SP | **Dependências:** Nenhuma
**Objetivo de negócio:** Escolher um curso e uma modalidade cujo estágio curricular obrigatório seja realmente exigido e documentado.
**Regras de negócio:**
- **RN1.** Obrigatoriedade não se presume pela nomenclatura do curso
- **RN2.** documentos do PPC/regulamento ou confirmação competente são fontes
- **RN3.** escopo do piloto limita-se a um curso e uma modalidade.

**Lógica técnica de implementação:**
- **T1.** Consultar matriz curricular e regulamento vigentes
- **T2.** registrar fonte, data e responsável
- **T3.** montar matriz de curso e modalidade
- **T4.** criar decisão documentada e restrições do domínio.

**Critérios de aceite / testes:**
- **CA1.** Curso/modalidade identificados com fonte
- **CA2.** exigências ainda incertas sinalizadas como pendentes
- **CA3.** decisão revisada pelo grupo.

**Entregável verificável:** Matriz de validação do curso piloto e registro de decisão.

#### ESP-02 — Entrevistar estudantes sobre as dificuldades do estágio obrigatório
**Responsável sugerido:** D1 Jackson + D5 Vicenzo | **Estimativa:** 5 SP | **Dependências:** ESP-01
**Objetivo de negócio:** Comprovar quais problemas os estudantes realmente têm na entrega, correção e acompanhamento documental.
**Regras de negócio:**
- **RN1.** Dores são hipóteses até validação
- **RN2.** entrevistas voluntárias e anonimizadas
- **RN3.** não coletar matrículas e documentos pessoais
- **RN4.** mínimo de seis entrevistas, preferencialmente oito a doze.

**Lógica técnica de implementação:**
- **T1.** Preparar roteiro com perguntas abertas
- **T2.** abordar estudantes que já passaram pelo fluxo
- **T3.** registrar etapas, frequência e impacto de problemas
- **T4.** produzir jornada AS-IS e quadro de prioridades.

**Critérios de aceite / testes:**
- **CA1.** Ao menos seis entrevistas documentadas de forma anônima
- **CA2.** principais dores com evidências
- **CA3.** lista P0/P1 revisada com os achados.

**Entregável verificável:** Relatório de entrevistas e mapa das dores.

#### ESP-03 — Entrevistar responsável pela análise dos estágios
**Responsável sugerido:** D4 Marcel + D1 Jackson | **Estimativa:** 5 SP | **Dependências:** ESP-01
**Objetivo de negócio:** Descobrir quem recebe documentos, valida requisitos, solicita correções e decide no processo real.
**Regras de negócio:**
- **RN1.** Não confundir conferência documental com autorização institucional
- **RN2.** papéis, exceções, assinaturas e prazos devem ser confirmados
- **RN3.** ausência de entrevista não autoriza inventar regras.

**Lógica técnica de implementação:**
- **T1.** Preparar roteiro do fluxo atual
- **T2.** entrevistar responsável institucional ou equivalente
- **T3.** desenhar transições AS-IS, decisões e exceções
- **T4.** identificar permissões mínimas de cada papel.

**Critérios de aceite / testes:**
- **CA1.** Fluxo atual documentado ou marcado expressamente como não validado
- **CA2.** papéis e responsabilidades definidos para o cenário acadêmico.

**Entregável verificável:** Fluxo AS-IS e matriz de responsáveis.

#### ESP-04 — Levantar documentos, prazos e regras do curso piloto
**Responsável sugerido:** D3 Marcos + D4 Marcel | **Estimativa:** 5 SP | **Dependências:** ESP-01 e ESP-03
**Objetivo de negócio:** Determinar quais itens aparecerão no checklist de forma rastreável e configurável.
**Regras de negócio:**
- **RN1.** Cada requisito deve ter título, descrição, obrigatoriedade, fonte e critério
- **RN2.** itens opcionais não impedem conclusão
- **RN3.** uma alteração futura não deve modificar processos antigos.

**Lógica técnica de implementação:**
- **T1.** Elaborar tabela de requisitos, modalidade, prazo e origem
- **T2.** separar confirmação de hipótese
- **T3.** derivar modelo versionado e regras de aplicabilidade
- **T4.** validar a matriz com responsável.

**Critérios de aceite / testes:**
- **CA1.** Matriz completa com origem de cada regra e status de validação
- **CA2.** nenhum documento não confirmado apresentado como regra oficial.

**Entregável verificável:** Catálogo validável de requisitos e regras.

#### ESP-05 — Criar protótipo navegável do aluno e revisor no Figma
**Responsável sugerido:** D1 Jackson + D2 Bernardo + D4 Marcel | **Estimativa:** 5 SP | **Dependências:** ESP-02, ESP-03 e ESP-04
**Objetivo de negócio:** Produzir pela primeira vez uma representação navegável da jornada para testar antes de desenvolver telas definitivas.
**Regras de negócio:**
- **RN1.** No momento não há protótipo no Figma
- **RN2.** estados devem usar texto além de cores
- **RN3.** a UI não pode chamar revisão interna de autorização oficial.

**Lógica técnica de implementação:**
- **T1.** Desenhar arquitetura de informação e wireframes
- **T2.** criar telas mobile e web de envio/revisão/reenvio
- **T3.** incluir loading, vazio, erro e devolutiva
- **T4.** construir interações clicáveis e recolher feedback.

**Critérios de aceite / testes:**
- **CA1.** Protótipo criado do zero, link anexado após criação
- **CA2.** fluxo sem telas órfãs
- **CA3.** problemas encontrados anotados.

**Entregável verificável:** Protótipo Figma a criar na Sprint 1 e relatório de validação.

#### ESP-06 — Configurar Flutter, Supabase, GitHub e integração contínua
**Responsável sugerido:** D2 Bernardo + D3 Marcos + D5 Vicenzo | **Estimativa:** 5 SP | **Dependências:** Nenhuma
**Objetivo de negócio:** Criar uma base técnica compartilhável para desenvolvimento paralelo e entregas revisáveis.
**Regras de negócio:**
- **RN1.** Dados de teste fictícios
- **RN2.** nenhum segredo ou chave administrativa no Flutter
- **RN3.** CI deve impedir integração de código inválido
- **RN4.** ambientes separados por finalidade.

**Lógica técnica de implementação:**
- **T1.** Inicializar Flutter Android e Web
- **T2.** criar repositório, README e .env.example
- **T3.** estruturar módulos e dependências
- **T4.** configurar ambientes Supabase e pipeline de format/analyze/test em GitHub Actions.

**Critérios de aceite / testes:**
- **CA1.** Projeto roda ao clonar e seguir README
- **CA2.** pipeline verde
- **CA3.** segredos ausentes do repositório.

**Entregável verificável:** Bootstrap do projeto e pipeline CI reproduzível.

#### ESP-07 — Modelar dados iniciais e políticas de autorização
**Responsável sugerido:** D3 Marcos + D5 Vicenzo | **Estimativa:** 5 SP | **Dependências:** ESP-04 e ESP-06
**Objetivo de negócio:** Construir modelo relacional que suporte processos, requisitos e histórico com isolamento de dados.
**Regras de negócio:**
- **RN1.** Aluno é dono de seu processo
- **RN2.** revisor precisa de atribuição válida
- **RN3.** templates são versionados
- **RN4.** não confiar em filtro Flutter para segurança.

**Lógica técnica de implementação:**
- **T1.** Criar migrations SQL de cursos, perfis, processos, requisitos, submissões e revisão
- **T2.** definir chaves e índices
- **T3.** habilitar RLS default deny
- **T4.** testar usuário A x B e papéis de revisor.

**Critérios de aceite / testes:**
- **CA1.** Migrations reaplicáveis
- **CA2.** testes negam acesso cruzado
- **CA3.** diagrama relacional e evidências versionados.

**Entregável verificável:** Banco inicial e conjunto de testes RLS.

### Sprint 2 — Autenticação e processos (semanas 3–4)

**Objetivo/gate:** Aluno autenticado abre processo e visualiza checklist versionado sem acessar dados de terceiros.

#### ESP-08 — Cadastro, login, logout e recuperação de senha
**Responsável sugerido:** D2 Bernardo + D3 Marcos | **Estimativa:** 5 SP | **Dependências:** ESP-06 e ESP-07
**Objetivo de negócio:** Permitir que estudantes e revisores se autentiquem e retomem suas sessões com segurança.
**Regras de negócio:**
- **RN1.** Cadastro público cria estudante
- **RN2.** ninguém se torna revisor por escolher papel no formulário
- **RN3.** sem sessão válida não há acesso
- **RN4.** não vazar existência de e-mail cadastrado.

**Lógica técnica de implementação:**
- **T1.** Integrar supabase_flutter Auth e AuthRepository
- **T2.** gerenciar sessão e guards de rotas
- **T3.** implementar recuperação de senha/deep link
- **T4.** testar expiração, logout e persistência sem expor token.

**Critérios de aceite / testes:**
- **CA1.** Cadastro cria estudante
- **CA2.** logout impede acesso a rotas privadas
- **CA3.** recuperação não revela dados de terceiros.

**Entregável verificável:** Telas de autenticação e testes de sessão.

#### ESP-09 — Perfis de aluno e revisor com autorização
**Responsável sugerido:** D3 Marcos + D4 Marcel | **Estimativa:** 5 SP | **Dependências:** ESP-07 e ESP-08
**Objetivo de negócio:** Separar atribuições de alunos e revisores no banco, tornando impossível a autoelevação de privilégios.
**Regras de negócio:**
- **RN1.** Somente operação privilegiada concede role de revisor
- **RN2.** revisor vê processos de escopo atribuído
- **RN3.** sem atribuição negar por padrão.

**Lógica técnica de implementação:**
- **T1.** Criar profiles.role e reviewer_assignments
- **T2.** aplicar RLS por operação em tabelas e storage
- **T3.** adicionar guards UI por experiência
- **T4.** escrever testes de alteração de role e de acesso de terceiros.

**Critérios de aceite / testes:**
- **CA1.** Aluno não consegue aprovar nem alterar role
- **CA2.** revisor sem assignment vê zero registros
- **CA3.** negações ocorrem mesmo por API direta.

**Entregável verificável:** Permissões server-side e testes adversariais.

#### ESP-10 — Abertura, listagem e detalhes de processos
**Responsável sugerido:** D2 Bernardo + D3 Marcos | **Estimativa:** 5 SP | **Dependências:** ESP-08, ESP-09 e ESP-04
**Objetivo de negócio:** Dar ao aluno um processo persistente com curso, modalidade e status de acompanhamento.
**Regras de negócio:**
- **RN1.** owner_id deve vir da sessão e não da entrada do cliente
- **RN2.** curso/modalidade precisam estar válidos
- **RN3.** duplicidade de processo ativo deve obedecer regra explícita.

**Lógica técnica de implementação:**
- **T1.** Criar tabela internship_processes com integridade e índices
- **T2.** construir repositories/create/list/detail
- **T3.** criar processo e requisitos em operação consistente
- **T4.** tratar erros e indisponibilidade de checklist.

**Critérios de aceite / testes:**
- **CA1.** Aluno cria e retoma seu processo
- **CA2.** não consulta processo de outro
- **CA3.** duplicações inválidas são rejeitadas sem registros parciais.

**Entregável verificável:** CRUD de processos e telas mobile.

#### ESP-11 — Checklist dinâmico por curso e modalidade
**Responsável sugerido:** D3 Marcos + D2 Bernardo + D1 Jackson | **Estimativa:** 5 SP | **Dependências:** ESP-04, ESP-07 e ESP-10
**Objetivo de negócio:** Aplicar ao processo apenas os requisitos válidos para o curso e modalidade escolhidos.
**Regras de negócio:**
- **RN1.** Templates têm versão e origem
- **RN2.** no início do processo registrar snapshot
- **RN3.** itens opcionais não contam como pendência obrigatória
- **RN4.** ausência de configuração não equivale a 100%.

**Lógica técnica de implementação:**
- **T1.** Implementar tabelas requirement_templates e process_requirements
- **T2.** criar serviço transacional de snapshot
- **T3.** implementar tela de detalhes/obrigatoriedade/status
- **T4.** testar templates v1/v2 e falhas de configuração.

**Critérios de aceite / testes:**
- **CA1.** Checklist corresponde à modalidade do processo
- **CA2.** versão nova não altera processo antigo
- **CA3.** não apresentar conclusão sem requisitos validados.

**Entregável verificável:** Checklist dinâmico e testes de versões.

#### ESP-12 — Testes de autenticação, papéis e formulários
**Responsável sugerido:** D5 Vicenzo + D3 Marcos | **Estimativa:** 3 SP | **Dependências:** ESP-08 a ESP-11
**Objetivo de negócio:** Prevenir falhas básicas de sessão, validação e isolamento antes de lidar com arquivos pessoais.
**Regras de negócio:**
- **RN1.** Testes de negação de acesso são obrigatórios
- **RN2.** não confiar apenas no frontend
- **RN3.** toda mudança de role ou owner precisa ser autorizada.

**Lógica técnica de implementação:**
- **T1.** Automatizar unitários de validação e mapeamento de erros
- **T2.** integrar testes A/B/revisor
- **T3.** cobrir expiração, roles, templates, processo duplicado e sessão renovada
- **T4.** executar no CI.

**Critérios de aceite / testes:**
- **CA1.** CI passa
- **CA2.** remoção de policy causa falha
- **CA3.** acesso cruzado bloqueado
- **CA4.** formulários apresentam erros claros.

**Entregável verificável:** Suite automatizada e relatório de execução.

### Sprint 3 — Documentos e privacidade (semanas 5–6)

**Objetivo/gate:** Aluno anexa PDF privado, mantém versões e vê progresso correto.

#### ESP-13 — Armazenamento privado e políticas de acesso
**Responsável sugerido:** D3 Marcos + D5 Vicenzo | **Estimativa:** 5 SP | **Dependências:** ESP-07, ESP-09 e ESP-10
**Objetivo de negócio:** Proteger PDFs e metadados contra acesso indevido dentro e fora da aplicação.
**Regras de negócio:**
- **RN1.** Apenas aluno dono e revisor atribuído podem acessar
- **RN2.** bucket não é público
- **RN3.** path conhecido não confere acesso
- **RN4.** não usar chaves service_role no cliente.

**Lógica técnica de implementação:**
- **T1.** Criar bucket privado com paths opacos por processo/requisito/versão
- **T2.** configurar RLS em storage.objects e tabelas
- **T3.** usar download autenticado ou signed URLs curtos após autorização
- **T4.** testar isolamento com usuários distintos.

**Critérios de aceite / testes:**
- **CA1.** Link sem sessão/escopo é negado
- **CA2.** owner e revisor correto têm acesso
- **CA3.** não há URL pública permanente.

**Entregável verificável:** Bucket privado, políticas e testes de privacidade.

#### ESP-14 — Upload de documentos PDF
**Responsável sugerido:** D2 Bernardo + D3 Marcos | **Estimativa:** 5 SP | **Dependências:** ESP-11 e ESP-13
**Objetivo de negócio:** Fazer o estudante enviar documentos aos requisitos corretos com feedback inequívoco de sucesso/falha.
**Regras de negócio:**
- **RN1.** Só pode submeter ao próprio requisito em estado permitido
- **RN2.** envio concluído significa em análise, nunca aprovado
- **RN3.** aceitar apenas arquivos segundo regras validadas.

**Lógica técnica de implementação:**
- **T1.** Flutter file picker e validação local
- **T2.** upload com chave única sem overwrite
- **T3.** persistir submissão somente após Storage confirmar
- **T4.** tratar compensação de upload órfão e exibir progresso/erro de rede.

**Critérios de aceite / testes:**
- **CA1.** PDF válido aparece em análise
- **CA2.** arquivo grande ou inválido não gera submissão válida
- **CA3.** falha de conexão não aparece como entregue.

**Entregável verificável:** Tela de upload e integração privada.

#### ESP-15 — Versionamento e estados das submissões
**Responsável sugerido:** D3 Marcos + D4 Marcel | **Estimativa:** 5 SP | **Dependências:** ESP-07, ESP-11 e ESP-14
**Objetivo de negócio:** Permitir correções sem perder provas das submissões e impedir decisões sobre arquivos obsoletos.
**Regras de negócio:**
- **RN1.** Histórico de versões imutável
- **RN2.** só a versão vigente pode receber análise
- **RN3.** aluno não pode mudar status para aprovado
- **RN4.** reenvio cria versão nova.

**Lógica técnica de implementação:**
- **T1.** Criar document_submissions(version, key, status, submitted_at) com UNIQUE por requisito/versão
- **T2.** transação ou RPC para incremento atômico
- **T3.** máquina não enviado→em análise→aprovado/correção→nova análise
- **T4.** testar concorrência.

**Critérios de aceite / testes:**
- **CA1.** Versões anteriores preservadas
- **CA2.** decisão de versão obsoleta bloqueada
- **CA3.** concorrência não duplica versão.

**Entregável verificável:** Modelo versionado e máquina de estados.

#### ESP-16 — Progresso e visualização de pendências
**Responsável sugerido:** D1 Jackson + D2 Bernardo | **Estimativa:** 3 SP | **Dependências:** ESP-11, ESP-14 e ESP-15
**Objetivo de negócio:** Permitir ao aluno enxergar imediatamente documentos faltantes, enviados, aprovados e em correção.
**Regras de negócio:**
- **RN1.** Progresso considera apenas obrigatórios aprovados
- **RN2.** itens em análise ou correção não contam
- **RN3.** nenhum template/zero obrigatório não gera falso 100%
- **RN4.** status não autoriza estágio.

**Lógica técnica de implementação:**
- **T1.** Criar view agregada por processo
- **T2.** calcular aprovado/total obrigatórios no backend
- **T3.** implementar dashboard/indicadores e rótulos com texto/ícone
- **T4.** testar atualização após revisão e reenvio.

**Critérios de aceite / testes:**
- **CA1.** Percentuais corretos, inclusive casos limite
- **CA2.** correções com motivo aparecem claramente
- **CA3.** nenhuma indicação de autorização oficial.

**Entregável verificável:** Dashboard e consulta de progresso.

#### ESP-17 — Validação de formato, tamanho e falhas de upload
**Responsável sugerido:** D5 Vicenzo + D2 Bernardo + D3 Marcos | **Estimativa:** 3 SP | **Dependências:** ESP-13 a ESP-16
**Objetivo de negócio:** Evitar PDFs falsos, operações incompletas e bugs que deixem registros inconsistentes.
**Regras de negócio:**
- **RN1.** Limite de tamanho configurável e tipo PDF exigido
- **RN2.** falha parcial não conta como envio
- **RN3.** erros não mostram tokens ou paths internos.

**Lógica técnica de implementação:**
- **T1.** Validar extensão/MIME/magic bytes na borda confiável
- **T2.** tratar 401/403/413/offline/timeout
- **T3.** prevenir clique duplicado
- **T4.** limpar objetos órfãos e testar arquivo vazio ou camuflado.

**Critérios de aceite / testes:**
- **CA1.** Cenários inválidos sem submissão válida
- **CA2.** acesso de outro usuário negado
- **CA3.** testes negativos registrados.

**Entregável verificável:** Validações, testes de falha e mensagens úteis.

### Sprint 4 — Revisão e correção (semanas 7–8)

**Objetivo/gate:** Ciclo completo de devolutiva, reenvio e aprovação protegido no backend.

#### ESP-18 — Fila de documentos para revisão
**Responsável sugerido:** D4 Marcel + D3 Marcos | **Estimativa:** 5 SP | **Dependências:** ESP-09, ESP-15 e ESP-16
**Objetivo de negócio:** Disponibilizar ao revisor uma lista clara de itens que aguardam uma decisão.
**Regras de negócio:**
- **RN1.** Mostrar apenas última versão em análise dentro do escopo do revisor
- **RN2.** sem assignment não existem itens visíveis
- **RN3.** não listar versões antigas ou decididas.

**Lógica técnica de implementação:**
- **T1.** Query/view com join de submissão corrente e reviewer_assignments com RLS
- **T2.** implementar Flutter Web responsivo com paginação, filtros e estados vazios
- **T3.** testar múltiplos revisores.

**Critérios de aceite / testes:**
- **CA1.** Apenas revisores autorizados veem itens adequados
- **CA2.** lista filtra e pagina
- **CA3.** acesso por API fora do escopo negado.

**Entregável verificável:** Fila de revisão testada com papéis distintos.

#### ESP-19 — Visualização segura de PDFs pelo revisor
**Responsável sugerido:** D4 Marcel + D3 Marcos | **Estimativa:** 3 SP | **Dependências:** ESP-13, ESP-14 e ESP-18
**Objetivo de negócio:** Permitir conferir conteúdo e versão do documento sem expô-lo publicamente.
**Regras de negócio:**
- **RN1.** Somente aluno dono e revisor atribuído acessam
- **RN2.** links temporários expiram
- **RN3.** identificação da versão deve preceder decisão.

**Lógica técnica de implementação:**
- **T1.** Validar auth.uid(), owner/assignment e submission_id
- **T2.** emitir signed URL curta ou download autenticado
- **T3.** viewer PDF Web com fallback
- **T4.** testar alteração de IDs e links expirados.

**Critérios de aceite / testes:**
- **CA1.** PDF correto abre ao revisor
- **CA2.** usuário anônimo/terceiro falha
- **CA3.** link só renova após autorização.

**Entregável verificável:** Viewer privado com testes de expiração.

#### ESP-20 — Aprovação ou solicitação de correção com motivo
**Responsável sugerido:** D3 Marcos + D4 Marcel | **Estimativa:** 5 SP | **Dependências:** ESP-09, ESP-15, ESP-18 e ESP-19
**Objetivo de negócio:** Registrar uma decisão clara, segura e auditável sobre cada versão submetida.
**Regras de negócio:**
- **RN1.** Somente revisor atribuído decide versão atual em análise
- **RN2.** correção exige justificativa
- **RN3.** decisão é única por versão
- **RN4.** aprovação documental não equivale à autorização oficial.

**Lógica técnica de implementação:**
- **T1.** Implementar RPC transacional review_submission verificando sessão/assignment/estado
- **T2.** aplicar controle de concorrência e constraint
- **T3.** gravar review imutável e transição na mesma operação
- **T4.** formular decisão Flutter Web.

**Critérios de aceite / testes:**
- **CA1.** Aluno não consegue aprovar
- **CA2.** correção sem motivo é negada
- **CA3.** dupla decisão bloqueada
- **CA4.** feedback visível no checklist.

**Entregável verificável:** Decisão segura e testes concorrentes.

#### ESP-21 — Histórico de revisões e eventos de auditoria
**Responsável sugerido:** D3 Marcos + D5 Vicenzo | **Estimativa:** 5 SP | **Dependências:** ESP-15 e ESP-20
**Objetivo de negócio:** Tornar possível reconstruir versões, decisões e correções ao longo de todo o processo.
**Regras de negócio:**
- **RN1.** Histórico append-only
- **RN2.** aluno não altera registro
- **RN3.** somente usuários com acesso ao processo veem timeline
- **RN4.** versões antigas não substituem status atual.

**Lógica técnica de implementação:**
- **T1.** Criar audit_events com ator, ação, versão, momento e metadados mínimos
- **T2.** gravar na mesma transação de mudança
- **T3.** listar timeline paginada com RLS e exibir hora local.

**Critérios de aceite / testes:**
- **CA1.** Toda transição gera evento
- **CA2.** histórico preserva autor e motivo
- **CA3.** tentativa de alteração/consulta cruzada negada.

**Entregável verificável:** Trilha de auditoria e timeline.

#### ESP-22 — Reenvio após correção e nova análise
**Responsável sugerido:** D2 Bernardo + D3 Marcos + D4 Marcel | **Estimativa:** 5 SP | **Dependências:** ESP-15, ESP-20 e ESP-21
**Objetivo de negócio:** Fechar o ciclo entre estudante e revisor preservando todo o histórico documental.
**Regras de negócio:**
- **RN1.** Só reenviar quando estado permitir
- **RN2.** nova versão não herda aprovação
- **RN3.** justificativa anterior persiste
- **RN4.** conclusão exige aprovação dos obrigatórios vigentes.

**Lógica técnica de implementação:**
- **T1.** Exibir motivo e botão corrigir no mobile
- **T2.** criar novo arquivo privado e versão atômica
- **T3.** atualizar fila e histórico
- **T4.** testar E2E aluno envia→revisor corrige→aluno reenvia→revisor aprova.

**Critérios de aceite / testes:**
- **CA1.** Versão n+1 aparece em análise
- **CA2.** n permanece
- **CA3.** fluxo completo demonstrável até fim da Sprint 4.

**Entregável verificável:** Ciclo ponta a ponta funcionando.

### Sprint 5 — Alertas, métricas e qualidade (semanas 9–10)

**Objetivo/gate:** Adicionar valor operacional sem prejudicar fluxo P0, acessibilidade e testes.

#### ESP-23 — Central de notificações in-app
**Responsável sugerido:** D2 Bernardo + D3 Marcos | **Estimativa:** 3 SP | **Dependências:** ESP-20 e ESP-21
**Objetivo de negócio:** Informar sobre aprovação e solicitação de correção sem consulta manual constante.
**Regras de negócio:**
- **RN1.** Cada evento gera notificação somente ao aluno dono
- **RN2.** ler notificação não altera estado
- **RN3.** não divulgar conteúdos sensíveis
- **RN4.** deduplicar por evento.

**Lógica técnica de implementação:**
- **T1.** Tabela notifications com recipient, event_key e read_at
- **T2.** emitir eventos no backend após decisão
- **T3.** tela Flutter com não lidos e marcação protegida
- **T4.** testes de duplicidade e isolamento.

**Critérios de aceite / testes:**
- **CA1.** Aviso correto aparece uma vez para o destinatário
- **CA2.** aluno B não vê de A
- **CA3.** status permanece inalterado ao marcar lida.

**Entregável verificável:** Central de avisos e testes de entrega.

#### ESP-24 — Prazos e alertas de pendências
**Responsável sugerido:** D3 Marcos + D5 Vicenzo | **Estimativa:** 3 SP | **Dependências:** ESP-04, ESP-11 e ESP-23
**Objetivo de negócio:** Antecipar atrasos usando apenas datas que sejam confirmadas ou configuradas pelo processo.
**Regras de negócio:**
- **RN1.** Sem prazo validado não há atraso
- **RN2.** alerta não bloqueia envio por si
- **RN3.** timezone coerente e alertas idempotentes.

**Lógica técnica de implementação:**
- **T1.** Definir due_date em requisitos e regra de origem
- **T2.** calcular prazo no backend, exibir localmente e notificar por evento periódico se necessário
- **T3.** testar sem prazo, hoje, vencido e aprovado.

**Critérios de aceite / testes:**
- **CA1.** Ausência de prazo não gera aviso
- **CA2.** aviso liga ao requisito
- **CA3.** sem mensagens repetidas indevidas.

**Entregável verificável:** Alerta de prazo configurável e testes.

#### ESP-25 — Indicadores básicos para revisores
**Responsável sugerido:** D4 Marcel + D3 Marcos | **Estimativa:** 5 SP | **Dependências:** ESP-18, ESP-20 e ESP-21
**Objetivo de negócio:** Mostrar volume de documentos e correções para facilitar gestão da fila sem expor dados de terceiros.
**Regras de negócio:**
- **RN1.** Indicador limitado ao escopo de reviewer_assignment
- **RN2.** contagem por última versão
- **RN3.** histórico contado à parte
- **RN4.** métricas não avaliam oficialmente o aluno.

**Lógica técnica de implementação:**
- **T1.** Criar views agregadas/RPC por escopo e período
- **T2.** calcular fila, aprovados, correções e tempo de análise se mensurável
- **T3.** desenvolver dashboard web e validar em base conhecida.

**Critérios de aceite / testes:**
- **CA1.** Contagens conferem com dataset
- **CA2.** revisor não vê indicadores fora do escopo
- **CA3.** denominador ausente tratado.

**Entregável verificável:** Painel operacional com testes.

#### ESP-26 — Acessibilidade, responsividade e tratamento de erros
**Responsável sugerido:** D1 Jackson + D2 Bernardo + D5 Vicenzo | **Estimativa:** 5 SP | **Dependências:** ESP-08 a ESP-25
**Objetivo de negócio:** Deixar status, devolutivas e formulários compreensíveis em tela pequena, desktop e uso assistivo.
**Regras de negócio:**
- **RN1.** Nunca comunicar estado apenas por cor
- **RN2.** motivo da correção acessível
- **RN3.** erros orientam ação sem expor detalhes internos.

**Lógica técnica de implementação:**
- **T1.** Flutter Semantics, labels, navegação teclado e contraste
- **T2.** unificar loading/empty/error
- **T3.** revisar overflow mobile/web
- **T4.** testar com leitor de tela e conexão lenta.

**Critérios de aceite / testes:**
- **CA1.** Fluxos sem dependência de cor ou mouse
- **CA2.** erros recuperáveis
- **CA3.** resoluções-alvo sem overflow crítico.

**Entregável verificável:** Checklist de acessibilidade e correções.

#### ESP-27 — Automatizar testes ponta a ponta dos fluxos críticos
**Responsável sugerido:** D5 Vicenzo + D2 Bernardo + D3 Marcos | **Estimativa:** 5 SP | **Dependências:** ESP-08 a ESP-26
**Objetivo de negócio:** Garantir que jornada principal continue correta após integrar avisos e painel.
**Regras de negócio:**
- **RN1.** Cenários negativos são tão importantes quanto positivos
- **RN2.** usar dados fictícios
- **RN3.** conclusão só com todos obrigatórios aprovados.

**Lógica técnica de implementação:**
- **T1.** Teste automatizado login/processo/upload/revisão/correção/reenvio/aprovação
- **T2.** testar revisor não atribuído, usuário cruzado, token expirado e PDF inválido
- **T3.** criar fixtures resetáveis em CI.

**Critérios de aceite / testes:**
- **CA1.** 100% dos cenários críticos previstos passam
- **CA2.** quebrar RLS faz teste falhar
- **CA3.** demo reproduzível com seed.

**Entregável verificável:** Suite E2E e evidências CI.

### Sprint 6 — Estabilização e entrega (semanas 11–12)

**Objetivo/gate:** Segurança, resiliência, usabilidade, documentação e builds de demonstração.

#### ESP-28 — Testar segurança e isolamento de dados
**Responsável sugerido:** D3 Marcos + D5 Vicenzo | **Estimativa:** 3 SP | **Dependências:** ESP-09, ESP-13, ESP-19 e ESP-20
**Objetivo de negócio:** Comprovar que acessos aos processos e PDFs respeitam escopo inclusive em requisições diretas.
**Regras de negócio:**
- **RN1.** Aluno só acessa próprio processo
- **RN2.** revisor só escopo atribuído
- **RN3.** nenhuma transição privilegiada no cliente
- **RN4.** service_role nunca exposta.

**Lógica técnica de implementação:**
- **T1.** Matriz de testes RLS SQL e Storage com duas contas
- **T2.** revisar RPCs e tokens
- **T3.** testar acesso cruzado e URL temporária
- **T4.** auditar segredos/logs e dependências.

**Critérios de aceite / testes:**
- **CA1.** Todas as negações funcionam
- **CA2.** zero vulnerabilidades críticas conhecidas
- **CA3.** relatório e evidências registrados.

**Entregável verificável:** Relatório de segurança e testes adversariais.

#### ESP-29 — Revisar desempenho e recuperação de falhas
**Responsável sugerido:** D2 Bernardo + D3 Marcos | **Estimativa:** 3 SP | **Dependências:** ESP-14, ESP-15, ESP-18 e ESP-27
**Objetivo de negócio:** Evitar operações duplicadas e estados inconsistentes após internet instável e erros de backend.
**Regras de negócio:**
- **RN1.** Falha não pode aparecer como sucesso
- **RN2.** repetição não duplica versão ou review
- **RN3.** ações recuperáveis conservam dados preenchidos.

**Lógica técnica de implementação:**
- **T1.** Paginar e indexar consultas
- **T2.** implementar timeout/retry com idempotência
- **T3.** detectar arquivos órfãos
- **T4.** testar clique repetido, sessão vencida e falha no upload.

**Critérios de aceite / testes:**
- **CA1.** Sem duplicação
- **CA2.** carregamento e falha coerentes
- **CA3.** lista continua utilizável em volume de dados de demonstração.

**Entregável verificável:** Plano de resiliência e correções.

#### ESP-30 — Realizar testes de usabilidade e correções prioritárias
**Responsável sugerido:** D1 Jackson + D5 Vicenzo | **Estimativa:** 5 SP | **Dependências:** ESP-22, ESP-26 e ESP-27
**Objetivo de negócio:** Verificar se o usuário compreende o que precisa enviar, corrigir e acompanhar sem ajuda excessiva.
**Regras de negócio:**
- **RN1.** Usar contas/arquivos fictícios
- **RN2.** não confundir aprovado com autorização de estágio
- **RN3.** avaliar necessidades reais de aluno/revisor.

**Lógica técnica de implementação:**
- **T1.** Roteiro de tarefas de abertura, upload e reenvio
- **T2.** sessões acompanhadas e métricas simples
- **T3.** priorizar bloqueadores e retestar após correção.

**Critérios de aceite / testes:**
- **CA1.** Meta sugerida de 80% de conclusão sem ajuda
- **CA2.** nenhum bloqueio grave aberto
- **CA3.** relatório de achados e ajustes.

**Entregável verificável:** Relatório de usabilidade e retestes.

#### ESP-31 — Preparar documentação técnica e apresentação
**Responsável sugerido:** D1 Jackson + D4 Marcel + equipe | **Estimativa:** 3 SP | **Dependências:** ESP-01 a ESP-30
**Objetivo de negócio:** Permitir reprodução técnica e explicação acadêmica do problema, regras, decisões e limites do MVP.
**Regras de negócio:**
- **RN1.** Distinguir hipóteses e fatos
- **RN2.** não incluir dados reais, nem alegar parceria/integração oficial
- **RN3.** todos devem saber apresentar.

**Lógica técnica de implementação:**
- **T1.** README de setup, migrations e seeds
- **T2.** diagrama de domínio, RLS e estados
- **T3.** roteiro demo com alunos/revisores fictícios
- **T4.** anexar testes, arquitetura e limitações.

**Critérios de aceite / testes:**
- **CA1.** Outro integrante executa ambiente só pelo README
- **CA2.** apresentação cobre envio→correção→aprovação
- **CA3.** cinco membros aptos a explicar.

**Entregável verificável:** Documentação, roteiro e material para o professor.

#### ESP-32 — Publicar painel web e gerar build Android
**Responsável sugerido:** D2 Bernardo + D5 Vicenzo + D3 Marcos | **Estimativa:** 5 SP | **Dependências:** ESP-28 a ESP-31
**Objetivo de negócio:** Entregar uma versão instalável, demonstrável e reproduzível em ambiente acadêmico isolado.
**Regras de negócio:**
- **RN1.** Ambiente usa dados fictícios
- **RN2.** web exige autenticação
- **RN3.** publicar não significa integrar sistemas UNIPÊ
- **RN4.** rollback documentado.

**Lógica técnica de implementação:**
- **T1.** Gerar Flutter Android release e smoke test
- **T2.** fazer Flutter Web build HTTPS com rotas
- **T3.** aplicar migrations no ambiente demo, políticas RLS e secrets
- **T4.** registrar tag/release e passos de implantação.

**Critérios de aceite / testes:**
- **CA1.** APK instala, painel HTTPS funciona, ciclo completo demonstrável
- **CA2.** negações testadas no deploy
- **CA3.** instruções e URL disponibilizadas.

**Entregável verificável:** APK e painel web de demonstração com checklist de release.

## 5. Responsabilidades e comunicação

- **D1 Jackson Fabiano Macena Dias Filho (líder):** coordenação, descoberta, requisitos, UX/fluxo do aluno e documentação.
- **D2 Bernardo Mourthé e Silva:** Flutter Mobile, formulários, checklist, upload e reenvio.
- **D3 Marcos Vinicius da Silva Pimentel:** Supabase, Auth, PostgreSQL, Storage privado, RLS, transações e segurança.
- **D4 Marcel Paiva Martins Filho:** Flutter Web, fila e visualização do revisor, decisões e métricas.
- **D5 Vicenzo Benelli da Silva:** QA, CI, testes de segurança/regressão, notificações, acessibilidade e suporte ao UX.

Atribuições são sugestões e não substituem code review cruzado. Integrantes ainda devem ser adicionados ao Trello conforme suas contas.

## 6. Procedimento padrão para um agente ao receber uma task

1. Identifique o card `ESP-XX`, sprint, responsável e dependências. Leia a descrição do Trello e este arquivo.
2. Inspecione código, banco, migrations, testes, CI e documentos reais do repositório; anote o que já existe e o que está ausente.
3. Escreva um plano incremental com arquivos/migrations e impacto em regras RN, autorização e fluxos.
4. Se depender de regra não validada, **pare a parte normativa**, proponha configuração fictícia e registre questão aberta.
5. Implemente com autorização backend e tratamento de erros; preserve compatibilidade das migrations e histórico.
6. Adicione testes de casos de sucesso, falha, usuário sem permissão, concorrência quando aplicável e regressão.
7. Execute `flutter format`/`dart format`, `flutter analyze`, `flutter test` e testes de integração/SQL disponíveis; **não invente resultado**.
8. Prepare PR com: objetivo, RN implementadas, decisões, testes executados, evidências, migrações, riscos e próximos passos. Mova no Trello somente após aceite.

## 7. Template para prompt de implementação de task

```text
Você é engenheiro de software no projeto Estágio sem Pendência.
Leia AGENTS_CONTEXT.md, README, migrations, testes e a descrição atual do card ESP-XX.
Não assuma que tarefas anteriores estão implementadas.
Audite o estado atual do código; liste lacunas e dependências.
Implemente SOMENTE o escopo da ESP-XX, respeitando RN, lógica técnica e CA documentados.
Não invente regras de estágio; não alegue autorização institucional.
Toda autorização crítica deve ser garantida no backend (RLS/RPC/Storage), não só Flutter.
Use dados fictícios; inclua testes positivos, negativos e de autorização.
Ao final apresente arquivos alterados, comandos/testes realmente executados,
resultados, riscos, critérios de aceite verificados e o que ficou pendente.
```

## 8. Referências de trabalho e divergências

- Quadro Trello: https://trello.com/b/xmO3dE2C/est%C3%A1gio-sem-pend%C3%AAncia-mvp-tecnologia
- PDF de equipe: `Planejamento_Detalhado_Estagio_sem_Pendencia.pdf`.
- Documento anterior anexado: `Texto colado(3).txt` é **histórico**, não backlog atual. Possui 30 cards e numeração antiga. A numeração **vigente é ESP-01 a ESP-32** do Trello.
- A equipe deve validar o curso piloto e a lista de documentos antes de tratá-los como regras oficiais.
