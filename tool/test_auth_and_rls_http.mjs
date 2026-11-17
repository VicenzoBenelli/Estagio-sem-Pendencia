#!/usr/bin/env node
/**
 * Suite real de testes HTTP (GoTrue + PostgREST + Mailpit) contra Supabase local.
 * Cobre integralmente os 15 cenários obrigatórios, PKCE com callback Android,
 * contrato auditável de operador administrativo, repetibilidade sem reset e
 * sanitização estrita de credenciais/tokens em logs e erros.
 */

import assert from 'node:assert/strict';
import { execSync } from 'node:child_process';
import crypto from 'node:crypto';

const DEMO_INSTITUTION_ID = '10000000-0000-4000-8000-000000000001';
const ANDROID_CALLBACK_URL = 'estagiosempendencia://auth/callback';
const OPERATOR_TYPE = 'technical_automation';
const OPERATOR_IDENTIFIER = 'tool/test_auth_and_rls_http.mjs';

function sanitizeUrlForLog(rawUrl) {
  try {
    const parsed = new URL(rawUrl);
    return `${parsed.protocol}//${parsed.host}${parsed.pathname}`;
  } catch {
    return '[url-redacted]';
  }
}

function sanitizeHttpSummary(res) {
  const code = res.data?.error_code ?? res.data?.code ?? res.data?.error ?? null;
  const msg = res.data?.msg ?? res.data?.message ?? null;
  return `HTTP ${res.status}${code ? ` code=${code}` : ''}${msg ? ` msg=${String(msg).slice(0, 120)}` : ''}`;
}

function redactKnownSecrets(text, secrets) {
  let out = String(text ?? '');
  for (const secret of secrets) {
    if (secret && secret.length >= 6) {
      out = out.split(secret).join('[REDACTED]');
    }
  }
  out = out.replace(/([?#&](?:code|token|token_hash|access_token|refresh_token)=)[^&\s"']+/gi, '$1[REDACTED]');
  out = out.replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, '[JWT_REDACTED]');
  return out;
}

function verifyControlledFailureRedaction() {
  const fakePassword = 'FakePassword!987654';
  const fakeJwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signaturepart12345';
  const fakeRecoveryUrl = `${ANDROID_CALLBACK_URL}?code=secret-pkce-code-999#access_token=${fakeJwt}&refresh_token=refresh999`;
  const rawFailure = `Falha simulada com pass=${fakePassword} url=${fakeRecoveryUrl}`;

  const safeUrl = sanitizeUrlForLog(fakeRecoveryUrl);
  assert.equal(safeUrl, ANDROID_CALLBACK_URL);
  assert.equal(safeUrl.includes('secret-pkce-code-999'), false);
  assert.equal(safeUrl.includes(fakeJwt), false);

  const redacted = redactKnownSecrets(rawFailure, [fakePassword, fakeJwt]);
  assert.equal(redacted.includes(fakePassword), false);
  assert.equal(redacted.includes(fakeJwt), false);
  assert.equal(redacted.includes('secret-pkce-code-999'), false);
  assert.equal(redacted.includes('refresh999'), false);
}

function createPkcePair() {
  const verifier = crypto.randomBytes(32).toString('base64url');
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

function getLocalSupabaseEnv() {
  const raw = execSync('npx supabase status -o json', {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const jsonStart = raw.indexOf('{');
  if (jsonStart === -1) {
    throw new Error('Não foi possível ler JSON de `npx supabase status -o json`.');
  }
  const parsed = JSON.parse(raw.slice(jsonStart));
  const apiUrl = (parsed.API_URL ?? '').replace(/\/$/, '');
  const mailpitUrl = (parsed.MAILPIT_URL ?? '').replace(/\/$/, '');
  const anonKey = parsed.ANON_KEY;
  const publishableKey = parsed.PUBLISHABLE_KEY;
  const serviceRoleKey = parsed.SERVICE_ROLE_KEY;

  assert.ok(apiUrl && mailpitUrl && anonKey && serviceRoleKey, 'Config local do Supabase incompleta');
  const host = new URL(apiUrl).hostname;
  assert.ok(
    host === '127.0.0.1' || host === 'localhost',
    `Suite HTTP recusada para host não local: ${host}`,
  );
  return { apiUrl, mailpitUrl, anonKey, publishableKey, serviceRoleKey };
}

async function httpJson(url, { method = 'GET', headers = {}, body } = {}) {
  const response = await fetch(url, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: response.status, ok: response.ok, headers: response.headers, data: json };
}

async function findMailpitMessageForEmail(mailpitUrl, recipientEmail, subjectHint) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const res = await httpJson(
      `${mailpitUrl}/api/v1/search?query=${encodeURIComponent(`to:${recipientEmail}`)}&limit=20`,
    );
    const messages = res.ok && Array.isArray(res.data?.messages) ? res.data.messages : [];
    const match = messages.find((msg) => {
      const toMatch = (msg.To ?? []).some(
        (addr) => (addr.Address ?? '').toLowerCase() === recipientEmail.toLowerCase(),
      );
      const subjectMatch =
        !subjectHint || (msg.Subject ?? '').toLowerCase().includes(subjectHint.toLowerCase());
      return toMatch && subjectMatch;
    });
    if (match) {
      const detail = await httpJson(`${mailpitUrl}/api/v1/message/${match.ID}`);
      if (detail.ok && detail.data) return detail.data;
    }
    await new Promise((r) => setTimeout(r, 400));
  }
  throw new Error(`E-mail esperado não localizado no Mailpit para destinatário da execução.`);
}

function extractAuthVerifyUrlFromMessage(message) {
  const content = `${message.HTML ?? ''}\n${message.Text ?? ''}`;
  const urls = content.match(/https?:\/\/[^\s"'<>]+/g) ?? [];
  const verifyUrl = urls.find((u) => u.includes('/auth/v1/verify'));
  assert.ok(verifyUrl, 'Link de verificação GoTrue ausente no corpo do e-mail do Mailpit.');
  return verifyUrl.replace(/&amp;/g, '&');
}

async function followVerifyLink(verifyUrl) {
  const res = await fetch(verifyUrl, { redirect: 'manual' });
  const location = res.headers.get('location') ?? '';
  assert.ok(
    res.status >= 300 && res.status < 400 && location,
    `Esperado redirect do endpoint verify; recebido HTTP ${res.status} (${sanitizeUrlForLog(location)})`,
  );
  const parsed = new URL(location);
  const hashParams = new URLSearchParams(parsed.hash.startsWith('#') ? parsed.hash.slice(1) : parsed.hash);
  const queryParams = parsed.searchParams;
  return {
    schemeAndPath: sanitizeUrlForLog(location),
    accessToken: hashParams.get('access_token') ?? queryParams.get('access_token'),
    refreshToken: hashParams.get('refresh_token') ?? queryParams.get('refresh_token'),
    type: hashParams.get('type') ?? queryParams.get('type'),
    code: queryParams.get('code'),
    error: hashParams.get('error') ?? queryParams.get('error'),
  };
}

async function createIsolatedCatalog(apiUrl, serviceHeaders, suffix, withRequiredItem) {
  const course = await httpJson(`${apiUrl}/rest/v1/courses`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      institution_id: DEMO_INSTITUTION_ID,
      code: `HTTP_COURSE_${suffix}`,
      name: `Curso Teste HTTP (${suffix})`,
      is_demo: true,
      active: true,
    },
  });
  assert.equal(course.status, 201, `Erro criando curso isolado: ${sanitizeHttpSummary(course)}`);
  const courseId = course.data[0].id;

  const modality = await httpJson(`${apiUrl}/rest/v1/course_modalities`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      course_id: courseId,
      code: `HTTP_MOD_${suffix}`,
      name: `Modalidade Teste HTTP (${suffix})`,
      is_mandatory: true,
      is_demo: true,
      active: true,
    },
  });
  assert.equal(modality.status, 201, `Erro criando modalidade isolada: ${sanitizeHttpSummary(modality)}`);
  const modalityId = modality.data[0].id;

  const templateDraft = await httpJson(`${apiUrl}/rest/v1/requirement_templates`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      institution_id: DEMO_INSTITUTION_ID,
      course_id: courseId,
      course_modality_id: modalityId,
      version: 1,
      title: `Template Isolado HTTP (${suffix})`,
      source_reference: 'Dados fictícios automatizados para teste isolado',
      status: 'draft',
      is_demo: true,
    },
  });
  assert.equal(templateDraft.status, 201, `Erro criando template draft: ${sanitizeHttpSummary(templateDraft)}`);
  const templateId = templateDraft.data[0].id;

  const item = await httpJson(`${apiUrl}/rest/v1/requirement_template_items`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      template_id: templateId,
      code: `ITEM_${suffix}`,
      title: `[Demonstração] Item ${suffix}`,
      description: 'Item fictício para teste HTTP isolado',
      acceptance_criteria: 'Critério fictício',
      is_required: withRequiredItem,
      display_order: 1,
      is_demo: true,
    },
  });
  assert.equal(item.status, 201, `Erro criando item template: ${sanitizeHttpSummary(item)}`);

  const publishTemplate = await httpJson(
    `${apiUrl}/rest/v1/requirement_templates?id=eq.${templateId}`,
    {
      method: 'PATCH',
      headers: serviceHeaders,
      body: { status: 'published' },
    },
  );
  assert.equal(publishTemplate.ok, true, `Erro publicando template: ${sanitizeHttpSummary(publishTemplate)}`);

  return {
    courseId,
    modalityId,
    templateId,
    itemId: item.data[0].id,
    itemCode: item.data[0].code,
  };
}

async function main() {
  const env = getLocalSupabaseEnv();
  const runId = `${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;
  const passA = `DemoA!${crypto.randomBytes(8).toString('hex')}`;
  const passB = `DemoB!${crypto.randomBytes(8).toString('hex')}`;
  const newPassB = `DemoB2!${crypto.randomBytes(8).toString('hex')}`;
  const passR1 = `DemoR1!${crypto.randomBytes(8).toString('hex')}`;
  const passR2 = `DemoR2!${crypto.randomBytes(8).toString('hex')}`;
  const passPkce = `DemoP!${crypto.randomBytes(8).toString('hex')}`;

  const sensitivePool = [
    passA,
    passB,
    newPassB,
    passR1,
    passR2,
    passPkce,
    env.serviceRoleKey,
    env.anonKey,
    env.publishableKey,
  ];

  const emailA = `estudante.a.${runId}@demo.local`;
  const emailB = `estudante.b.${runId}@demo.local`;
  const emailR1 = `revisor.r1.${runId}@demo.local`;
  const emailR2 = `revisor.r2.${runId}@demo.local`;
  const emailPkce = `android.pkce.${runId}@demo.local`;

  const clientHeaders = (jwt) => ({
    apikey: env.publishableKey ?? env.anonKey,
    ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}),
  });

  const serviceHeaders = {
    apikey: env.serviceRoleKey,
    Authorization: `Bearer ${env.serviceRoleKey}`,
  };

  try {
    verifyControlledFailureRedaction();
    console.log(`[HTTP-TEST] Executando suite em ${env.apiUrl} (run=${runId})`);

    // C1-01: Validar callback Android real (estagiosempendencia://auth/callback) com fluxo PKCE no GoTrue
    const signupPkcePair = createPkcePair();
    const signupAndroid = await httpJson(
      `${env.apiUrl}/auth/v1/signup?redirect_to=${encodeURIComponent(ANDROID_CALLBACK_URL)}`,
      {
        method: 'POST',
        headers: clientHeaders(env.anonKey),
        body: {
          email: emailPkce,
          password: passPkce,
          data: { full_name: 'Android Callback Demo' },
          code_challenge: signupPkcePair.challenge,
          code_challenge_method: 's256',
        },
      },
    );
    assert.equal(signupAndroid.status, 200, `Signup PKCE Android falhou: ${sanitizeHttpSummary(signupAndroid)}`);
    const androidMail = await findMailpitMessageForEmail(env.mailpitUrl, emailPkce, 'Confirm');
    const androidVerify = await followVerifyLink(extractAuthVerifyUrlFromMessage(androidMail));
    assert.equal(
      androidVerify.schemeAndPath,
      ANDROID_CALLBACK_URL,
      `Redirect Android devia usar ${ANDROID_CALLBACK_URL}, recebeu ${androidVerify.schemeAndPath}`,
    );
    assert.ok(androidVerify.code, 'Callback PKCE Android deve retornar code');

    const pkceExchange = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=pkce`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: {
        auth_code: androidVerify.code,
        code_verifier: signupPkcePair.verifier,
      },
    });
    assert.equal(pkceExchange.status, 200, `Troca PKCE falhou: ${sanitizeHttpSummary(pkceExchange)}`);
    assert.ok(pkceExchange.data?.access_token, 'Troca PKCE deve emitir sessão');

    // Validar também recuperação de senha redirecionando para estagiosempendencia://auth/callback
    const recoverPkcePair = createPkcePair();
    const recoverAndroid = await httpJson(
      `${env.apiUrl}/auth/v1/recover?redirect_to=${encodeURIComponent(ANDROID_CALLBACK_URL)}`,
      {
        method: 'POST',
        headers: clientHeaders(env.anonKey),
        body: {
          email: emailPkce,
          code_challenge: recoverPkcePair.challenge,
          code_challenge_method: 's256',
        },
      },
    );
    assert.equal(recoverAndroid.status, 200, `Recover Android falhou: ${sanitizeHttpSummary(recoverAndroid)}`);
    const recoverAndroidMail = await findMailpitMessageForEmail(env.mailpitUrl, emailPkce, 'Reset');
    const recoverAndroidVerify = await followVerifyLink(
      extractAuthVerifyUrlFromMessage(recoverAndroidMail),
    );
    assert.equal(recoverAndroidVerify.schemeAndPath, ANDROID_CALLBACK_URL);
    assert.ok(recoverAndroidVerify.code, 'Recover PKCE Android deve retornar code');
    console.log('✓ C1-01: Callback Android estagiosempendencia://auth/callback + PKCE reais validados');

    // Cenário 1 + 13: Cadastro público de Estudante A, bloqueio antes da confirmação e confirmação via Mailpit
    const signupA = await httpJson(`${env.apiUrl}/auth/v1/signup`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: {
        email: emailA,
        password: passA,
        data: { full_name: 'Estudante A HTTP' },
      },
    });
    assert.equal(signupA.status, 200, `Signup A falhou: ${sanitizeHttpSummary(signupA)}`);
    const studentAId = signupA.data?.user?.id ?? signupA.data?.id;
    assert.ok(studentAId, 'ID de Estudante A ausente');
    assert.equal(signupA.data?.access_token ?? null, null, 'Com confirmação ativa, signup não libera sessão imediata');

    const unconfirmedLoginA = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { email: emailA, password: passA },
    });
    assert.equal(unconfirmedLoginA.ok, false, 'Login antes de confirmar e-mail precisa falhar');

    const confirmMailA = await findMailpitMessageForEmail(env.mailpitUrl, emailA, 'Confirm');
    const verifyResultA = await followVerifyLink(extractAuthVerifyUrlFromMessage(confirmMailA));
    assert.ok(!verifyResultA.error, `Erro na confirmação de e-mail A: ${verifyResultA.error}`);

    const loginA = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { email: emailA, password: passA },
    });
    assert.equal(loginA.status, 200, `Login A pós-confirmação falhou: ${sanitizeHttpSummary(loginA)}`);
    const tokenA = loginA.data.access_token;
    const refreshA = loginA.data.refresh_token;
    sensitivePool.push(tokenA, refreshA);

    const profileA = await httpJson(`${env.apiUrl}/rest/v1/profiles?id=eq.${studentAId}&select=id,role,email`, {
      headers: clientHeaders(tokenA),
    });
    assert.equal(profileA.status, 200);
    assert.equal(profileA.data.length, 1);
    assert.equal(profileA.data[0].role, 'student');
    console.log('✓ Cenários 1 e 13: Cadastro + confirmação de e-mail no ambiente local validados');

    // Cenário 2: Tentativa de cadastro enviando role='reviewer' no metadata não concede privilégio
    const signupB = await httpJson(`${env.apiUrl}/auth/v1/signup`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: {
        email: emailB,
        password: passB,
        data: { full_name: 'Estudante B HTTP', role: 'reviewer' },
      },
    });
    assert.equal(signupB.status, 200, `Signup B falhou: ${sanitizeHttpSummary(signupB)}`);
    const studentBId = signupB.data?.user?.id ?? signupB.data?.id;
    const confirmMailB = await findMailpitMessageForEmail(env.mailpitUrl, emailB, 'Confirm');
    await followVerifyLink(extractAuthVerifyUrlFromMessage(confirmMailB));

    const loginB = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { email: emailB, password: passB },
    });
    assert.equal(loginB.status, 200, `Login B falhou: ${sanitizeHttpSummary(loginB)}`);
    const tokenB = loginB.data.access_token;
    sensitivePool.push(tokenB);

    const profileB = await httpJson(`${env.apiUrl}/rest/v1/profiles?id=eq.${studentBId}&select=id,role`, {
      headers: clientHeaders(tokenB),
    });
    assert.equal(profileB.status, 200);
    assert.equal(profileB.data[0].role, 'student', 'Metadata role=reviewer nunca deve conceder papel reviewer');
    console.log('✓ Cenário 2: Tentativa de escalação via metadata no signup bloqueada');

    // Cenário 15: Link/token inválido ou expirado retorna erro apropriado
    const invalidVerifyGet = await fetch(
      `${env.apiUrl}/auth/v1/verify?token=token-invalido-expirado-${runId}&type=recovery`,
      { redirect: 'manual' },
    );
    const invalidLocation = invalidVerifyGet.headers.get('location') ?? '';
    assert.ok(
      !invalidVerifyGet.ok && (invalidVerifyGet.status >= 400 || invalidLocation.includes('error=')),
      `Link inválido deve retornar erro (status=${invalidVerifyGet.status})`,
    );

    const invalidVerifyPost = await httpJson(`${env.apiUrl}/auth/v1/verify`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: {
        token_hash: `hash_invalido_${runId}`,
        type: 'recovery',
      },
    });
    assert.equal(invalidVerifyPost.ok, false, 'POST /auth/v1/verify com token inválido deve falhar');
    assert.ok(invalidVerifyPost.status >= 400 && invalidVerifyPost.status < 500);
    console.log('✓ Cenário 15: Token/link inválido ou expirado retorna erro HTTP apropriado');

    // Cenário 3: Usuário sem sessão (anon) não acessa recursos privados nem RPCs administrativas
    for (const endpoint of [
      '/rest/v1/profiles',
      '/rest/v1/internship_processes',
      '/rest/v1/process_requirements',
      '/rest/v1/document_submissions',
      '/rest/v1/audit_events',
      '/rest/v1/institutions',
      '/rest/v1/process_progress_v',
    ]) {
      const anonRes = await httpJson(`${env.apiUrl}${endpoint}`, {
        headers: {
          apikey: env.anonKey,
          Authorization: `Bearer ${env.anonKey}`,
        },
      });
      assert.ok(
        anonRes.status === 401 || anonRes.status === 403,
        `Anon não pode acessar ${endpoint}; recebido ${sanitizeHttpSummary(anonRes)}`,
      );
    }

    for (const [rpcPath, rpcBody] of [
      [
        '/rest/v1/rpc/admin_set_user_role',
        {
          p_user_id: studentAId,
          p_new_role: 'reviewer',
          p_operator_type: OPERATOR_TYPE,
          p_operator_identifier: OPERATOR_IDENTIFIER,
          p_reason: 'Tentativa anônima',
        },
      ],
      [
        '/rest/v1/rpc/admin_assign_reviewer_scope',
        {
          p_reviewer_id: studentAId,
          p_institution_id: DEMO_INSTITUTION_ID,
          p_course_id: DEMO_INSTITUTION_ID,
          p_course_modality_id: null,
          p_operator_type: OPERATOR_TYPE,
          p_operator_identifier: OPERATOR_IDENTIFIER,
          p_reason: 'Tentativa anônima',
        },
      ],
      [
        '/rest/v1/rpc/admin_revoke_reviewer_assignment',
        {
          p_assignment_id: DEMO_INSTITUTION_ID,
          p_operator_type: OPERATOR_TYPE,
          p_operator_identifier: OPERATOR_IDENTIFIER,
          p_reason: 'Tentativa anônima',
        },
      ],
    ]) {
      const anonRpc = await httpJson(`${env.apiUrl}${rpcPath}`, {
        method: 'POST',
        headers: {
          apikey: env.anonKey,
          Authorization: `Bearer ${env.anonKey}`,
        },
        body: rpcBody,
      });
      assert.ok(
        anonRpc.status === 401 || anonRpc.status === 403,
        `Anon não pode executar ${rpcPath}: ${sanitizeHttpSummary(anonRpc)}`,
      );
    }
    console.log('✓ Cenário 3: Usuário sem sessão bloqueado em todos os recursos e RPCs administrativas');

    // C1-02: Criar catálogos isolados desta execução (inScope para A/R1 e outScope para B)
    const inScope = await createIsolatedCatalog(apiUrlOr(env.apiUrl), serviceHeaders, `IN_${runId}`, true);
    const outScope = await createIsolatedCatalog(apiUrlOr(env.apiUrl), serviceHeaders, `OUT_${runId}`, true);

    const procA = await httpJson(`${env.apiUrl}/rest/v1/internship_processes`, {
      method: 'POST',
      headers: { ...serviceHeaders, Prefer: 'return=representation' },
      body: {
        owner_id: studentAId,
        institution_id: DEMO_INSTITUTION_ID,
        course_id: inScope.courseId,
        course_modality_id: inScope.modalityId,
        template_id: inScope.templateId,
        template_version: 1,
        status: 'in_progress',
        is_demo: true,
      },
    });
    assert.equal(procA.status, 201, `Erro criando procA: ${sanitizeHttpSummary(procA)}`);
    const procAId = procA.data[0].id;

    const procB = await httpJson(`${env.apiUrl}/rest/v1/internship_processes`, {
      method: 'POST',
      headers: { ...serviceHeaders, Prefer: 'return=representation' },
      body: {
        owner_id: studentBId,
        institution_id: DEMO_INSTITUTION_ID,
        course_id: outScope.courseId,
        course_modality_id: outScope.modalityId,
        template_id: outScope.templateId,
        template_version: 1,
        status: 'in_progress',
        is_demo: true,
      },
    });
    assert.equal(procB.status, 201, `Erro criando procB: ${sanitizeHttpSummary(procB)}`);
    const procBId = procB.data[0].id;

    const reqInsert = await httpJson(`${env.apiUrl}/rest/v1/process_requirements`, {
      method: 'POST',
      headers: serviceHeaders,
      body: [
        {
          process_id: procAId,
          template_item_id: inScope.itemId,
          code: inScope.itemCode,
          title: '[Demonstração] Item A',
          description: 'Demo',
          acceptance_criteria: 'Demo',
          is_required: true,
          display_order: 1,
          status: 'not_submitted',
        },
        {
          process_id: procBId,
          template_item_id: outScope.itemId,
          code: outScope.itemCode,
          title: '[Demonstração] Item B',
          description: 'Demo',
          acceptance_criteria: 'Demo',
          is_required: true,
          display_order: 1,
          status: 'not_submitted',
        },
      ],
    });
    assert.equal(reqInsert.status, 201, `Erro criando process_requirements: ${sanitizeHttpSummary(reqInsert)}`);

    // Cenário 4: Estudante A não acessa dados de Estudante B nem de outros ciclos
    const aProcesses = await httpJson(`${env.apiUrl}/rest/v1/internship_processes?select=id,owner_id`, {
      headers: clientHeaders(tokenA),
    });
    assert.equal(aProcesses.status, 200);
    assert.deepEqual(aProcesses.data.map((p) => p.id), [procAId]);

    const aReadsBProfile = await httpJson(`${env.apiUrl}/rest/v1/profiles?id=eq.${studentBId}`, {
      headers: clientHeaders(tokenA),
    });
    assert.equal(aReadsBProfile.status, 200);
    assert.equal(aReadsBProfile.data.length, 0);

    const aReadsBReqs = await httpJson(`${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${procBId}`, {
      headers: clientHeaders(tokenA),
    });
    assert.equal(aReadsBReqs.data.length, 0);
    console.log('✓ Cenário 4: Isolamento cruzado entre Estudante A e Estudante B comprovado');

    // Cenário 10 + C1-05 + C1-06: Provisionamento administrativo protegido, identificável e auditado
    const r1Create = await httpJson(`${env.apiUrl}/auth/v1/admin/users`, {
      method: 'POST',
      headers: serviceHeaders,
      body: { email: emailR1, password: passR1, email_confirm: true, user_metadata: { full_name: 'Revisor R1 HTTP' } },
    });
    assert.equal(r1Create.status, 200, `Erro criando R1: ${sanitizeHttpSummary(r1Create)}`);
    const r1Id = r1Create.data.id;

    const r2Create = await httpJson(`${env.apiUrl}/auth/v1/admin/users`, {
      method: 'POST',
      headers: serviceHeaders,
      body: { email: emailR2, password: passR2, email_confirm: true, user_metadata: { full_name: 'Revisor R2 HTTP' } },
    });
    assert.equal(r2Create.status, 200, `Erro criando R2: ${sanitizeHttpSummary(r2Create)}`);
    const r2Id = r2Create.data.id;

    // Estudante A não pode executar RPCs administrativas (C1-05)
    const studentCallsAdminRpc = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_set_user_role`, {
      method: 'POST',
      headers: clientHeaders(tokenA),
      body: {
        p_user_id: studentAId,
        p_new_role: 'reviewer',
        p_operator_type: OPERATOR_TYPE,
        p_operator_identifier: OPERATOR_IDENTIFIER,
        p_reason: 'Tentativa não autorizada',
      },
    });
    assert.ok(studentCallsAdminRpc.status === 401 || studentCallsAdminRpc.status === 403);

    // C1-06: Sem identificação válida ou tentando verified_human_operator via service_role sem sub deve falhar
    const spoofHumanOp = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_set_user_role`, {
      method: 'POST',
      headers: serviceHeaders,
      body: {
        p_user_id: r1Id,
        p_new_role: 'reviewer',
        p_operator_type: 'verified_human_operator',
        p_operator_identifier: studentAId,
        p_reason: 'Tentativa sem sessão humana verificada',
      },
    });
    assert.equal(spoofHumanOp.ok, false, 'verified_human_operator sem JWT sub verificado deve falhar');

    const missingReason = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_set_user_role`, {
      method: 'POST',
      headers: serviceHeaders,
      body: {
        p_user_id: r1Id,
        p_new_role: 'reviewer',
        p_operator_type: OPERATOR_TYPE,
        p_operator_identifier: OPERATOR_IDENTIFIER,
        p_reason: '  ',
      },
    });
    assert.equal(missingReason.ok, false, 'Operação administrativa sem motivo válido deve falhar');

    const promoteR1 = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_set_user_role`, {
      method: 'POST',
      headers: serviceHeaders,
      body: {
        p_user_id: r1Id,
        p_new_role: 'reviewer',
        p_operator_type: OPERATOR_TYPE,
        p_operator_identifier: OPERATOR_IDENTIFIER,
        p_reason: 'Teste HTTP automatizado R1',
      },
    });
    assert.equal(promoteR1.status, 200, `Erro promovendo R1: ${sanitizeHttpSummary(promoteR1)}`);

    const promoteR2 = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_set_user_role`, {
      method: 'POST',
      headers: serviceHeaders,
      body: {
        p_user_id: r2Id,
        p_new_role: 'reviewer',
        p_operator_type: OPERATOR_TYPE,
        p_operator_identifier: OPERATOR_IDENTIFIER,
        p_reason: 'Teste HTTP automatizado R2',
      },
    });
    assert.equal(promoteR2.status, 200, `Erro promovendo R2: ${sanitizeHttpSummary(promoteR2)}`);

    const assignR1 = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_assign_reviewer_scope`, {
      method: 'POST',
      headers: serviceHeaders,
      body: {
        p_reviewer_id: r1Id,
        p_institution_id: DEMO_INSTITUTION_ID,
        p_course_id: inScope.courseId,
        p_course_modality_id: inScope.modalityId,
        p_operator_type: OPERATOR_TYPE,
        p_operator_identifier: OPERATOR_IDENTIFIER,
        p_reason: 'Atribuição HTTP isolada R1',
      },
    });
    assert.equal(assignR1.status, 200, `Erro atribuindo R1: ${sanitizeHttpSummary(assignR1)}`);
    const assignmentR1Id = assignR1.data.id;

    const adminAudit = await httpJson(
      `${env.apiUrl}/rest/v1/audit_events?target_user_id=eq.${r1Id}&order=occurred_at.asc`,
      { headers: serviceHeaders },
    );
    assert.equal(adminAudit.status, 200);
    const roleEvent = adminAudit.data.find((e) => e.event_type === 'user_role_changed');
    const assignEvent = adminAudit.data.find((e) => e.event_type === 'reviewer_assignment_created');
    assert.ok(roleEvent && assignEvent, 'Auditoria deve conter user_role_changed e reviewer_assignment_created');
    assert.equal(roleEvent.operator_type, OPERATOR_TYPE);
    assert.equal(roleEvent.operator_identifier, OPERATOR_IDENTIFIER);
    assert.equal(roleEvent.actor_id, null);
    assert.equal(assignEvent.operator_type, OPERATOR_TYPE);
    assert.equal(assignEvent.operator_identifier, OPERATOR_IDENTIFIER);
    console.log('✓ Cenário 10, C1-05 e C1-06: Provisionamento protegido com identidade auditável');

    // Login R1 e R2
    const loginR1 = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { email: emailR1, password: passR1 },
    });
    assert.equal(loginR1.status, 200);
    const tokenR1 = loginR1.data.access_token;
    sensitivePool.push(tokenR1);

    const loginR2 = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { email: emailR2, password: passR2 },
    });
    assert.equal(loginR2.status, 200);
    const tokenR2 = loginR2.data.access_token;
    sensitivePool.push(tokenR2);

    // Revisor autenticado também não executa RPC administrativa
    const reviewerCallsAdminRpc = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_assign_reviewer_scope`, {
      method: 'POST',
      headers: clientHeaders(tokenR1),
      body: {
        p_reviewer_id: r1Id,
        p_institution_id: DEMO_INSTITUTION_ID,
        p_course_id: outScope.courseId,
        p_course_modality_id: outScope.modalityId,
        p_operator_type: OPERATOR_TYPE,
        p_operator_identifier: OPERATOR_IDENTIFIER,
        p_reason: 'Tentativa escalação revisor',
      },
    });
    assert.ok(reviewerCallsAdminRpc.status === 401 || reviewerCallsAdminRpc.status === 403);

    // Cenário 5: Revisor R1 atribuído visualiza apenas seu escopo (procA), não procB nem processos de outras execuções
    const r1Processes = await httpJson(`${env.apiUrl}/rest/v1/internship_processes?select=id`, {
      headers: clientHeaders(tokenR1),
    });
    assert.equal(r1Processes.status, 200);
    assert.deepEqual(r1Processes.data.map((p) => p.id), [procAId]);

    const r1OutOfScope = await httpJson(`${env.apiUrl}/rest/v1/internship_processes?id=eq.${procBId}`, {
      headers: clientHeaders(tokenR1),
    });
    assert.equal(r1OutOfScope.data.length, 0);
    console.log('✓ Cenário 5: Revisor atribuído R1 visualiza apenas seu escopo');

    // Cenário 6: Revisor R2 não atribuído vê zero processos protegidos em todo o banco
    const r2Processes = await httpJson(`${env.apiUrl}/rest/v1/internship_processes?select=id`, {
      headers: clientHeaders(tokenR2),
    });
    assert.equal(r2Processes.status, 200);
    assert.equal(r2Processes.data.length, 0);
    const r2Reqs = await httpJson(`${env.apiUrl}/rest/v1/process_requirements?select=id`, {
      headers: clientHeaders(tokenR2),
    });
    assert.equal(r2Reqs.data.length, 0);
    console.log('✓ Cenário 6: Revisor não atribuído R2 bloqueado por padrão');

    // Cenário 7: Usuário comum não altera role ou assignments
    const escalateSelf = await httpJson(`${env.apiUrl}/rest/v1/profiles?id=eq.${studentAId}`, {
      method: 'PATCH',
      headers: clientHeaders(tokenA),
      body: { role: 'reviewer' },
    });
    assert.equal(escalateSelf.ok, false, 'Estudante não pode alterar role em profiles');

    const insertAssignmentSelf = await httpJson(`${env.apiUrl}/rest/v1/reviewer_assignments`, {
      method: 'POST',
      headers: clientHeaders(tokenA),
      body: {
        reviewer_id: studentAId,
        institution_id: DEMO_INSTITUTION_ID,
        course_id: inScope.courseId,
        course_modality_id: inScope.modalityId,
      },
    });
    assert.equal(insertAssignmentSelf.ok, false, 'Estudante não pode inserir reviewer_assignments');

    const r1AlterAssignment = await httpJson(`${env.apiUrl}/rest/v1/reviewer_assignments?id=eq.${assignmentR1Id}`, {
      method: 'PATCH',
      headers: clientHeaders(tokenR1),
      body: { course_modality_id: null },
    });
    assert.equal(r1AlterAssignment.ok, false, 'Revisor não pode ampliar seu próprio assignment');
    console.log('✓ Cenário 7: Alteração direta de role e assignments negada');

    // Cenário 8: Usuário comum não altera diretamente estados e histórico
    const mutateProcess = await httpJson(`${env.apiUrl}/rest/v1/internship_processes?id=eq.${procAId}`, {
      method: 'PATCH',
      headers: clientHeaders(tokenA),
      body: { status: 'documentally_complete' },
    });
    assert.equal(mutateProcess.ok, false);

    const mutateReq = await httpJson(`${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${procAId}`, {
      method: 'PATCH',
      headers: clientHeaders(tokenR1),
      body: { status: 'approved' },
    });
    assert.equal(mutateReq.ok, false);

    const insertAudit = await httpJson(`${env.apiUrl}/rest/v1/audit_events`, {
      method: 'POST',
      headers: clientHeaders(tokenA),
      body: {
        event_type: 'forged_event',
        actor_role: 'reviewer',
        entity_table: 'profiles',
        entity_id: studentAId,
      },
    });
    assert.equal(insertAudit.ok, false);
    console.log('✓ Cenário 8: Mutação direta de estados e histórico bloqueada');

    // Cenário 9: Revogação de assignment bloqueia imediatamente novos acessos de R1
    const revokeR1 = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_revoke_reviewer_assignment`, {
      method: 'POST',
      headers: serviceHeaders,
      body: {
        p_assignment_id: assignmentR1Id,
        p_operator_type: OPERATOR_TYPE,
        p_operator_identifier: OPERATOR_IDENTIFIER,
        p_reason: 'Revogação HTTP teste',
      },
    });
    assert.equal(revokeR1.status, 200);
    assert.equal(revokeR1.data.active, false);

    const r1AfterRevoke = await httpJson(`${env.apiUrl}/rest/v1/internship_processes?select=id`, {
      headers: clientHeaders(tokenR1),
    });
    assert.equal(r1AfterRevoke.status, 200);
    assert.equal(r1AfterRevoke.data.length, 0, 'Após revogação, R1 não pode ver processos');
    console.log('✓ Cenário 9: Revogação de assignment bloqueia acessos imediatamente');

    // Cenário 12: Sessão restaurada é validada via refresh_token
    const refreshedA = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=refresh_token`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { refresh_token: refreshA },
    });
    assert.equal(refreshedA.status, 200, `Refresh A falhou: ${sanitizeHttpSummary(refreshedA)}`);
    const freshTokenA = refreshedA.data.access_token;
    const freshRefreshA = refreshedA.data.refresh_token;
    sensitivePool.push(freshTokenA, freshRefreshA);

    const userCheckA = await httpJson(`${env.apiUrl}/auth/v1/user`, {
      headers: clientHeaders(freshTokenA),
    });
    assert.equal(userCheckA.status, 200);
    assert.equal(userCheckA.data.id, studentAId);
    console.log('✓ Cenário 12: Sessão restaurada/renovada validada');

    // Cenário 11: Logout bloqueia acesso privado e invalida sessão/refresh
    const logoutA = await httpJson(`${env.apiUrl}/auth/v1/logout?scope=global`, {
      method: 'POST',
      headers: clientHeaders(freshTokenA),
    });
    assert.ok(logoutA.status === 200 || logoutA.status === 204, `Logout falhou: HTTP ${logoutA.status}`);

    const userAfterLogout = await httpJson(`${env.apiUrl}/auth/v1/user`, {
      headers: clientHeaders(freshTokenA),
    });
    assert.equal(userAfterLogout.ok, false, 'Access token após logout global deve ser rejeitado pelo GoTrue');

    const refreshAfterLogout = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=refresh_token`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { refresh_token: freshRefreshA },
    });
    assert.equal(refreshAfterLogout.ok, false, 'Refresh token após logout global deve ser rejeitado');
    console.log('✓ Cenário 11: Logout global invalida sessão e acesso privado');

    // Cenário 14: Recuperação de senha completa o fluxo via Mailpit
    const recoverB = await httpJson(`${env.apiUrl}/auth/v1/recover`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { email: emailB },
    });
    assert.equal(recoverB.status, 200, `Recover B falhou: ${sanitizeHttpSummary(recoverB)}`);

    const recoverMailB = await findMailpitMessageForEmail(env.mailpitUrl, emailB, 'Reset');
    const recoveryVerify = await followVerifyLink(extractAuthVerifyUrlFromMessage(recoverMailB));
    assert.ok(recoveryVerify.accessToken, 'Verify de recuperação deve retornar access_token válido');
    sensitivePool.push(recoveryVerify.accessToken);

    const updatePassB = await httpJson(`${env.apiUrl}/auth/v1/user`, {
      method: 'PUT',
      headers: clientHeaders(recoveryVerify.accessToken),
      body: { password: newPassB },
    });
    assert.equal(updatePassB.status, 200, `Atualização de senha B falhou: ${sanitizeHttpSummary(updatePassB)}`);

    const oldPassLoginB = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { email: emailB, password: passB },
    });
    assert.equal(oldPassLoginB.ok, false, 'Senha antiga não pode mais autenticar');

    const newPassLoginB = await httpJson(`${env.apiUrl}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: clientHeaders(env.anonKey),
      body: { email: emailB, password: newPassB },
    });
    assert.equal(newPassLoginB.status, 200, `Login com nova senha falhou: ${sanitizeHttpSummary(newPassLoginB)}`);
    console.log('✓ Cenário 14: Recuperação e redefinição de senha completadas ponta a ponta');

    // ========================================================================
    // LOTE 2 (ESP-10 / ESP-11 / ESP-12): Abertura segura, snapshot e leituras
    // ========================================================================
    await runLote2ProcessAndChecklistScenarios({
      env,
      runId,
      clientHeaders,
      serviceHeaders,
      sensitivePool,
    });

    console.log('\nTODOS OS CENÁRIOS HTTP/AUTH/RLS E HARDENING PASSARAM COM SUCESSO.');
  } catch (err) {
    const safeMessage = redactKnownSecrets(err?.message ?? String(err), sensitivePool);
    console.error(`\n[FALHA NO TESTE HTTP]: ${safeMessage}`);
    process.exit(1);
  }
}

async function createConfirmedAdminUser(apiUrl, serviceHeaders, clientHeaders, anonKey, sensitivePool, { email, password, fullName }) {
  const created = await httpJson(`${apiUrl}/auth/v1/admin/users`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName },
    },
  });
  assert.equal(created.status, 200, `Erro criando usuário admin (${email}): ${sanitizeHttpSummary(created)}`);

  const login = await httpJson(`${apiUrl}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: clientHeaders(anonKey),
    body: { email, password },
  });
  assert.equal(login.status, 200, `Erro autenticando usuário (${email}): ${sanitizeHttpSummary(login)}`);
  sensitivePool.push(password, login.data.access_token, login.data.refresh_token);

  return {
    id: created.data.id,
    token: login.data.access_token,
  };
}

async function createIsolatedCatalogRecord(apiUrl, serviceHeaders, {
  institutionId = DEMO_INSTITUTION_ID,
  suffix,
  courseActive = true,
  modalityActive = true,
  templateStatus = null,
  items = [],
}) {
  const course = await httpJson(`${apiUrl}/rest/v1/courses`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      institution_id: institutionId,
      code: `L2_COURSE_${suffix}`,
      name: `Curso L2 HTTP (${suffix})`,
      is_demo: true,
      active: courseActive,
    },
  });
  assert.equal(course.status, 201, `Erro criando curso L2 (${suffix}): ${sanitizeHttpSummary(course)}`);
  const courseId = course.data[0].id;

  const modality = await httpJson(`${apiUrl}/rest/v1/course_modalities`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      course_id: courseId,
      code: `L2_MOD_${suffix}`,
      name: `Modalidade L2 HTTP (${suffix})`,
      is_mandatory: true,
      is_demo: true,
      active: modalityActive,
    },
  });
  assert.equal(modality.status, 201, `Erro criando modalidade L2 (${suffix}): ${sanitizeHttpSummary(modality)}`);
  const modalityId = modality.data[0].id;

  let templateId = null;
  const createdItems = [];

  if (templateStatus !== null) {
    const tplDraft = await httpJson(`${apiUrl}/rest/v1/requirement_templates`, {
      method: 'POST',
      headers: { ...serviceHeaders, Prefer: 'return=representation' },
      body: {
        institution_id: institutionId,
        course_id: courseId,
        course_modality_id: modalityId,
        version: 1,
        title: `Template L2 v1 (${suffix})`,
        source_reference: 'Dados fictícios automatizados Lote 2 HTTP',
        status: 'draft',
        is_demo: true,
      },
    });
    assert.equal(tplDraft.status, 201, `Erro criando template L2 (${suffix}): ${sanitizeHttpSummary(tplDraft)}`);
    templateId = tplDraft.data[0].id;

    for (const itemSpec of items) {
      const insertedItem = await httpJson(`${apiUrl}/rest/v1/requirement_template_items`, {
        method: 'POST',
        headers: { ...serviceHeaders, Prefer: 'return=representation' },
        body: {
          template_id: templateId,
          code: itemSpec.code,
          title: itemSpec.title,
          description: itemSpec.description,
          acceptance_criteria: itemSpec.acceptanceCriteria,
          is_required: itemSpec.isRequired,
          display_order: itemSpec.displayOrder,
          is_demo: true,
        },
      });
      assert.equal(insertedItem.status, 201, `Erro criando item L2 (${itemSpec.code}): ${sanitizeHttpSummary(insertedItem)}`);
      createdItems.push(insertedItem.data[0]);
    }

    if (templateStatus === 'published' || templateStatus === 'archived') {
      const pub = await httpJson(`${apiUrl}/rest/v1/requirement_templates?id=eq.${templateId}`, {
        method: 'PATCH',
        headers: serviceHeaders,
        body: { status: 'published' },
      });
      assert.equal(pub.ok, true, `Erro publicando template L2 (${suffix}): ${sanitizeHttpSummary(pub)}`);
    }
    if (templateStatus === 'archived') {
      const arch = await httpJson(`${apiUrl}/rest/v1/requirement_templates?id=eq.${templateId}`, {
        method: 'PATCH',
        headers: serviceHeaders,
        body: { status: 'archived' },
      });
      assert.equal(arch.ok, true, `Erro arquivando template L2 (${suffix}): ${sanitizeHttpSummary(arch)}`);
    }
  }

  return { institutionId, courseId, modalityId, templateId, items: createdItems };
}

async function runLote2ProcessAndChecklistScenarios({
  env,
  runId,
  clientHeaders,
  serviceHeaders,
  sensitivePool,
}) {
  const passC = `DemoC!${crypto.randomBytes(8).toString('hex')}`;
  const passD = `DemoD!${crypto.randomBytes(8).toString('hex')}`;
  const passR3 = `DemoR3!${crypto.randomBytes(8).toString('hex')}`;
  const passR4 = `DemoR4!${crypto.randomBytes(8).toString('hex')}`;

  const studentC = await createConfirmedAdminUser(env.apiUrl, serviceHeaders, clientHeaders, env.anonKey, sensitivePool, {
    email: `estudante.c.l2.${runId}@demo.local`,
    password: passC,
    fullName: 'Estudante C Lote 2 HTTP',
  });
  const studentD = await createConfirmedAdminUser(env.apiUrl, serviceHeaders, clientHeaders, env.anonKey, sensitivePool, {
    email: `estudante.d.l2.${runId}@demo.local`,
    password: passD,
    fullName: 'Estudante D Lote 2 HTTP',
  });
  const reviewerR3 = await createConfirmedAdminUser(env.apiUrl, serviceHeaders, clientHeaders, env.anonKey, sensitivePool, {
    email: `revisor.r3.l2.${runId}@demo.local`,
    password: passR3,
    fullName: 'Revisor R3 Atribuído Lote 2 HTTP',
  });
  const reviewerR4 = await createConfirmedAdminUser(env.apiUrl, serviceHeaders, clientHeaders, env.anonKey, sensitivePool, {
    email: `revisor.r4.l2.${runId}@demo.local`,
    password: passR4,
    fullName: 'Revisor R4 Sem Escopo Lote 2 HTTP',
  });

  // Promover R3 e R4 para reviewer
  for (const rev of [reviewerR3, reviewerR4]) {
    const promote = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_set_user_role`, {
      method: 'POST',
      headers: serviceHeaders,
      body: {
        p_user_id: rev.id,
        p_new_role: 'reviewer',
        p_operator_type: OPERATOR_TYPE,
        p_operator_identifier: OPERATOR_IDENTIFIER,
        p_reason: 'Provisionamento Lote 2 HTTP',
      },
    });
    assert.equal(promote.status, 200, `Erro promovendo revisor L2: ${sanitizeHttpSummary(promote)}`);
  }

  // Criar instituição inativa isolada por runId
  const inactiveInst = await httpJson(`${env.apiUrl}/rest/v1/institutions`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      code: `L2_INST_INAT_${runId}`,
      name: `Instituição Inativa HTTP (${runId})`,
      is_demo: true,
      active: false,
    },
  });
  assert.equal(inactiveInst.status, 201, `Erro criando instituição inativa: ${sanitizeHttpSummary(inactiveInst)}`);
  const inactiveInstId = inactiveInst.data[0].id;

  // Catálogos isolados do Lote 2
  const catMain = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `MAIN_${runId}`,
    templateStatus: 'published',
    items: [
      {
        code: `L2_OBR1_${runId}`,
        title: '[Demo L2] Termo Obrigatório 1 v1',
        description: 'Descrição obrigatória 1 v1',
        acceptanceCriteria: 'Critério obrigatório 1 v1',
        isRequired: true,
        displayOrder: 1,
      },
      {
        code: `L2_OBR2_${runId}`,
        title: '[Demo L2] Plano Obrigatório 2 v1',
        description: 'Descrição obrigatória 2 v1',
        acceptanceCriteria: 'Critério obrigatório 2 v1',
        isRequired: true,
        displayOrder: 2,
      },
      {
        code: `L2_OPC3_${runId}`,
        title: '[Demo L2] Documento Opcional 3 v1',
        description: 'Descrição opcional 3 v1',
        acceptanceCriteria: 'Critério opcional 3 v1',
        isRequired: false,
        displayOrder: 3,
      },
    ],
  });

  // Criar v2 DRAFT coexistindo com v1 PUBLISHED em catMain para garantir que v2 draft não é escolhida
  const catMainV2Draft = await httpJson(`${env.apiUrl}/rest/v1/requirement_templates`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      institution_id: catMain.institutionId,
      course_id: catMain.courseId,
      course_modality_id: catMain.modalityId,
      version: 2,
      title: `Template L2 v2 (${runId})`,
      source_reference: 'Versão v2 fictícia',
      status: 'draft',
      is_demo: true,
    },
  });
  assert.equal(catMainV2Draft.status, 201, `Erro criando template v2 draft: ${sanitizeHttpSummary(catMainV2Draft)}`);
  const tplV2Id = catMainV2Draft.data[0].id;

  const tplV2Item = await httpJson(`${env.apiUrl}/rest/v1/requirement_template_items`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      template_id: tplV2Id,
      code: `L2_V2_OBR1_${runId}`,
      title: '[Demo L2] Único Obrigatório V2',
      description: 'Descrição v2',
      acceptance_criteria: 'Critério v2',
      is_required: true,
      display_order: 1,
      is_demo: true,
    },
  });
  assert.equal(tplV2Item.status, 201, `Erro criando item v2: ${sanitizeHttpSummary(tplV2Item)}`);

  const catOnlyOpt = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `OPT_${runId}`,
    templateStatus: 'published',
    items: [
      {
        code: `L2_ONLY_OPT_${runId}`,
        title: '[Demo L2] Único Opcional',
        description: 'Somente opcional',
        acceptanceCriteria: 'Critério opcional',
        isRequired: false,
        displayOrder: 1,
      },
    ],
  });

  const catConcurrent = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `CONC_${runId}`,
    templateStatus: 'published',
    items: [
      {
        code: `L2_CONC_OBR_${runId}`,
        title: '[Demo L2] Item Concorrência',
        description: 'Teste concorrência',
        acceptanceCriteria: 'Critério concorrência',
        isRequired: true,
        displayOrder: 1,
      },
    ],
  });

  const catNoTpl = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `NOTPL_${runId}`,
    templateStatus: null,
  });

  const catDraftOnly = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `DRAFT_${runId}`,
    templateStatus: 'draft',
    items: [
      {
        code: `L2_DRAFT_${runId}`,
        title: '[Demo L2] Draft Only',
        description: 'Draft',
        acceptanceCriteria: 'Draft',
        isRequired: true,
        displayOrder: 1,
      },
    ],
  });

  const catArchOnly = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `ARCH_${runId}`,
    templateStatus: 'archived',
    items: [
      {
        code: `L2_ARCH_${runId}`,
        title: '[Demo L2] Archived Only',
        description: 'Arch',
        acceptanceCriteria: 'Arch',
        isRequired: true,
        displayOrder: 1,
      },
    ],
  });

  const catModInat = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `MODINAT_${runId}`,
    modalityActive: false,
    templateStatus: 'published',
    items: [
      {
        code: `L2_MODINAT_${runId}`,
        title: '[Demo L2] Mod Inativa',
        description: 'Mod Inat',
        acceptanceCriteria: 'Mod Inat',
        isRequired: true,
        displayOrder: 1,
      },
    ],
  });

  const catCourseInat = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `CURINAT_${runId}`,
    courseActive: false,
    templateStatus: 'published',
    items: [
      {
        code: `L2_CURINAT_${runId}`,
        title: '[Demo L2] Curso Inativo',
        description: 'Cur Inat',
        acceptanceCriteria: 'Cur Inat',
        isRequired: true,
        displayOrder: 1,
      },
    ],
  });

  const catInstInat = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    institutionId: inactiveInstId,
    suffix: `INSTINAT_${runId}`,
    templateStatus: 'published',
    items: [
      {
        code: `L2_INSTINAT_${runId}`,
        title: '[Demo L2] Inst Inativa',
        description: 'Inst Inat',
        acceptanceCriteria: 'Inst Inat',
        isRequired: true,
        displayOrder: 1,
      },
    ],
  });

  // Atribuir Revisor R3 apenas a catMain
  const assignR3 = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_assign_reviewer_scope`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_reviewer_id: reviewerR3.id,
      p_institution_id: catMain.institutionId,
      p_course_id: catMain.courseId,
      p_course_modality_id: catMain.modalityId,
      p_operator_type: OPERATOR_TYPE,
      p_operator_identifier: OPERATOR_IDENTIFIER,
      p_reason: 'Escopo L2 R3 somente catMain',
    },
  });
  assert.equal(assignR3.status, 200, `Erro atribuindo R3: ${sanitizeHttpSummary(assignR3)}`);

  // 1) Anon e Revisor bloqueados na RPC create_internship_process
  const anonRpc = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(env.anonKey),
    body: { p_course_modality_id: catMain.modalityId },
  });
  assert.ok(anonRpc.status === 401 || anonRpc.status === 403, `Anon devia falhar RPC: ${sanitizeHttpSummary(anonRpc)}`);

  const revRpc = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(reviewerR4.token),
    body: { p_course_modality_id: catMain.modalityId },
  });
  assert.equal(revRpc.ok, false, 'Revisor não pode abrir processo via create_internship_process');
  assert.ok(revRpc.status === 401 || revRpc.status === 403, `Esperado 401/403 para revisor, recebido ${sanitizeHttpSummary(revRpc)}`);

  // 2) Tentativa de passar p_owner_id na RPC ou POST direto é bloqueada
  const forgedOwnerRpc = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentC.token),
    body: { p_course_modality_id: catMain.modalityId, p_owner_id: studentD.id },
  });
  assert.equal(forgedOwnerRpc.ok, false, 'RPC não deve aceitar p_owner_id arbitrário');

  const directInsertProcess = await httpJson(`${env.apiUrl}/rest/v1/internship_processes`, {
    method: 'POST',
    headers: clientHeaders(studentC.token),
    body: {
      owner_id: studentD.id,
      institution_id: catMain.institutionId,
      course_id: catMain.courseId,
      course_modality_id: catMain.modalityId,
      template_id: catMain.templateId,
      template_version: 1,
      status: 'in_progress',
    },
  });
  assert.ok(
    directInsertProcess.status === 401 || directInsertProcess.status === 403,
    `INSERT direto em internship_processes devia falhar: ${sanitizeHttpSummary(directInsertProcess)}`,
  );

  // 3) Catálogo ativo visível ao estudante autenticado (inclui seed + ativa, omite inativos)
  const catalogProbeIds = [
    '30000000-0000-4000-8000-000000000001',
    catMain.modalityId,
    catModInat.modalityId,
    catCourseInat.modalityId,
    catInstInat.modalityId,
  ].join(',');
  const activeCatalogRes = await httpJson(
    `${env.apiUrl}/rest/v1/course_modalities?select=id,code,name,is_mandatory,active,courses!inner(id,code,name,active,institutions!inner(id,code,name,active)),requirement_templates(id,version,title,status)&id=in.(${catalogProbeIds})&active=eq.true&courses.active=eq.true&courses.institutions.active=eq.true&requirement_templates.status=eq.published`,
    { headers: clientHeaders(studentC.token) },
  );
  assert.equal(activeCatalogRes.status, 200, `Erro consultando catálogo ativo: ${sanitizeHttpSummary(activeCatalogRes)}`);
  const returnedModIds = new Set(activeCatalogRes.data.map((row) => row.id));
  assert.equal(returnedModIds.has('30000000-0000-4000-8000-000000000001'), true, 'Modalidade demo do seed deve constar no catálogo');
  assert.equal(returnedModIds.has(catMain.modalityId), true, 'Modalidade ativa deve constar no catálogo');
  assert.equal(returnedModIds.has(catModInat.modalityId), false, 'Modalidade inativa não deve aparecer no catálogo');
  assert.equal(returnedModIds.has(catCourseInat.modalityId), false, 'Curso inativo não deve aparecer no catálogo');
  assert.equal(returnedModIds.has(catInstInat.modalityId), false, 'Instituição inativa não deve aparecer no catálogo');

  // 4) Estudante C abre processo em catMain -> recebe snapshot v1 completo e auditoria
  const openMain = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentC.token),
    body: { p_course_modality_id: catMain.modalityId },
  });
  assert.equal(openMain.status, 200, `Erro abrindo processo catMain: ${sanitizeHttpSummary(openMain)}`);
  const procC = openMain.data;
  assert.ok(procC?.id, 'ID do processo deve ser retornado');
  assert.equal(procC.owner_id, studentC.id, 'owner_id deve derivar do JWT do estudante C');
  assert.equal(procC.institution_id, catMain.institutionId);
  assert.equal(procC.course_id, catMain.courseId);
  assert.equal(procC.course_modality_id, catMain.modalityId);
  assert.equal(procC.template_id, catMain.templateId);
  assert.equal(procC.template_version, 1, 'Deve escolher v1 published, ignorando v2 draft');
  assert.equal(procC.status, 'in_progress');

  // Leitura detalhada do processo pelo ID + joins
  const procCDetail = await httpJson(
    `${env.apiUrl}/rest/v1/internship_processes?id=eq.${procC.id}&select=id,owner_id,template_id,template_version,status,institutions(id,code,name),courses(id,code,name),course_modalities(id,code,name,is_mandatory),requirement_templates(id,version,title,source_reference)`,
    { headers: clientHeaders(studentC.token) },
  );
  assert.equal(procCDetail.status, 200);
  assert.equal(procCDetail.data.length, 1);
  assert.equal(procCDetail.data[0].course_modalities.id, catMain.modalityId);
  assert.equal(procCDetail.data[0].requirement_templates.version, 1);

  // Leitura ordenada do snapshot em process_requirements
  const procCReqs = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${procC.id}&order=display_order.asc`,
    { headers: clientHeaders(studentC.token) },
  );
  assert.equal(procCReqs.status, 200);
  assert.equal(procCReqs.data.length, 3);
  assert.deepEqual(
    procCReqs.data.map((r) => [r.display_order, r.code, r.is_required, r.status, r.current_version, r.current_submission_id]),
    [
      [1, `L2_OBR1_${runId}`, true, 'not_submitted', 0, null],
      [2, `L2_OBR2_${runId}`, true, 'not_submitted', 0, null],
      [3, `L2_OPC3_${runId}`, false, 'not_submitted', 0, null],
    ],
  );
  assert.equal(procCReqs.data[0].template_item_id, catMain.items[0].id);

  // Progresso inicial (2 obrigatórios, 1 opcional excluído)
  const procCProgress = await httpJson(
    `${env.apiUrl}/rest/v1/process_progress_v?process_id=eq.${procC.id}`,
    { headers: clientHeaders(studentC.token) },
  );
  assert.equal(procCProgress.status, 200);
  assert.equal(procCProgress.data.length, 1);
  assert.equal(procCProgress.data[0].required_total, 2);
  assert.equal(procCProgress.data[0].required_approved, 0);
  assert.equal(procCProgress.data[0].progress_status, 'in_progress');
  assert.equal(Number(procCProgress.data[0].progress_percentage), 0);

  // Evento de auditoria process_created
  const procCAudit = await httpJson(
    `${env.apiUrl}/rest/v1/audit_events?process_id=eq.${procC.id}&event_type=eq.process_created`,
    { headers: clientHeaders(studentC.token) },
  );
  assert.equal(procCAudit.status, 200);
  assert.equal(procCAudit.data.length, 1);
  assert.equal(procCAudit.data[0].actor_id, studentC.id);
  assert.equal(procCAudit.data[0].operator_type, 'user_self_action');
  assert.equal(procCAudit.data[0].operator_identifier, 'rpc:create_internship_process');

  // 5) Processo sem obrigatórios -> indeterminate / null (nunca 100%)
  const openOpt = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentC.token),
    body: { p_course_modality_id: catOnlyOpt.modalityId },
  });
  assert.equal(openOpt.status, 200, `Erro abrindo processo somente opcional: ${sanitizeHttpSummary(openOpt)}`);
  const procOptId = openOpt.data.id;

  const optProgress = await httpJson(
    `${env.apiUrl}/rest/v1/process_progress_v?process_id=eq.${procOptId}`,
    { headers: clientHeaders(studentC.token) },
  );
  assert.equal(optProgress.status, 200);
  assert.equal(optProgress.data[0].required_total, 0);
  assert.equal(optProgress.data[0].progress_status, 'indeterminate');
  assert.equal(optProgress.data[0].progress_percentage, null);

  // 6) Duplicata sequencial + Concorrência HTTP real + Rejeições negativas sem audit_event espúrio
  const dupCall = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentC.token),
    body: { p_course_modality_id: catMain.modalityId },
  });
  assert.equal(dupCall.status, 409, `Duplicata ativa devia retornar 409: ${sanitizeHttpSummary(dupCall)}`);
  assert.equal(dupCall.data?.code, '23505');

  const [concRes1, concRes2] = await Promise.all([
    httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
      method: 'POST',
      headers: clientHeaders(studentD.token),
      body: { p_course_modality_id: catConcurrent.modalityId },
    }),
    httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
      method: 'POST',
      headers: clientHeaders(studentD.token),
      body: { p_course_modality_id: catConcurrent.modalityId },
    }),
  ]);
  const concResults = [concRes1, concRes2];
  const concSuccess = concResults.filter((r) => r.status === 200);
  const concConflict = concResults.filter((r) => r.status === 409);
  assert.equal(concSuccess.length, 1, `Concorrência devia aprovar exatamente 1 requisição (${concResults.map(sanitizeHttpSummary).join(' | ')})`);
  assert.equal(concConflict.length, 1, `Concorrência devia rejeitar exatamente 1 requisição (${concResults.map(sanitizeHttpSummary).join(' | ')})`);
  assert.equal(concConflict[0].data?.code, '23505');

  // Rejeições negativas por modalidade/escopo/template
  for (const [label, modalityId, expectedCode] of [
    ['inexistente', crypto.randomUUID(), 'P0002'],
    ['modalidade inativa', catModInat.modalityId, '23514'],
    ['curso inativo', catCourseInat.modalityId, '23514'],
    ['instituição inativa', catInstInat.modalityId, '23514'],
    ['sem template', catNoTpl.modalityId, '23514'],
    ['apenas draft', catDraftOnly.modalityId, '23514'],
    ['apenas archived', catArchOnly.modalityId, '23514'],
  ]) {
    const failRes = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
      method: 'POST',
      headers: clientHeaders(studentC.token),
      body: { p_course_modality_id: modalityId },
    });
    assert.equal(failRes.ok, false, `Cenário '${label}' devia falhar`);
    assert.equal(failRes.data?.code, expectedCode, `Cenário '${label}' devia retornar ${expectedCode}: ${sanitizeHttpSummary(failRes)}`);
  }

  // Confirmar contagem exata de processos e audit_events de Estudante C após todas as falhas
  const cAllProcs = await httpJson(`${env.apiUrl}/rest/v1/internship_processes?select=id`, {
    headers: clientHeaders(studentC.token),
  });
  assert.equal(cAllProcs.data.length, 2, 'Nenhuma falha negativa pode gerar processo parcial para Estudante C');

  const cAllCreatedAudits = await httpJson(
    `${env.apiUrl}/rest/v1/audit_events?actor_id=eq.${studentC.id}&event_type=eq.process_created`,
    { headers: serviceHeaders },
  );
  assert.equal(cAllCreatedAudits.data.length, 2, 'audit_events process_created só deve registrar os 2 sucessos');

  // 7) Isolamento cruzado por ID conhecido: D, R4 (sem escopo), R3 (com escopo)
  for (const endpoint of [
    `/rest/v1/internship_processes?id=eq.${procC.id}`,
    `/rest/v1/process_requirements?process_id=eq.${procC.id}`,
    `/rest/v1/process_progress_v?process_id=eq.${procC.id}`,
    `/rest/v1/audit_events?process_id=eq.${procC.id}`,
  ]) {
    const dRead = await httpJson(`${env.apiUrl}${endpoint}`, { headers: clientHeaders(studentD.token) });
    assert.equal(dRead.status, 200);
    assert.equal(dRead.data.length, 0, `Estudante D não pode ler ${endpoint}`);

    const r4Read = await httpJson(`${env.apiUrl}${endpoint}`, { headers: clientHeaders(reviewerR4.token) });
    assert.equal(r4Read.status, 200);
    assert.equal(r4Read.data.length, 0, `Revisor R4 sem escopo não pode ler ${endpoint}`);
  }

  const r3ProcC = await httpJson(`${env.apiUrl}/rest/v1/internship_processes?id=eq.${procC.id}`, {
    headers: clientHeaders(reviewerR3.token),
  });
  assert.equal(r3ProcC.data.length, 1, 'Revisor R3 vê processo em seu escopo');

  const r3OutOfScope = await httpJson(`${env.apiUrl}/rest/v1/internship_processes?id=eq.${procOptId}`, {
    headers: clientHeaders(reviewerR3.token),
  });
  assert.equal(r3OutOfScope.data.length, 0, 'Revisor R3 não vê processo fora do escopo por ID');

  // 8) Publicar v2 em catMain e confirmar que D abre com v2 sem alterar o snapshot v1 de C
  const archV1 = await httpJson(`${env.apiUrl}/rest/v1/requirement_templates?id=eq.${catMain.templateId}`, {
    method: 'PATCH',
    headers: serviceHeaders,
    body: { status: 'archived' },
  });
  assert.equal(archV1.ok, true, `Erro arquivando v1: ${sanitizeHttpSummary(archV1)}`);

  const pubV2 = await httpJson(`${env.apiUrl}/rest/v1/requirement_templates?id=eq.${tplV2Id}`, {
    method: 'PATCH',
    headers: serviceHeaders,
    body: { status: 'published' },
  });
  assert.equal(pubV2.ok, true, `Erro publicando v2: ${sanitizeHttpSummary(pubV2)}`);

  const openV2ForD = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentD.token),
    body: { p_course_modality_id: catMain.modalityId },
  });
  assert.equal(openV2ForD.status, 200, `Erro abrindo v2 para D: ${sanitizeHttpSummary(openV2ForD)}`);
  assert.equal(openV2ForD.data.template_id, tplV2Id);
  assert.equal(openV2ForD.data.template_version, 2);

  const procDReqs = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${openV2ForD.data.id}&order=display_order.asc`,
    { headers: clientHeaders(studentD.token) },
  );
  assert.equal(procDReqs.data.length, 1);
  assert.equal(procDReqs.data[0].code, `L2_V2_OBR1_${runId}`);

  // Validar que o processo e snapshot v1 de C permaneceram inalterados
  const procCReqsAfterV2 = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${procC.id}&order=display_order.asc`,
    { headers: clientHeaders(studentC.token) },
  );
  assert.equal(procCReqsAfterV2.data.length, 3);
  assert.deepEqual(
    procCReqsAfterV2.data.map((r) => [r.display_order, r.code, r.title, r.is_required]),
    [
      [1, `L2_OBR1_${runId}`, '[Demo L2] Termo Obrigatório 1 v1', true],
      [2, `L2_OBR2_${runId}`, '[Demo L2] Plano Obrigatório 2 v1', true],
      [3, `L2_OPC3_${runId}`, '[Demo L2] Documento Opcional 3 v1', false],
    ],
  );

  console.log('✓ Lote 2 (ESP-10/11/12): Catálogo, RPC create_internship_process, snapshot v1/v2, concorrência e isolamento RLS validados');
}

function apiUrlOr(url) {
  return url;
}

main();
