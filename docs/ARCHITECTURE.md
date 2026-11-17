# Arquitetura — Estágio sem Pendência (Lote 1)

Um único projeto Flutter atende Android e Web compartilhando tema Material 3, regras de validação de entrada, controle de sessão e testes de interface.

## Camadas Flutter

- `lib/app/`: composição global (`EstagioSemPendenciaApp`) e tema (`AppTheme`).
- `lib/core/`: configuração pública por `--dart-define` (`SupabaseConfig`) e breakpoints responsivos (`AppBreakpoints`).
- `lib/features/auth/`:
  - `domain/`: `UserRole`, `UserProfile`, `AuthFailure` e contrato `AuthGateway`.
  - `data/`: `SupabaseAuthGateway` com PKCE, tratamento de links/callbacks, mapeamento seguro de erros sem vazamento de detalhes internos e validação de sessão no servidor (`auth.getUser()` + `profiles`).
  - `application/`: `AuthController` (`ChangeNotifier`) com proteção de época contra condições de corrida e limpeza imediata de estado em logout ou sessão inválida.
  - `presentation/`: `AuthGate`, `AuthScreen`, `ResetPasswordPage`, `StudentHomePage` e `ReviewerHomePage`, trocando o widget raiz de forma declarativa para impedir que o histórico de navegação na Web/Android reexiba telas privadas após logout.

Não foram adicionados roteadores externos nem gerenciadores de estado de terceiros.

## Modelo de Dados e Autorização (Backend)

As migrations versionadas em `supabase/migrations/` implementam as 12 tabelas de domínio e a view de progresso calculado:

1. Catálogo configurável (fictício no `seed.sql`): `institutions`, `courses`, `course_modalities`, `requirement_templates`, `requirement_template_items`.
2. Identidade e escopo: `profiles`, `reviewer_assignments`.
3. Processos e evidências: `internship_processes`, `process_requirements`, `document_submissions`, `document_reviews`, `audit_events` e a view `process_progress_v` (`WITH (security_invoker = true)`).

### Invariantes de Segurança

- **RLS deny-by-default:** habilitada em todas as 12 tabelas de domínio e ativa em `storage.buckets`/`storage.objects` (sem políticas abertas no Lote 1).
- **Zero acesso `anon` e isolamento de privilégios:** privilégios de `anon` revogados em todas as tabelas, views e funções do schema `public`; `REVOKE ALL ON FUNCTION` aplicado após a criação das rotinas e reforçado com `ALTER DEFAULT PRIVILEGES FOR ROLE postgres` global e no schema `public` revogando `EXECUTE` de `PUBLIC`, `anon` e `authenticated` para futuras funções.
- **Cadastro sempre estudante:** trigger `handle_new_user()` em `auth.users` força `role = 'student'`, ignora qualquer `role` enviada nos metadados e registra `profile_created` em `audit_events`.
- **Proteção de perfil, vínculos compostos e imutabilidade:** coluna `role` protegida por `REVOKE`/`GRANT UPDATE (full_name)` e `guard_profiles_write()`. A integridade entre processo, template e submissão corrente é garantida no banco por chaves compostas (`uq_requirement_templates_scope` → `fk_internship_processes_template_scope` e `uq_document_submissions_id_req_version` → `fk_process_requirements_current_submission`), triggers de validação (`validate_internship_process_insert`, `validate_process_requirement_origin`, `guard_document_reviews_insert`) e travas estritas de imutabilidade e transições (`guard_requirement_templates_immutability`, `guard_requirement_template_items_immutability` validando template origem/destino e bloqueando alteração de `template_id`, `guard_internship_processes_immutability`, `guard_process_requirements_immutability` validando `status`/`current_submission_id`/`current_version` mesmo sem mudança de status, e `guard_document_submissions_immutability`), além de `ON DELETE RESTRICT`.
- **Isolamento de processos e escopo:** estudante acessa apenas registros em que `owner_id = auth.uid()`. Revisor acessa apenas processos dentro de `reviewer_assignments` ativos verificados por `public.is_assigned_reviewer(...)`.
- **Provisionamento privilegiado com proveniência auditável:** `admin_set_user_role`, `admin_assign_reviewer_scope` e `admin_revoke_reviewer_assignment` exigem contexto privilegiado (`service_role` ou administrador SQL), validam o operador por `_resolve_privileged_operator` (`verified_human_operator`, `technical_automation` ou `local_demo_provisioning`, recusando UUID forjado e motivo vazio) e gravam `operator_type`, `operator_identifier` e detalhes seguros em `audit_events`.
- **Progresso calculado:** `process_progress_v` nunca é armazenada no cliente e retorna `indeterminate`/`NULL` quando não há requisitos obrigatórios aplicáveis (nunca falso `100%`).

## Android e Web

- **Android:** `android/app/src/main/AndroidManifest.xml` declara `android.permission.INTERNET` e o `<intent-filter>` de callback `estagiosempendencia://auth/callback` (`android:scheme="estagiosempendencia"`, `android:host="auth"`, `android:pathPrefix="/callback"`), sincronizado com `SupabaseConfig.androidAuthCallbackUrl`, validação RFC 3986 (`SupabaseConfig.isValidCallbackUri`) e `supabase/config.toml`. Em emulador Android, o host Windows é acessado por `10.0.2.2`. `android.overridePathCheck=true` permanece em `android/gradle.properties` apenas para compatibilidade local com caminho Windows acentuado.
- **Web:** `SupabaseAuth` limpa parâmetros de callback da URL (`clearAuthUrlParameters`) e `AuthGate` substitui a árvore raiz no logout sem reter dados privados na navegação.
