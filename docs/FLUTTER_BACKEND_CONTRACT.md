# Contrato Backend -> Flutter (Lote 4: ESP-18, ESP-19, ESP-20, ESP-21, ESP-22)

Este documento especifica o contrato real implementado nas migrations `20261116000100` a `20261125001000` e nas Edge Functions `submit-requirement-pdf` e `download-submission-pdf` para consumo pelos clientes Flutter (Web do revisor e Android/Web do estudante).

> **Invariante de segurança:** Todas as operações usam exclusivamente sessão JWT autenticada do Supabase (`ANON_KEY`/`PUBLISHABLE_KEY`). Nunca incorporar `service_role` ou credenciais administrativas no Flutter. Toda conclusão documental no MVP (`documentally_complete`) refere-se apenas ao checklist documental e **não equivale à autorização oficial de estágio**.

---

## 1. Fila do Revisor (`public.reviewer_queue_v` — ESP-18)

- **Endpoint PostgREST:** `GET /rest/v1/reviewer_queue_v`
- **Flutter SDK:** `_client.from('reviewer_queue_v').select(..., count: CountOption.exact)`
- **Segurança:** View com `security_invoker = true`, `SELECT` restrito a `authenticated` (bloqueado para `anon`). Retorna apenas linhas que satisfazem cumulativamente:
  1. `internship_processes.status <> 'cancelled'` (nenhum dado de processo cancelado);
  2. `process_requirements.status = 'under_review'` e `current_submission_id IS NOT NULL`;
  3. `document_submissions.id = process_requirements.current_submission_id`, `version = current_version` e `status = 'under_review'` (exclui versões antigas e já decididas);
  4. Ausência de registro em `document_reviews` para `submission_id`;
  5. `public.is_assigned_reviewer(institution_id, course_id, course_modality_id) = true` (exige perfil `active = true`, `role = 'reviewer'` e `reviewer_assignments` ativo e não revogado; estudantes, revisores inativos e revisores sem atribuição no escopo recebem **0 linhas**).

### Colunas expostas

| Coluna | Tipo JSON | Origem / Significado |
| --- | --- | --- |
| `submission_id` | `uuid` | ID da submissão vigente aguardando decisão (enviar em `review_submission`) |
| `process_requirement_id` | `uuid` | ID do requisito do processo |
| `process_id` | `uuid` | ID do processo de estágio |
| `student_id` | `uuid` | ID do estudante dono do processo |
| `student_name` | `text` | Nome de exibição do estudante (`'Estudante'` se ausente; sem e-mail desnecessário) |
| `institution_id`, `institution_code`, `institution_name` | `uuid`, `text?`, `text?` | Instituição do processo (`code`/`name` podem ser `null` se catálogo desativado) |
| `course_id`, `course_code`, `course_name` | `uuid`, `text?`, `text?` | Curso do processo (`code`/`name` podem ser `null` se catálogo desativado) |
| `course_modality_id`, `modality_code`, `modality_name` | `uuid`, `text?`, `text?` | Modalidade do processo (`code`/`name` podem ser `null` se catálogo desativado) |
| `process_status` | `text` | `'in_progress'` ou `'documentally_complete'` (nunca `'cancelled'`) |
| `process_opened_at` | `timestamptz` | Data/hora de abertura do processo (UTC) |
| `template_version` | `integer` | Versão do template do snapshot |
| `requirement_code` | `text` | Código estável do requisito |
| `requirement_title` | `text` | Título do requisito |
| `requirement_display_order` | `integer` | Ordem no checklist |
| `is_required` | `boolean` | Indica se o item compõe o denominador do progresso |
| `requirement_status` | `text` | Sempre `'under_review'` |
| `current_version` | `integer` | Versão vigente (`>= 1`) |
| `is_resubmission` | `boolean` | `true` quando `submission_version > 1` (reenvio após correção) |
| `submission_version` | `integer` | Versão da submissão vigente |
| `submission_status` | `text` | Sempre `'under_review'` |
| `original_filename` | `text?` | Nome sanitizado original do PDF |
| `size_bytes` | `bigint` | Tamanho do PDF em bytes |
| `sha256_checksum` | `text?` | Hash SHA-256 em hexadecimal |
| `storage_bucket` | `text` | `'internship-documents'` |
| `storage_path` | `text` | Caminho opaco por UUIDs no bucket privado |
| `submitted_at` | `timestamptz` | Timestamp UTC da submissão vigente |
| `is_demo` | `boolean` | Flag de catálogo/dados fictícios |

### Filtros suportados

Via operadores nativos do PostgREST / `PostgrestFilterBuilder`:
- Escopo: `institution_id=eq.<uuid>`, `course_id=eq.<uuid>`, `course_modality_id=eq.<uuid>`, `process_id=eq.<uuid>`
- Requisito/Submissão: `requirement_code=eq.<code>`, `is_required=eq.true|false`, `is_resubmission=eq.true|false`
- Busca textual: `or=(student_name.ilike.*termo*,requirement_title.ilike.*termo*,requirement_code.ilike.*termo*,course_name.ilike.*termo*)`

---

## 2. Visualização e Download Autenticado de PDFs (ESP-19 / ESP-13 / GATE E3-CACHE-FIX)

- **Bucket privado:** `internship-documents` (`public = false`, MIME exclusivo `application/pdf`, `storage.objects` *deny-by-default* sem policy `SELECT` direta para `anon`/`authenticated` após a migration `20261125001000_private_pdf_download_gateway.sql`).
- **Canal obrigatório (Gateway Server-Side):** Chamada autenticada à Edge Function `download-submission-pdf` com o JWT da sessão atual:
  - **Endpoint HTTP:** `POST /functions/v1/download-submission-pdf`
  - **Headers:** `Authorization: Bearer <user_jwt>`, `apikey: <SUPABASE_PUBLISHABLE_KEY>`, `Content-Type: application/json`, `Cache-Control: no-store, no-cache, must-revalidate`
  - **Body JSON:** `{"submission_id": "<uuid>"}` (único campo aceito; `bucket` ou `storage_path` fornecidos pelo cliente são rejeitados com `400 unsupported_destination_parameter`)
  - **Resposta de sucesso (`HTTP 200`):** Bytes binários brutos (`Uint8List`) com `Content-Type: application/pdf`, `Cache-Control: private, no-store, no-cache, must-revalidate`, `Pragma: no-cache`, `Expires: 0` e `X-Content-Type-Options: nosniff`.
  - **Flutter SDK (`SupabaseDocumentRepository` e `SupabaseReviewRepository`):** Requisição `http.Request('POST', ...)` via `_client.rest.httpClient` lendo diretamente `streamedResponse.stream.toBytes()` sem decodificação UTF-8 ou JSON sobre o binário PDF.
- **Proibido:**
  - Leitura direta no Storage (`/storage/v1/object/...` ou `/storage/v1/object/authenticated/...`) não é utilizada pelo cliente nem permitida por RLS.
  - `createSignedUrl` (`POST /storage/v1/object/sign/...`) e URLs públicas (`/storage/v1/object/public/...`) são estritamente proibidos.
- **Invariantes para o cliente:**
  - Sempre identificar e exibir `submission_id` e `submission_version` antes de habilitar a decisão (RN3 da ESP-19).
  - Revogação do `reviewer_assignments` ou `logout?scope=global` bloqueia novos downloads imediatamente no servidor (inclusive contra replay idêntico, sem cache CDN de objeto privado).
  - Em logout ou troca de sessão, descartar imediatamente bytes em memória (`wipeBytes()`) e revogar qualquer `blob:` URL na Web.

---

## 3. Decisão Atômica de Revisão (`public.review_submission` — ESP-20)

- **Endpoint PostgREST:** `POST /rest/v1/rpc/review_submission`
- **Flutter SDK:** `await _client.rpc('review_submission', params: ...)`
- **Acesso:** Exclusivo para `authenticated` com `profiles.active = true`, `profiles.role = 'reviewer'` e `is_assigned_reviewer(...) = true` para o processo da submissão.

### Parâmetros

| Parâmetro | Tipo | Obrigatório | Regras |
| --- | --- | --- | --- |
| `p_submission_id` | `uuid` | Sim | Deve apontar para a submissão vigente (`current_submission_id`) em status `'under_review'` |
| `p_decision` | `text` | Sim | Exclusivamente `'approved'` ou `'correction_requested'` |
| `p_reason` | `text?` | Condicional | **Obrigatório** e não vazio após trim (1..2000 caracteres) quando `p_decision = 'correction_requested'`. Opcional/normalizado para `null` quando vazio em `'approved'`. |
| `p_idempotency_key` | `uuid?` | Opcional (recomendado) | UUID v4 gerado por tentativa de ação na UI para permitir retry seguro em timeout/queda de rede sem duplicar revisão ou evento. |

### Garantias transacionais no backend

1. Serializa concorrência por processo e requisito (`pg_advisory_xact_lock` em ordem fixa `process -> requirement` seguida de `FOR UPDATE` em `process_requirements`, `document_submissions` e `internship_processes`).
2. Verifica `auth.uid()`, `profiles.role = 'reviewer'`, `profiles.active = true`, `is_assigned_reviewer(...)` e `internship_processes.status <> 'cancelled'` antes de qualquer transição ou replay idempotente.
3. Impede dupla decisão na mesma submissão (`document_reviews.submission_id UNIQUE`) e bloqueia decisão em versão obsoleta (`current_submission_id <> p_submission_id`).
4. Insere 1 registro imutável em `document_reviews` (validado também por `trg_document_reviews_validate_insert`), atualiza `document_submissions.status` e `process_requirements.status` na mesma transação.
5. Quando `p_decision = 'approved'`, `required_total > 0` e todos os itens obrigatórios (`is_required = true`) estão `'approved'`, atualiza `internship_processes.status` para `'documentally_complete'`. Processos sem itens obrigatórios (`required_total = 0`) **nunca** viram `'documentally_complete'` nem `100%` (permanecem `'in_progress'` / `'indeterminate'`).
6. Registra **evento único** da revisão em `audit_events` (`entity_table = 'document_reviews'`, garantido por índice único `uq_audit_events_single_document_review`) e, quando há transição para `'documentally_complete'`, registra o evento único `process_documentally_completed` com `not_official_internship_authorization: true`.

### Resposta JSON (`200 OK`)

```json
{
  "ok": true,
  "idempotent_replay": false,
  "review": {
    "id": "uuid",
    "process_id": "uuid",
    "process_requirement_id": "uuid",
    "submission_id": "uuid",
    "reviewer_id": "uuid",
    "decision": "approved | correction_requested",
    "reason": "string | null",
    "idempotency_key": "uuid | null",
    "reviewed_at": "timestamptz",
    "created_at": "timestamptz"
  },
  "submission": { "...registro atualizado de document_submissions..." },
  "requirement": { "...registro atualizado de process_requirements..." },
  "process": { "...registro atualizado de internship_processes..." },
  "progress": {
    "process_id": "uuid",
    "owner_id": "uuid",
    "process_status": "in_progress | documentally_complete | cancelled",
    "required_total": 2,
    "required_approved": 1,
    "required_under_review": 0,
    "required_correction_requested": 1,
    "progress_status": "indeterminate | in_progress | documentally_complete",
    "progress_percentage": 50.0
  }
}
```

---

## 4. Tabela de Erros e Tratamento no Flutter

Os erros das RPCs e consultas seguem padrão seguro sem exposição de credenciais, stack traces ou paths internos. Na RPC `review_submission`, o campo `message` de `PostgrestException` inicia com a tag `[ERR:<codigo>]`.

| HTTP Status | SQLSTATE (`code`) | Tag `[ERR:...]` | Causa | Ação esperada no Flutter |
| --- | --- | --- | --- | --- |
| `401` | `PGRST301` | — | JWT ausente, expirado ou sessão revogada | Encerrar estado privado e redirecionar para login |
| `403` | `42501` | `unauthorized_session` | Sessão inválida | Forçar reautenticação |
| `403` | `42501` | `forbidden_role` | Usuário não é `reviewer` ativo | Bloquear operação e manter mensagem neutra |
| `403` | `42501` | `forbidden_scope` | Revisor sem assignment ativo ou assignment revogado | Limpar fila/detalhe fora do escopo e informar perda de acesso |
| `403` | `42501` | `process_cancelled` | Processo cancelado | Atualizar fila/processo e informar que processo está cancelado |
| `400` | `22023` | `invalid_input` | `p_submission_id` ausente/inválido | Validar seleção antes da chamada |
| `400` | `22023` | `invalid_decision` | Decisão diferente de `approved`/`correction_requested` | Erro de validação de formulário |
| `400` | `22023` | `missing_correction_reason` | Solicitação de correção sem justificativa | Exibir erro no campo de motivo mantendo o texto digitado |
| `400` | `22023` | `reason_too_long` | Motivo excede 2000 caracteres | Validar limite de 2000 caracteres na UI |
| `500` (PostgREST RPC) | `P0002` | `submission_not_found` | Submissão inexistente (mapear no Flutter por `PostgrestException.code == 'P0002'`) | Atualizar fila e exibir indisponibilidade |
| `409` | `23505` | `submission_already_reviewed` | Submissão já decidida (inclusive corrida concorrente) | Recarregar fila/histórico e informar que item já foi revisado |
| `409` | `23505` | `obsolete_submission_version` | Submissão não é mais a versão vigente | Recarregar item/fila para exibir a versão mais recente |
| `409` | `23505` | `requirement_status_conflict` | Requisito ou submissão não está em `under_review` | Recarregar fila/processo |
| `409` | `23505` | `idempotency_mismatch` | Mesma `p_idempotency_key` reutilizada com outra submissão/decisão/motivo | Gerar nova chave e recarregar estado |
| Timeout / Rede | — | — | Falha de transporte ambígua | Permitir retry mantendo o **mesmo `p_idempotency_key`** (se já gravado, retorna `200` com `idempotent_replay: true`) |

---

## 5. Paginação Determinística (Fila e Timeline)

Ambas as views (`reviewer_queue_v` e `process_audit_timeline_v`) suportam paginação nativa via PostgREST:

- **Cabeçalho obrigatório para total:** `Prefer: count=exact` (`CountOption.exact` no `supabase_flutter`) -> retorna `Content-Range: <start>-<end>/<total>` (ou `*/0` quando vazio).
- **Tamanho de página sugerido:** `20` itens (`limit=20&offset=0`, `range(page * 20, page * 20 + 19)`), respeitando `max_rows = 1000` do `config.toml`.
- **Ordenação determinística obrigatória (sempre incluir UUID de desempate):**
  - **Fila (`reviewer_queue_v`):** `order=submitted_at.asc,submission_id.asc` (FIFO; ou `submitted_at.desc,submission_id.desc`).
  - **Timeline (`process_audit_timeline_v`):** `order=occurred_at.desc,event_id.desc` (mais recente primeiro; ou `occurred_at.asc,event_id.asc`).
  - **Tabela bruta (`audit_events`):** `order=occurred_at.desc,id.desc`.

---

## 6. Histórico, Revisões e Trilha Imutável (`audit_events` / `process_audit_timeline_v` — ESP-21)

### Histórico documental por requisito (já em `SupabaseDocumentRepository`)
- Submissões: `GET /rest/v1/document_submissions?process_requirement_id=eq.<req_id>&order=version.desc`
- Revisões: `GET /rest/v1/document_reviews?process_requirement_id=eq.<req_id>&order=reviewed_at.desc`

### Timeline imutável por escopo (`process_audit_timeline_v`)
- **Endpoint:** `GET /rest/v1/process_audit_timeline_v?process_id=eq.<process_id>&order=occurred_at.desc,event_id.desc&limit=20&offset=0`
- **Segurança:** View `security_invoker = true` sobre `audit_events` e `internship_processes`.
  - Estudante vê apenas eventos de seus próprios processos (`owner_id = auth.uid()`).
  - Revisor vê apenas eventos de processos dentro de seus `reviewer_assignments` ativos.
  - `actor_display_name` usa `public.get_scoped_actor_display_name(...)` para exibir o nome de quem revisou ou enviou sem expor `profiles.email` ao estudante nem permitir enumeração de perfis.
- **Timezone:** `occurred_at` é persistido em UTC (`timestamptz`). Converter via `DateTime.parse(...).toLocal()` na camada Flutter antes de exibir (RN da ESP-21 T3).
- **Imutabilidade:** `INSERT`/`UPDATE`/`DELETE` diretos em `audit_events` e `document_reviews` são bloqueados por privilégios e triggers `prevent_row_mutation()`.

| Coluna (`process_audit_timeline_v`) | Tipo JSON | Significado |
| --- | --- | --- |
| `event_id` | `uuid` | ID do evento em `audit_events` (tiebreaker de paginação) |
| `process_id` | `uuid` | ID do processo |
| `event_type` | `text` | Tipo do evento (tabela abaixo) |
| `actor_id`, `actor_role`, `actor_display_name` | `uuid?`, `text`, `text` | Autor da transição e nome seguro para exibição |
| `target_user_id` | `uuid?` | Usuário alvo (estudante dono do processo) |
| `entity_table`, `entity_id` | `text`, `uuid` | Entidade primária afetada |
| `process_requirement_id`, `requirement_code`, `requirement_title` | `uuid?`, `text?`, `text?` | Requisito associado ao evento (quando aplicável) |
| `submission_id`, `submission_version` | `uuid?`, `integer?` | Submissão e versão associadas (quando aplicável) |
| `decision`, `reason` | `text?`, `text?` | Decisão e justificativa da revisão (quando aplicável) |
| `process_status` | `text` | Status atual do processo (`in_progress` / `documentally_complete` / `cancelled`) |
| `institution_id`, `course_id`, `course_modality_id` | `uuid` | Escopo do processo (permite filtros do revisor) |
| `occurred_at` | `timestamptz` | Timestamp UTC da ocorrência |
| `metadata` | `jsonb` | Metadados estruturados do evento |

### Tipos de evento esperados na timeline do processo

| `event_type` | `entity_table` | Quando ocorre | Metadados principais |
| --- | --- | --- | --- |
| `process_created` | `internship_processes` | Abertura via `create_internship_process` | `template_version`, `snapshot_item_count`, `required_item_count` |
| `document_submitted` | `document_submissions` | Upload/reenvio confirmado via `submit-requirement-pdf` | `process_requirement_id`, `version`, `is_resubmission`, `size_bytes`, `sha256_checksum` |
| `document_correction_requested` | `document_reviews` | Decisão `'correction_requested'` via `review_submission` | `review_id`, `submission_id`, `requirement_code`, `requirement_title`, `version`, `decision`, `reason` |
| `document_approved` | `document_reviews` | Decisão `'approved'` via `review_submission` | `review_id`, `submission_id`, `requirement_code`, `requirement_title`, `version`, `decision`, `reason`, `process_became_documentally_complete` |
| `process_documentally_completed` | `internship_processes` | Todos os obrigatórios (`required_total > 0`) aprovados | `triggered_by_review_id`, `triggered_by_submission_id`, `required_total`, `required_approved`, `not_official_internship_authorization: true` |

---

## 7. Ciclo Completo de Reenvio Versionado (ESP-22 / ESP-15)

1. **Envio v1:** Estudante chama `POST /functions/v1/submit-requirement-pdf` (`multipart/form-data` com `process_requirement_id`, `idempotency_key` v1 e `file`). Backend grava `v1` (`under_review`), aponta `current_submission_id = v1.id`, `current_version = 1` e emite `document_submitted`.
2. **Entrada na fila:** `v1` passa a constar em `reviewer_queue_v` para revisores ativos do escopo.
3. **Solicitação de correção:** Revisor baixa o PDF autenticado, identifica `v1.id`, chama `review_submission(p_submission_id: v1.id, p_decision: 'correction_requested', p_reason: '...')`. `v1` sai da fila, `v1.status` e `requirement.status` viram `'correction_requested'`, motivo fica registrado em `document_reviews` e `audit_events`.
4. **Reenvio v2:** Estudante lê a justificativa em `document_reviews` ou `process_audit_timeline_v` e envia novo PDF via `POST /functions/v1/submit-requirement-pdf` com **nova** `idempotency_key` v2.
   - Backend preserva integralmente `v1`, seu PDF no Storage e sua `document_reviews`.
   - Cria `v2` (`version = 2`, `status = 'under_review'`, novo `storage_path` opaco) e atualiza `process_requirements` (`current_submission_id = v2.id`, `current_version = 2`, `status = 'under_review'`).
5. **Reentrada na fila:** `v2` aparece em `reviewer_queue_v` com `is_resubmission = true` e `submission_version = 2` (`v1` permanece fora da fila e bloqueada contra nova decisão).
6. **Aprovação e conclusão:** Revisor aprova `v2` via `review_submission(p_submission_id: v2.id, p_decision: 'approved')`. O progresso em `process_progress_v` é recalculado e, se todos os obrigatórios (`> 0`) estiverem aprovados, `internship_processes.status` passa para `'documentally_complete'` (acompanhado do aviso de que não representa autorização oficial).
