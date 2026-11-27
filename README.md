# Estágio sem Pendência

MVP acadêmico para organização e acompanhamento documental de estágios curriculares obrigatórios em cursos de tecnologia.

> **Aviso importante:** Esta ferramenta **não concede autorização institucional de estágio**. Curso piloto, documentos obrigatórios e prazos ainda dependem de validação institucional; o catálogo atual usa dados fictícios de demonstração.

## Tecnologias e Versões

- **Flutter / Dart:** CI fixada em Flutter `3.47.3` / Dart `3.13.3` (testado localmente em Flutter `3.47.9` / Dart `3.13.7`), Android/Kotlin e Flutter Web.
- **Supabase CLI local:** `supabase@3.2.0` via `package.json` (`npx supabase`) e Docker Desktop.
- **Cliente Supabase:** `supabase_flutter ^2.18.3`.
- **Banco e Auth:** PostgreSQL 17, RLS deny-by-default, pgTAP e GoTrue com confirmação de e-mail e PKCE.
- **Application ID Android provisório:** `br.com.estagiosempendencia.estagio_sem_pendencia`.

## 1. Setup e Supabase Local

Pré-requisitos: Flutter SDK, Android SDK/Java 17 (para build Android), Node.js 24+, e Docker Desktop em execução.

```powershell
flutter pub get
npm ci
npx supabase start --yes -x studio,imgproxy,logflare,vector,supavisor
```

> **Recuperação do Edge Runtime (`submit-requirement-pdf`):** o container `supabase_edge_runtime_estagio-sem-pendencia` é criado pelo Supabase CLI com `RestartPolicy=no`. Caso o Docker Engine reinicie ou o container encerre durante a inicialização antes de `supabase_db_estagio-sem-pendencia` atingir estado `healthy`, inicie-o explicitamente após o banco estar saudável:
>
> ```powershell
> docker start supabase_edge_runtime_estagio-sem-pendencia
> ```

Para reconstruir o banco local do zero em ambiente descartável (migrations + seed fictício de demonstração):

```powershell
npx supabase db reset --yes
```

Consulte as URLs e chaves públicas locais com:

```powershell
npx supabase status -o env
```

> Nunca vincule projeto remoto nem aplique migrations hospedadas a partir de ambiente de desenvolvimento sem autorização. Nunca utilize `service_role` ou chaves secretas em Flutter/Web.

## 2. Preparação de Contas Fictícias Locais

O procedimento isolado em `tool/setup_local_test_users.mjs` provisiona os quatro perfis fictícios canônicos de teste (`estudante.a@demo.local`, `estudante.b@demo.local`, `revisor.r1@demo.local` com escopo atribuído ao catálogo piloto `INST_DEMO` / `TEC_DEMO` / `ESTAGIO_OBRIG_DEMO` e `revisor.r2@demo.local` sem atribuição), operando exclusivamente contra `127.0.0.1`/`localhost`:

```powershell
# Com senha definida apenas no ambiente local:
$env:LOCAL_TEST_USER_PASSWORD="SuaSenhaLocalFicticia123"
node tool/setup_local_test_users.mjs

# Ou gerando senha efêmera em memória (sem gravação em disco nem saída em terminal/logs):
node tool/setup_local_test_users.mjs --ephemeral

# Autoteste das guardas de segurança do provisionador:
node tool/setup_local_test_users.mjs --self-test
```

Em qualquer modo, as credenciais temporárias são mantidas exclusivamente em memória e nunca são gravadas em disco nem exibidas em stdout/stderr (a opção legada `--password-out` é rejeitada). Para reutilizar uma senha fictícia entre processos locais na mesma sessão, defina `LOCAL_TEST_USER_PASSWORD` no ambiente.

## 3. Como Iniciar a Aplicação (Web e Android)

Passe `SUPABASE_URL` e `SUPABASE_PUBLISHABLE_KEY` via `--dart-define` (use os valores exibidos por `npx supabase status`; veja `.env.example`):

- **Flutter Web (host local):**

```powershell
flutter run -d chrome `
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<PUBLISHABLE_KEY_LOCAL>
```

- **Emulador Android (`Pixel_10a` / AVD):** no emulador, `127.0.0.1` aponta para o próprio emulador; use `10.0.2.2` para alcançar o host Windows/macOS/Linux:

```powershell
flutter run -d emulator-5554 `
  --dart-define=SUPABASE_URL=http://10.0.2.2:54321 `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<PUBLISHABLE_KEY_LOCAL>
```

- **Dispositivo físico Android (USB):** encaminhe a porta local antes de iniciar com `127.0.0.1`:

```powershell
adb reverse tcp:54321 tcp:54321
flutter run `
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<PUBLISHABLE_KEY_LOCAL>
```

E-mails locais (confirmação de cadastro e recuperação de senha) podem ser inspecionados no Mailpit em `http://127.0.0.1:54324`. O retorno PKCE utiliza `http://127.0.0.1:3000` (ou origem atual) na Web e o deep link RFC 3986 `estagiosempendencia://auth/callback` no Android.

## 4. Testes e Qualidade

```powershell
dart format --output=none --set-exit-if-changed .
dart analyze
flutter analyze
flutter test --no-pub -r expanded
flutter test --no-pub -r expanded tool/test_flutter_document_supabase_integration.dart
flutter build web --no-pub
flutter build apk --debug --no-pub
npx supabase test db
node tool/test_auth_and_rls_http.mjs
```

- **Suítes automatizadas:**
  - `flutter test --no-pub -r expanded`: 54 testes de unidade e widget cobrindo autenticação, processos, checklist, submissão de PDF, fila de revisão, visualizador PDF nativo/Web, gateway server-side `download-submission-pdf`, decisão documental, reenvio versionado e linha do tempo.
  - `flutter test --no-pub -r expanded tool/test_flutter_document_supabase_integration.dart`: suíte de integração real dos repositórios e controladores Flutter (`SupabaseProcessRepository`, `SupabaseDocumentRepository`, `SupabaseReviewRepository`, `SupabaseAuthGateway`, `ReviewerController`, `DocumentSubmissionController` e `ProcessTimelineController`) contra o Supabase local em execução (Lotes 3, 4 e Gateway de download privado).
  - `npx supabase test db`: 5 arquivos pgTAP (`00001` a `00005`) totalizando 347 asserções SQL de domínio, RLS, processos/checklists, Storage privado/submissões, fila/decisão/auditoria e gateway server-side `authorize_document_submission_download`.
  - `node tool/test_auth_and_rls_http.mjs`: 20 grupos de cenários HTTP reais cobrindo Auth, RLS, Storage privado deny-by-default, Edge Functions `submit-requirement-pdf` e `download-submission-pdf`, `reviewer_queue_v`, `review_submission` e `process_audit_timeline_v`.
- **Repetibilidade sem reset:** as suítes `npx supabase test db`, `node tool/test_auth_and_rls_http.mjs` e `tool/test_flutter_document_supabase_integration.dart` utilizam escopos ou processos isolados por execução e podem ser repetidas em sequência sem `db reset`.
- **Android Studio local:** abra a pasta raiz Flutter do projeto (não execute `gradle init` na raiz; o projeto Gradle fica em `android/`). Metadados locais de IDE (`.idea/`, `*.iml` e `android/local.properties`) permanecem fora do versionamento.
- **Android/Windows Unicode:** `android/gradle.properties` mantém `android.overridePathCheck=true` para caminhos Windows com acentuação (`Área de Trabalho`).
- **Limitações conhecidas:**
  - *`flutter analyze` em caminho Windows Unicode:* na linha Flutter 3.47.x em caminhos Windows com acentuação, `flutter analyze` pode falhar na comunicação LSP (`FormatException: Unexpected end of input`, [flutter/flutter#191309](https://github.com/flutter/flutter/issues/191309)); valide localmente com `dart analyze` e acompanhe o job de CI no Linux (`ubuntu-latest`).
  - *Container Edge Runtime:* possui `RestartPolicy=no` no Supabase CLI local; se o Docker reiniciar, execute `docker start supabase_edge_runtime_estagio-sem-pendencia` após o banco ficar `healthy`.
  - *Catálogo em volume local sem reset:* execuções repetidas de `node tool/test_auth_and_rls_http.mjs` acumulam cursos fictícios temporários no banco local; o catálogo piloto oficial permanece identificado pelo código `INST_DEMO` / `TEC_DEMO` / `ESTAGIO_OBRIG_DEMO`.

## 5. Estrutura e Fluxo Documental Implementado (Lotes 1 a 4)

- **Autenticação e Perfis (`lib/features/auth/`, Lote 1 — `ESP-01` a `ESP-09`):** `AuthGate`, `AuthController`, `SupabaseAuthGateway`, login, cadastro (sempre com papel inicial `student`), confirmação de e-mail, recuperação/redefinição de senha e roteamento segregado entre áreas de Estudante e Revisor.
- **Processos e Checklist Versionado (`lib/features/processes/`, Lote 2 — `ESP-10` a `ESP-12`, `ESP-16`, `ESP-17`):** abertura atômica de processo via RPC `create_internship_process` com geração automática de `process_requirement_items` a partir do template publicado (`published`), acompanhamento de progresso pela view `process_progress_v` (checklist ausente ou com zero obrigatórios nunca resulta em 100%) e visualização detalhada dos requisitos.
- **Submissão de PDF e Storage Privado (`lib/features/documents/`, Lote 3 — `ESP-13` a `ESP-15`):** seleção e validação estrutural de PDF (`.pdf`, `%PDF-`, `%%EOF`, até 10 MiB), upload autenticado via Edge Function `submit-requirement-pdf` e RPCs `prepare_pdf_submission` / `finalize_pdf_submission` / `abort_pdf_submission` no bucket privado `internship-documents` (`public = false`), com preservação de versões anteriores (`v1`, `v2`, ..., `v(n+1)`).
- **Revisão Documental, Visualização de PDF, Decisão, Reenvio e Histórico (`lib/features/review/`, Lote 4 — `ESP-18` a `ESP-22`):**
  - *Fila do Revisor (`ESP-18`):* consulta paginada e filtrável de `reviewer_queue_v` restrita às submissões vigentes (`is_current = true` e `status = 'under_review'`) dentro do escopo ativo de `reviewer_assignments`.
  - *Visualização Autenticada de PDF (`ESP-19` / `GATE E3-CACHE-FIX`):* download autenticado dos bytes via Edge Function `POST /functions/v1/download-submission-pdf` enviando `{"submission_id": "<uuid>"}` (sem acesso direto do cliente ao Storage, sem URLs públicas nem signed URLs persistidas e com cabeçalhos `Cache-Control: private, no-store, no-cache, must-revalidate`), com renderização real de páginas no Android via `android.graphics.pdf.PdfRenderer` (`MainActivity.kt` em `Dispatchers.IO`) e na Web via `Blob` (`application/pdf`) em `<iframe>` e abertura opcional em nova aba/tela cheia. No encerramento de sessão (`signOut`), troca de documento ou `dispose`, os bytes em memória são zerados, os `blob:` URLs na Web são revogados via `URL.revokeObjectURL` e os arquivos temporários do `PdfRenderer` no Android (`cacheDir/pdf_viewer_temp`) são removidos.
  - *Decisão Documental Atômica (`ESP-20`):* aprovação (`approved`) ou solicitação de correção (`correction_requested`, exigindo justificativa não vazia) exclusivamente via RPC `review_submission`, com bloqueio de versão obsoleta, submissão já decidida ou processo fora de escopo.
  - *Histórico e Auditoria (`ESP-21`):* consulta do histórico de versões por requisito e da linha do tempo auditável via `process_audit_timeline_v`.
  - *Correção e Reenvio Versionado pelo Estudante (`ESP-22`):* exibição do motivo de correção registrado pelo revisor, envio de nova versão `v(n+1)` preservando a versão `v(n)` e sua decisão histórica, retorno automático à fila do revisor e atualização do progresso documental.
- **Distinção semântica obrigatória (`documentally_complete`):** quando todos os requisitos obrigatórios são aprovados (`100%`), o processo assume o status `documentally_complete` (**"Sem pendências documentais"**). A aplicação exibe aviso explícito de que a conclusão documental no sistema **não equivale à autorização institucional ou formalização oficial do estágio** junto à instituição de ensino ou concedente.

Fluxo Git e metodologia operacional: consulte [docs/WORKFLOW_GITHUB.md](docs/WORKFLOW_GITHUB.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) e [docs/FLUTTER_BACKEND_CONTRACT.md](docs/FLUTTER_BACKEND_CONTRACT.md).
