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
npx supabase start --yes
```

Para reconstruir o banco local do zero (migrations + seed fictício de demonstração):

```powershell
npx supabase db reset --yes
```

Consulte as URLs e chaves públicas locais com:

```powershell
npx supabase status
```

> Nunca vincule projeto remoto nem aplique migrations hospedadas a partir de ambiente de desenvolvimento sem autorização. Nunca utilize `service_role` ou chaves secretas em Flutter/Web.

## 2. Preparação de Contas Fictícias Locais

O procedimento isolado em `tool/setup_local_test_users.mjs` provisiona os quatro perfis fictícios de teste (`estudante.a@demo.local`, `estudante.b@demo.local`, `revisor.r1@demo.local` com escopo atribuído e `revisor.r2@demo.local` sem atribuição), operando exclusivamente contra `127.0.0.1`/`localhost`:

```powershell
# Com senha definida apenas no ambiente local:
$env:LOCAL_TEST_USER_PASSWORD="SuaSenhaLocalFicticia123"
node tool/setup_local_test_users.mjs

# Ou gerando senha efêmera em memória (sem gravação em disco nem saída em terminal/logs):
node tool/setup_local_test_users.mjs --ephemeral
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

- **Emulador Android:** no emulador, `127.0.0.1` aponta para o próprio emulador; use `10.0.2.2` para alcançar o host Windows/macOS/Linux:

```powershell
flutter run `
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
flutter test
flutter build web
flutter build apk --debug
npx supabase test db
node tool/test_auth_and_rls_http.mjs
```

- **Repetibilidade sem reset:** as suítes `npx supabase test db` (106 asserções pgTAP) e `node tool/test_auth_and_rls_http.mjs` usam catálogos isolados por execução e podem ser repetidas em sequência sem `db reset`.
- **Android Studio local:** abra a pasta raiz Flutter do projeto (não execute `gradle init` na raiz; o projeto Gradle fica em `android/`). Metadados locais de IDE (`.idea/`, `*.iml` e `android/local.properties`) permanecem fora do versionamento.
- **Android/Windows Unicode:** `android/gradle.properties` mantém `android.overridePathCheck=true` para caminhos Windows com acentuação (`Área de Trabalho`).
- **Limitação conhecida do `flutter analyze` em caminho Unicode:** na linha Flutter 3.47.x em caminhos Windows com acentuação, `flutter analyze` pode falhar na comunicação LSP (`FormatException: Unexpected end of input`, [flutter/flutter#191309](https://github.com/flutter/flutter/issues/191309)); nesses casos, valide localmente com `dart analyze` e acompanhe o job de CI no Linux (`ubuntu-latest`).

## 5. Estrutura e Limites Atuais (Lote 1)

- `lib/core/config/`: leitura e validação segura de configuração `--dart-define`.
- `lib/features/auth/`: `AuthGate`, `AuthController`, `AuthGateway`, `SupabaseAuthGateway`, login, cadastro (sempre estudante), confirmação de e-mail, recuperação/redefinição de senha e telas iniciais separadas para Estudante e Revisor.
- `supabase/migrations/` e `supabase/seed.sql`: modelagem de 12 entidades de domínio, view calculada `process_progress_v`, RLS deny-by-default, auditoria append-only e catálogo fictício inicial.
- `supabase/tests/` e `tool/`: testes pgTAP (`npx supabase test db`), suíte HTTP/Auth/RLS de 15 cenários (`tool/test_auth_and_rls_http.mjs`) e preparação de contas fictícias (`tool/setup_local_test_users.mjs`).
- **Fora do escopo do Lote 1:** abertura de processos na UI, checklist interativo, upload/visualização de PDFs e fila de revisão serão entregues nos lotes seguintes.

Fluxo Git e metodologia operacional: consulte [docs/WORKFLOW_GITHUB.md](docs/WORKFLOW_GITHUB.md) e [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
