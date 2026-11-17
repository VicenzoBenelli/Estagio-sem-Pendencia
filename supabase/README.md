# Supabase Local e Migrations — Estágio sem Pendência

O projeto utiliza `supabase@3.2.0` fixada em `package.json` (`npx supabase`) para desenvolvimento local descartável em Docker, sem vínculo com projeto hospedado.

## Estrutura

- `config.toml`: configuração local (`project_id = "estagio-sem-pendencia"`, Auth com `enable_confirmations = true`, `minimum_password_length = 8`, redirect URLs Web locais e `estagiosempendencia://auth/callback` no Android).
- `migrations/`: SQL versionado e reproduzível (`20261116000100_create_domain_tables.sql`, `20261116000200_rls_policies_and_auth_provisioning.sql`, `20261116000300_harden_integrity_immutability_and_admin_audit.sql` e `20261116000400_harden_template_items_version_transitions_and_default_privs.sql`).
- `seed.sql`: catálogo fictício inicial (1 instituição demo, 1 curso demo, 1 modalidade demo, template v1 criado em `draft`, populado com 2 itens obrigatórios + 1 opcional de demonstração e publicado para `published`).
- `tests/`: suíte pgTAP (`00001_domain_rls_and_security_test.sql` com catálogos isolados por execução).

## Comandos Principais

```powershell
npm ci
npx supabase start --yes
npx supabase migration up
npx supabase test db
node tool/test_auth_and_rls_http.mjs
node tool/setup_local_test_users.mjs --ephemeral
```

Para reconstruir uma base local descartável do zero (inclusive verificando `seed.sql`), utilize `npx supabase db reset --yes`. As suítes `npx supabase test db` e `node tool/test_auth_and_rls_http.mjs` também são repetíveis em sequência sem exigir reset.

## Segurança

- Nunca coloque `service_role`, senhas administrativas ou chaves privadas em Flutter/Web.
- Scripts administrativos locais (`tool/setup_local_test_users.mjs` e `tool/test_auth_and_rls_http.mjs`) validam destino loopback (`127.0.0.1`/`localhost`/`10.0.2.2`), mantêm credenciais efêmeras exclusivamente em memória (sem gravação em disco; `--password-out` é recusada) e não imprimem credenciais/tokens em logs/stdout.
- RPCs administrativas (`admin_set_user_role`, `admin_assign_reviewer_scope`, `admin_revoke_reviewer_assignment`) exigem contrato auditável de operador via `_resolve_privileged_operator` (`verified_human_operator`, `technical_automation` ou `local_demo_provisioning`) e motivo obrigatório em `audit_events`.
