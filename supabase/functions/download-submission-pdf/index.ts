// GATE E3-CACHE-FIX: Gateway server-side autenticado e sem cache para download de PDF privado.
// Substitui o acesso direto do cliente ao Supabase Storage (/storage/v1/object/*),
// eliminando replay por cache de borda CDN após revogação de revisor ou logout global.

const BUCKET_NAME = 'internship-documents';
const DEFAULT_MAX_PDF_BYTES = 5 * 1024 * 1024; // 5 MiB (alinhado ao bucket)
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const FORBIDDEN_CLIENT_DESTINATION_KEYS = [
  'bucket',
  'bucket_id',
  'bucketId',
  'storage_bucket',
  'storageBucket',
  'storage_path',
  'storagePath',
  'path',
  'object_name',
  'objectName',
  'object_path',
  'objectPath',
  'file_path',
  'filePath',
  'url',
] as const;

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, cache-control, pragma',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Expose-Headers':
    'content-type, content-length, cache-control, pragma, expires, x-content-type-options',
  'Vary': 'Origin, Authorization',
};

const NO_CACHE_SECURITY_HEADERS: Record<string, string> = {
  'Cache-Control': 'private, no-store, no-cache, must-revalidate',
  'CDN-Cache-Control': 'no-store',
  'Pragma': 'no-cache',
  'Expires': '0',
  'X-Content-Type-Options': 'nosniff',
};

interface JsonErrorBody {
  ok: false;
  error: {
    code: string;
    message: string;
  };
}

interface AuthorizedSubmissionMetadata {
  submission_id: string;
  process_id: string;
  process_requirement_id: string;
  version: number;
  storage_bucket: string;
  storage_path: string;
  original_filename: string | null;
  mime_type: string;
  size_bytes: number;
  sha256_checksum: string | null;
  access_role: 'owner' | 'reviewer';
}

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS_HEADERS,
      ...NO_CACHE_SECURITY_HEADERS,
      'Content-Type': 'application/json; charset=utf-8',
    },
  });
}

function errorResponse(status: number, code: string, message: string): Response {
  const payload: JsonErrorBody = {
    ok: false,
    error: { code, message },
  };
  return jsonResponse(status, payload as unknown as Record<string, unknown>);
}

function getMaxPdfBytes(): number {
  const raw = Deno.env.get('PDF_MAX_SIZE_BYTES');
  if (!raw) return DEFAULT_MAX_PDF_BYTES;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return DEFAULT_MAX_PDF_BYTES;
  }
  return parsed;
}

function extractBearerToken(req: Request): string | null {
  const authHeader = req.headers.get('authorization') ?? req.headers.get('Authorization');
  if (!authHeader) return null;
  const match = /^Bearer\s+(.+)$/i.exec(authHeader.trim());
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

function encodeStorageObjectPath(storagePath: string): string {
  return storagePath
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
}

function startsWithPdfMagic(bytes: Uint8Array): boolean {
  // %PDF-
  return (
    bytes.byteLength >= 5 &&
    bytes[0] === 0x25 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x44 &&
    bytes[3] === 0x46 &&
    bytes[4] === 0x2d
  );
}

function parseRpcError(payload: unknown): { code: string; message: string } {
  const rawMessage =
    typeof payload === 'object' && payload !== null && 'message' in payload
      ? String((payload as { message?: unknown }).message ?? '')
      : '';

  const tagMatch = /^\[ERR:([a-z0-9_]+)\]\s*(.*)$/i.exec(rawMessage);
  if (tagMatch) {
    return {
      code: tagMatch[1],
      message: tagMatch[2] || 'Erro ao autorizar download documental.',
    };
  }

  const pgCode =
    typeof payload === 'object' && payload !== null && 'code' in payload
      ? String((payload as { code?: unknown }).code ?? '')
      : '';

  return {
    code: pgCode || 'download_authorization_error',
    message: 'Não foi possível autorizar o download documental.',
  };
}

function mapAuthorizationErrorResponse(code: string): Response {
  switch (code) {
    case 'invalid_input':
      return errorResponse(400, 'invalid_submission_id', 'Identificador submission_id inválido.');
    case 'forbidden_inactive_profile':
      return errorResponse(403, 'forbidden_inactive_profile', 'Perfil ausente ou inativo.');
    case 'unauthorized_backend_caller':
      return errorResponse(500, 'backend_authorization_error', 'Falha interna de autorização.');
    case 'file_too_large':
      return errorResponse(413, 'file_too_large', 'Documento excede o limite máximo de tamanho.');
    case 'submission_not_found':
    case 'storage_object_missing':
    case 'storage_mime_mismatch':
    case 'storage_size_mismatch':
      // Resposta 404 uniforme para evitar enumeração ou vazamento de documentos alheios.
      return errorResponse(
        404,
        'submission_not_found',
        'Submissão documental não encontrada ou acesso indisponível.',
      );
    default:
      return errorResponse(500, 'download_authorization_error', 'Falha ao autorizar download.');
  }
}

async function verifyAuthenticatedUser(
  supabaseUrl: string,
  anonKey: string,
  bearerToken: string,
): Promise<{ ok: true; userId: string } | { ok: false; status: number; code: string; message: string }> {
  let res: Response;
  try {
    res = await fetch(`${supabaseUrl}/auth/v1/user`, {
      method: 'GET',
      headers: {
        apikey: anonKey,
        Authorization: `Bearer ${bearerToken}`,
      },
    });
  } catch {
    return {
      ok: false,
      status: 502,
      code: 'auth_service_unavailable',
      message: 'Falha ao validar sessão de autenticação.',
    };
  }

  if (!res.ok) {
    await res.body?.cancel();
    return {
      ok: false,
      status: 401,
      code: 'invalid_or_expired_session',
      message: 'Sessão ausente, inválida ou expirada.',
    };
  }

  const user = (await res.json().catch(() => null)) as { id?: unknown } | null;
  if (typeof user?.id !== 'string' || !UUID_REGEX.test(user.id)) {
    return {
      ok: false,
      status: 401,
      code: 'invalid_user_identity',
      message: 'Identidade autenticada inválida.',
    };
  }

  return { ok: true, userId: user.id };
}

async function queryPostgrestAsUser<T>(
  supabaseUrl: string,
  anonKey: string,
  bearerToken: string,
  relativePathAndQuery: string,
): Promise<{ ok: true; rows: T[] } | { ok: false; status: number; code: string; message: string }> {
  let res: Response;
  try {
    res = await fetch(`${supabaseUrl}/rest/v1/${relativePathAndQuery}`, {
      method: 'GET',
      headers: {
        apikey: anonKey,
        Authorization: `Bearer ${bearerToken}`,
        Accept: 'application/json',
      },
    });
  } catch {
    return {
      ok: false,
      status: 502,
      code: 'database_unavailable',
      message: 'Falha ao consultar autorização no banco de dados.',
    };
  }

  if (res.status === 401) {
    await res.body?.cancel();
    return {
      ok: false,
      status: 401,
      code: 'invalid_or_expired_session',
      message: 'Sessão ausente, inválida ou expirada.',
    };
  }

  if (!res.ok) {
    await res.body?.cancel();
    return {
      ok: false,
      status: 500,
      code: 'rls_query_failed',
      message: 'Erro ao verificar permissão documental.',
    };
  }

  const parsed = await res.json().catch(() => null);
  if (!Array.isArray(parsed)) {
    return {
      ok: false,
      status: 500,
      code: 'rls_query_failed',
      message: 'Resposta inesperada ao verificar permissão documental.',
    };
  }

  return { ok: true, rows: parsed as T[] };
}

async function callBackendRpc<T>(
  supabaseUrl: string,
  serviceRoleKey: string,
  rpcName: string,
  params: Record<string, unknown>,
): Promise<{ ok: true; data: T } | { ok: false; error: { code: string; message: string } }> {
  let res: Response;
  try {
    res = await fetch(`${supabaseUrl}/rest/v1/rpc/${rpcName}`, {
      method: 'POST',
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify(params),
    });
  } catch {
    return {
      ok: false,
      error: {
        code: 'database_unavailable',
        message: 'Falha ao acionar validação no banco de dados.',
      },
    };
  }

  const text = await res.text();
  let parsed: unknown = null;
  if (text.length > 0) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = { message: text };
    }
  }

  if (!res.ok) {
    return {
      ok: false,
      error: parseRpcError(parsed),
    };
  }

  return {
    ok: true,
    data: parsed as T,
  };
}

async function fetchPdfFromPrivateStorage(
  supabaseUrl: string,
  serviceRoleKey: string,
  bucket: string,
  storagePath: string,
  maxPdfBytes: number,
): Promise<
  | { ok: true; bytes: Uint8Array }
  | { ok: false; status: number; code: string; message: string }
> {
  const encodedPath = encodeStorageObjectPath(storagePath);
  const cacheNonce = crypto.randomUUID();
  const url =
    `${supabaseUrl}/storage/v1/object/${encodeURIComponent(bucket)}/${encodedPath}` +
    `?cacheNonce=${encodeURIComponent(cacheNonce)}`;

  let res: Response;
  try {
    res = await fetch(url, {
      method: 'GET',
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        'Cache-Control': 'no-store',
      },
    });
  } catch {
    return {
      ok: false,
      status: 502,
      code: 'storage_unavailable',
      message: 'Falha ao obter o arquivo PDF no repositório privado.',
    };
  }

  if (!res.ok) {
    await res.body?.cancel();
    if (res.status === 404 || res.status === 400) {
      return {
        ok: false,
        status: 404,
        code: 'submission_not_found',
        message: 'Submissão documental não encontrada ou acesso indisponível.',
      };
    }
    return {
      ok: false,
      status: 502,
      code: 'storage_fetch_failed',
      message: 'Falha ao recuperar o documento PDF privado.',
    };
  }

  const contentLengthHeader = res.headers.get('content-length');
  if (contentLengthHeader) {
    const declaredLength = Number.parseInt(contentLengthHeader, 10);
    if (Number.isFinite(declaredLength) && declaredLength > maxPdfBytes) {
      await res.body?.cancel();
      return {
        ok: false,
        status: 413,
        code: 'file_too_large',
        message: 'Documento excede o limite máximo de tamanho.',
      };
    }
  }

  let buffer: ArrayBuffer;
  try {
    buffer = await res.arrayBuffer();
  } catch {
    return {
      ok: false,
      status: 502,
      code: 'storage_read_failed',
      message: 'Falha ao ler conteúdo do documento PDF.',
    };
  }

  const bytes = new Uint8Array(buffer);
  if (bytes.byteLength === 0) {
    return {
      ok: false,
      status: 404,
      code: 'submission_not_found',
      message: 'Submissão documental não encontrada ou acesso indisponível.',
    };
  }

  if (bytes.byteLength > maxPdfBytes) {
    return {
      ok: false,
      status: 413,
      code: 'file_too_large',
      message: 'Documento excede o limite máximo de tamanho.',
    };
  }

  if (!startsWithPdfMagic(bytes)) {
    return {
      ok: false,
      status: 502,
      code: 'invalid_stored_pdf',
      message: 'Arquivo armazenado não possui assinatura PDF válida.',
    };
  }

  return { ok: true, bytes };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') {
    return errorResponse(405, 'method_not_allowed', 'Método HTTP não permitido.');
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return errorResponse(500, 'server_configuration_error', 'Configuração do servidor incompleta.');
  }

  // 1. Autenticação obrigatória via GoTrue (/auth/v1/user rejeita JWT ausente, inválido, expirado ou após logout global)
  const bearerToken = extractBearerToken(req);
  if (!bearerToken) {
    return errorResponse(401, 'missing_authorization', 'Token de autenticação obrigatório.');
  }

  const authCheck = await verifyAuthenticatedUser(supabaseUrl, anonKey, bearerToken);
  if (!authCheck.ok) {
    return errorResponse(authCheck.status, authCheck.code, authCheck.message);
  }
  const actorId = authCheck.userId;

  // 2. Validação estrita do JSON de entrada (proíbe bucket ou storage_path fornecidos pelo cliente)
  const contentType = (req.headers.get('content-type') ?? '').toLowerCase();
  if (!contentType.includes('application/json')) {
    return errorResponse(
      415,
      'invalid_content_type',
      'Envie a requisição utilizando Content-Type: application/json.',
    );
  }

  let parsedBody: unknown;
  try {
    parsedBody = await req.json();
  } catch {
    return errorResponse(400, 'invalid_json_payload', 'Corpo JSON inválido ou ausente.');
  }

  if (typeof parsedBody !== 'object' || parsedBody === null || Array.isArray(parsedBody)) {
    return errorResponse(400, 'invalid_json_payload', 'O payload deve ser um objeto JSON.');
  }

  const bodyRecord = parsedBody as Record<string, unknown>;
  for (const forbiddenKey of FORBIDDEN_CLIENT_DESTINATION_KEYS) {
    if (Object.prototype.hasOwnProperty.call(bodyRecord, forbiddenKey)) {
      return errorResponse(
        400,
        'unsupported_destination_parameter',
        'Parâmetros de bucket ou storage_path não são aceitos pelo servidor.',
      );
    }
  }

  const unexpectedKeys = Object.keys(bodyRecord).filter((key) => key !== 'submission_id');
  if (unexpectedKeys.length > 0) {
    return errorResponse(
      400,
      'unexpected_request_parameter',
      'Parâmetro de requisição não suportado.',
    );
  }

  const rawSubmissionId = bodyRecord.submission_id;
  if (typeof rawSubmissionId !== 'string' || !UUID_REGEX.test(rawSubmissionId.trim())) {
    return errorResponse(
      400,
      'invalid_submission_id',
      'Identificador submission_id inválido ou ausente.',
    );
  }
  const submissionId = rawSubmissionId.trim().toLowerCase();
  const maxPdfBytes = getMaxPdfBytes();

  // 3. Avaliação real de RLS com o JWT do próprio usuário antes de consultar service_role
  // Verifica perfil ativo do próprio usuário primeiro para evitar qualquer vazamento sobre terceiros.
  const ownProfileQuery = await queryPostgrestAsUser<{ id: string; active: boolean }>(
    supabaseUrl,
    anonKey,
    bearerToken,
    `profiles?id=eq.${encodeURIComponent(actorId)}&select=id,active`,
  );
  if (!ownProfileQuery.ok) {
    return errorResponse(ownProfileQuery.status, ownProfileQuery.code, ownProfileQuery.message);
  }
  if (ownProfileQuery.rows.length !== 1 || ownProfileQuery.rows[0].active !== true) {
    return errorResponse(403, 'forbidden_inactive_profile', 'Perfil ausente ou inativo.');
  }

  const rlsSubmissionQuery = await queryPostgrestAsUser<{ id: string }>(
    supabaseUrl,
    anonKey,
    bearerToken,
    `document_submissions?id=eq.${encodeURIComponent(submissionId)}&select=id`,
  );
  if (!rlsSubmissionQuery.ok) {
    return errorResponse(
      rlsSubmissionQuery.status,
      rlsSubmissionQuery.code,
      rlsSubmissionQuery.message,
    );
  }
  if (rlsSubmissionQuery.rows.length !== 1) {
    return errorResponse(
      404,
      'submission_not_found',
      'Submissão documental não encontrada ou acesso indisponível.',
    );
  }

  // 4. Autorização autoritativa no banco via service_role (equivalência completa + objeto Storage ativo)
  const authRpc = await callBackendRpc<AuthorizedSubmissionMetadata>(
    supabaseUrl,
    serviceRoleKey,
    'authorize_document_submission_download',
    {
      p_actor_id: actorId,
      p_submission_id: submissionId,
      p_max_size_bytes: maxPdfBytes,
    },
  );
  if (!authRpc.ok) {
    return mapAuthorizationErrorResponse(authRpc.error.code);
  }

  const authorized = authRpc.data;
  if (
    !authorized ||
    authorized.storage_bucket !== BUCKET_NAME ||
    typeof authorized.storage_path !== 'string' ||
    authorized.storage_path.trim().length === 0 ||
    authorized.storage_path.includes('..') ||
    authorized.storage_path.startsWith('/')
  ) {
    return errorResponse(
      404,
      'submission_not_found',
      'Submissão documental não encontrada ou acesso indisponível.',
    );
  }

  // 5. Busca binária privilegiada no Storage privado com cacheNonce exclusivo do servidor
  const storageFetch = await fetchPdfFromPrivateStorage(
    supabaseUrl,
    serviceRoleKey,
    authorized.storage_bucket,
    authorized.storage_path,
    maxPdfBytes,
  );
  if (!storageFetch.ok) {
    return errorResponse(storageFetch.status, storageFetch.code, storageFetch.message);
  }

  if (
    typeof authorized.size_bytes === 'number' &&
    storageFetch.bytes.byteLength !== authorized.size_bytes
  ) {
    return errorResponse(
      502,
      'storage_size_mismatch',
      'Tamanho do documento obtido diverge dos metadados autorizados.',
    );
  }

  // 6. Revalidação pré-entrega (anti-TOCTOU): garante que sessão e vínculo continuam válidos no instante da entrega
  const [postAuthCheck, postRpcCheck] = await Promise.all([
    verifyAuthenticatedUser(supabaseUrl, anonKey, bearerToken),
    callBackendRpc<AuthorizedSubmissionMetadata>(
      supabaseUrl,
      serviceRoleKey,
      'authorize_document_submission_download',
      {
        p_actor_id: actorId,
        p_submission_id: submissionId,
        p_max_size_bytes: maxPdfBytes,
      },
    ),
  ]);

  if (!postAuthCheck.ok) {
    return errorResponse(postAuthCheck.status, postAuthCheck.code, postAuthCheck.message);
  }
  if (!postRpcCheck.ok) {
    return mapAuthorizationErrorResponse(postRpcCheck.error.code);
  }

  return new Response(storageFetch.bytes as unknown as BodyInit, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      ...NO_CACHE_SECURITY_HEADERS,
      'Content-Type': 'application/pdf',
      'Content-Length': String(storageFetch.bytes.byteLength),
      'Content-Disposition': 'inline',
    },
  });
});
