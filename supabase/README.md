# Supabase Local e Migrations — Estágio sem Pendência

O projeto utiliza `supabase@3.2.0` fixada em `package.json` (`npx supabase`) para desenvolvimento local descartável em Docker, sem vínculo com projeto hospedado.

## Estrutura

- `config.toml`: configuração local (`project_id = "estagio-sem-pendencia"`, Auth com `enable_confirmations = true`, `minimum_password_length = 8`, redirect URLs Web locais e `estagiosempendencia://auth/callback` no Android, Edge Functions `submit-requirement-pdf` e `download-submission-pdf` com `verify_jwt = false` e validação interna via `/auth/v1/user`).
- `functions/submit-requirement-pdf/index.ts`: Edge Function autenticada de submissão multipart de PDF (`prepare_document_submission` -> validação de bytes `%PDF-`/`%%EOF`/tamanho -> upload no bucket privado `internship-documents` -> `finalize_document_submission`, com compensação segura de órfãos).
- `functions/download-submission-pdf/index.ts`: Edge Function autenticada de download privado server-side (`POST /functions/v1/download-submission-pdf` com `{"submission_id": "<uuid>"}`), que valida sessão GoTrue, avalia RLS com JWT do usuário, autoriza via `public.authorize_document_submission_download`, busca o binário no Storage com `cacheNonce` server-side, revalida autorização antes da entrega (anti-TOCTOU) e responde com `Cache-Control: private, no-store, no-cache, must-revalidate`.
- `migrations/`: SQL versionado e reproduzível dos Lotes 1 a 4 e Gate E3:
  - `20261116000100_create_domain_tables.sql`
  - `20261116000200_rls_policies_and_auth_provisioning.sql`
  - `20261116000300_harden_integrity_immutability_and_admin_audit.sql`
  - `20261116000400_harden_template_items_version_transitions_and_default_privs.sql`
  - `20261117000500_esp10_11_create_internship_process_rpc.sql`
  - `20261117000600_esp13_14_15_private_storage_and_submissions.sql`
  - `20261118000700_esp13_14_15_c3_remediation.sql`
  - `20261119000800_esp18_20_21_review_queue_decision_and_audit.sql`
  - `20261124000900_storage_cloud_authenticated_download.sql`
  - `20261125001000_private_pdf_download_gateway.sql`
- `seed.sql`: catálogo fictício inicial (`INST_DEMO`, `TEC_DEMO`, `ESTAGIO_OBRIG_DEMO`, template v1 criado em `draft`, populado com 2 itens obrigatórios `DEMO_REQ_OBRIG_01` e `DEMO_REQ_OBRIG_02` + 1 opcional `DEMO_REQ_OPC_01` e publicado para `published`).
- `tests/`: suíte pgTAP com 5 arquivos e 347 asserções (`00001_domain_rls_and_security_test.sql` a `00005_storage_cloud_policy_regression_test.sql`, todos com catálogos isolados por execução).

## Comandos Principais

```powershell
npm ci
npx supabase start --yes -x studio,imgproxy,logflare,vector,supavisor
docker start supabase_edge_runtime_estagio-sem-pendencia
npx supabase migration up
npx supabase test db
node tool/test_auth_and_rls_http.mjs
node tool/setup_local_test_users.mjs --ephemeral
flutter test --no-pub -r expanded tool/test_flutter_document_supabase_integration.dart
```

> **Nota sobre o Edge Runtime:** o container `supabase_edge_runtime_estagio-sem-pendencia` possui `RestartPolicy=no`. Sempre que o Docker Desktop reiniciar ou caso `submit-requirement-pdf` retorne `502`/`503`, execute `docker start supabase_edge_runtime_estagio-sem-pendencia` após `supabase_db_estagio-sem-pendencia` estar `healthy`.

Para reconstruir uma base local descartável do zero (inclusive verificando `seed.sql`), utilize `npx supabase db reset --yes`. As suítes `npx supabase test db`, `node tool/test_auth_and_rls_http.mjs` e `tool/test_flutter_document_supabase_integration.dart` são repetíveis em sequência sem exigir reset.

## Segurança e Regras de Domínio

- Nunca coloque `service_role`, senhas administrativas ou chaves privadas em Flutter/Web.
- Scripts administrativos locais (`tool/setup_local_test_users.mjs` e `tool/test_auth_and_rls_http.mjs`) validam destino loopback (`127.0.0.1`/`localhost`/`10.0.2.2`), mantêm credenciais efêmeras exclusivamente em memória (sem gravação em disco; `--password-out` é recusada) e não imprimem credenciais/tokens em logs/stdout.
- RPCs administrativas (`admin_set_user_role`, `admin_assign_reviewer_scope`, `admin_revoke_reviewer_assignment`) exigem contrato auditável de operador via `_resolve_privileged_operator` (`verified_human_operator`, `technical_automation` ou `local_demo_provisioning`) e motivo obrigatório em `audit_events`.
- Decisões documentais são registradas exclusivamente via RPC `review_submission` (`approved` ou `correction_requested` com comentário obrigatório), mantendo versões anteriores (`document_submissions` e `document_reviews`) imutáveis e auditadas em `audit_events` / `process_audit_timeline_v`.
- O status `documentally_complete` indica exclusivamente a conclusão documental dos requisitos obrigatórios no sistema, **não** constituindo autorização institucional oficial do estágio.
