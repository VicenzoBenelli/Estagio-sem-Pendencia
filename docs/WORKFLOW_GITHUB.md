# Workflow Git e GitHub — SGMI-FAST/30

## Fluxo de Branches

`vicenzo (desenvolvimento) -> homolog (integração/validação) -> main (base estável)`

1. O desenvolvimento e os testes dos lotes (ESP-01 a ESP-32) ocorrem na branch `vicenzo`.
2. Antes de qualquer integração, o lote precisa cumprir os **Gates A, B e C** com parecer `PASS` na auditoria independente e evidências reais de testes.
3. Após `Gate C = PASS`, o commit seletivo (em português, sem assinatura de ferramenta de IA) e o push são publicados na branch `vicenzo` e validados pelo GitHub Actions.
4. Confirmada a CI verde na `vicenzo` e verificado que `origin/homolog` é ancestral do commit publicado (fast-forward seguro via `git merge-base`), a atualização para `homolog` é feita por push direto (`git push origin vicenzo:homolog`), **sem `--force`** e **sem abrir Pull Request entre `vicenzo` e `homolog`**.
5. A promoção `homolog -> main` é feita exclusivamente via **Pull Request**, após estabilização e aprovação final.

## Regras e Proteções

- Nunca executar `git push --force`, `git push --force-with-lease`, `git reset --hard` ou `git clean -fd` sem autorização específica.
- Nunca realizar push direto na `main` nem ignorar CI reprovada.
- Arquivos privados locais (como `AGENTS.md` local), segredos, `.env` e artefatos de build nunca devem ser versionados.
- Mensagens de commit seguem o padrão em português: `feat(ESP-XX): ...`, `fix(ESP-XX): ...`, `test(ESP-XX): ...`, `refactor(ESP-XX): ...`.

## Pipeline de CI (`.github/workflows/flutter_ci.yml`)

A cada push ou PR para `homolog`/`main`, dois jobs são executados em `ubuntu-latest`:

- **`quality`:** `flutter pub get`, `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, `flutter test`, `flutter build web` e `flutter build apk --debug`.
- **`supabase_db_and_auth`:** `npm ci`, `npx supabase start`, `npx supabase db reset --yes`, `npx supabase test db` (pgTAP) e `node tool/test_auth_and_rls_http.mjs` (15 cenários reais HTTP/Auth/RLS/Mailpit).
