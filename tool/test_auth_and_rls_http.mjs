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
import zlib from 'node:zlib';

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

    // ========================================================================
    // LOTE 3 (ESP-13 / ESP-14 / ESP-15): Storage privado, Edge Upload e Versões
    // ========================================================================
    await runLote3StorageAndSubmissionScenarios({
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

function buildValidMinimalPdfBytes(labelText = 'Estagio Sem Pendencia Demo PDF') {
  const safeLabel = labelText.replace(/[()\\]/g, ' ');
  const streamContent = `BT\n/F1 12 Tf\n72 720 Td\n(${safeLabel}) Tj\nET\n`;
  const objects = [
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n',
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n',
    `4 0 obj\n<< /Length ${Buffer.byteLength(streamContent, 'latin1')} >>\nstream\n${streamContent}endstream\nendobj\n`,
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  ];

  const chunks = ['%PDF-1.4\n'];
  const offsets = [0];
  let byteOffset = Buffer.byteLength(chunks[0], 'latin1');

  for (const obj of objects) {
    offsets.push(byteOffset);
    chunks.push(obj);
    byteOffset += Buffer.byteLength(obj, 'latin1');
  }

  const xrefOffset = byteOffset;
  let xref = `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (let i = 1; i < offsets.length; i++) {
    xref += `${String(offsets[i]).padStart(10, '0')} 00000 n \n`;
  }

  const trailer = `${xref}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`;
  chunks.push(trailer);
  return Buffer.from(chunks.join(''), 'latin1');
}

function buildSolTruncated142PdfBytes() {
  const header = '%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  const trailer = 'xref\n0 2\ntrailer\n<< /Size 2 /Root 1 0 R >>\nstartxref\n999999999\n%%EOF\n';
  const baseLen = Buffer.byteLength(header + trailer, 'latin1');
  const padLen = Math.max(0, 142 - baseLen);
  const commentPad = padLen >= 2 ? `%${' '.repeat(padLen - 2)}\n` : '';
  return Buffer.from(header + commentPad + trailer, 'latin1');
}

function buildFakeInBoundsStartxrefPdfBytes() {
  return Buffer.from(
    '%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n' +
      '2 0 obj\n<< /Type /Pages /Count 0 >>\nendobj\nstartxref\n9\n%%EOF\n',
    'latin1',
  );
}

function buildValidXrefStreamPdfBytes(labelText = 'Estagio PDF 1.5 XRef Stream') {
  const safeLabel = labelText.replace(/[()\\]/g, ' ');
  const streamContent = `BT\n/F1 12 Tf\n72 720 Td\n(${safeLabel}) Tj\nET\n`;
  const objects = [
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n',
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n',
    `4 0 obj\n<< /Length ${Buffer.byteLength(streamContent, 'latin1')} >>\nstream\n${streamContent}endstream\nendobj\n`,
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  ];

  const chunks = [Buffer.from('%PDF-1.5\n', 'latin1')];
  const offsets = [0];
  let byteOffset = chunks[0].byteLength;

  for (const obj of objects) {
    offsets.push(byteOffset);
    const buf = Buffer.from(obj, 'latin1');
    chunks.push(buf);
    byteOffset += buf.byteLength;
  }

  const xrefStreamOffset = byteOffset;
  offsets.push(xrefStreamOffset);

  const xrefEntries = Buffer.alloc(offsets.length * 4);
  // Entrada 0: objeto livre
  xrefEntries[0] = 0;
  xrefEntries[1] = 0;
  xrefEntries[2] = 0;
  xrefEntries[3] = 255;
  for (let i = 1; i < offsets.length; i++) {
    const off = offsets[i];
    const base = i * 4;
    xrefEntries[base] = 1;
    xrefEntries[base + 1] = (off >> 8) & 0xff;
    xrefEntries[base + 2] = off & 0xff;
    xrefEntries[base + 3] = 0;
  }

  const xrefHeader = Buffer.from(
    `6 0 obj\n<< /Type /XRef /Size ${offsets.length} /Root 1 0 R /W [1 2 1] /Length ${xrefEntries.byteLength} >>\nstream\n`,
    'latin1',
  );
  const xrefFooter = Buffer.from(
    `\nendstream\nendobj\nstartxref\n${xrefStreamOffset}\n%%EOF\n`,
    'latin1',
  );

  return Buffer.concat([...chunks, xrefHeader, xrefEntries, xrefFooter]);
}

function buildC303R1MissingStreamXrefPdfBytes() {
  const obj1 = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  const obj2Body = 'BT /F1 12 Tf 72 720 Td (Objeto stream anterior isolado) Tj ET';
  const obj2 = `2 0 obj\n<< /Length ${Buffer.byteLength(obj2Body, 'latin1')} >>\nstream\n${obj2Body}\nendstream\nendobj\n`;
  const prefix = `%PDF-1.5\n${obj1}${obj2}`;
  const xrefObjOffset = Buffer.byteLength(prefix, 'latin1');
  const fakeXrefObj =
    '3 0 obj\n<< /Type /XRef /Size 4 /Root 1 0 R /W [1 2 1] /Length 28 >>\nendobj\n';
  return Buffer.from(`${prefix}${fakeXrefObj}startxref\n${xrefObjOffset}\n%%EOF\n`, 'latin1');
}

function buildC303R2IncompleteStreamXrefPdfBytes({ withTrailingPadding = false } = {}) {
  const prefix = '%PDF-1.5\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  const xrefObjOffset = Buffer.byteLength(prefix, 'latin1');
  const shortData = Buffer.alloc(10, 0x41);
  const padComment = withTrailingPadding ? `%${' '.repeat(48)}\n` : '';
  return Buffer.concat([
    Buffer.from(
      `${prefix}2 0 obj\n<< /Type /XRef /Size 3 /Root 1 0 R /W [1 2 1] /Length 28 >>\nstream\n`,
      'latin1',
    ),
    shortData,
    Buffer.from(`\nendstream\nendobj\n${padComment}startxref\n${xrefObjOffset}\n%%EOF\n`, 'latin1'),
  ]);
}

function buildC303R3MissingEndstreamXrefPdfBytes({ lateEndstream = false } = {}) {
  const prefix = '%PDF-1.5\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  const xrefObjOffset = Buffer.byteLength(prefix, 'latin1');
  const data28 = Buffer.alloc(28, 0x01);
  const tail = lateEndstream
    ? '\nEXTRA_DESALINHADO\nendstream\nendobj\n'
    : '\nendobj\n';
  return Buffer.concat([
    Buffer.from(
      `${prefix}2 0 obj\n<< /Type /XRef /Size 3 /Root 1 0 R /W [1 2 1] /Length 28 >>\nstream\n`,
      'latin1',
    ),
    data28,
    Buffer.from(`${tail}startxref\n${xrefObjOffset}\n%%EOF\n`, 'latin1'),
  ]);
}

function buildC303IndirectLengthXrefPdfBytes() {
  const obj1 = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  const obj2 = '2 0 obj\n28\nendobj\n';
  const prefix = `%PDF-1.5\n${obj1}${obj2}`;
  const xrefObjOffset = Buffer.byteLength(prefix, 'latin1');
  const data28 = Buffer.alloc(28, 0x02);
  return Buffer.concat([
    Buffer.from(
      `${prefix}3 0 obj\n<< /Type /XRef /Size 4 /Root 1 0 R /W [1 2 1] /Length 2 0 R >>\nstream\n`,
      'latin1',
    ),
    data28,
    Buffer.from(`\nendstream\nendobj\nstartxref\n${xrefObjOffset}\n%%EOF\n`, 'latin1'),
  ]);
}

function buildValidFlateXrefStreamPdfBytes(labelText = 'Estagio PDF 1.5 FlateDecode XRef') {
  const safeLabel = labelText.replace(/[()\\]/g, ' ');
  const streamContent = `BT\n/F1 12 Tf\n72 720 Td\n(${safeLabel}) Tj\nET\n`;
  const objects = [
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n',
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n',
    `4 0 obj\n<< /Length ${Buffer.byteLength(streamContent, 'latin1')} >>\nstream\n${streamContent}endstream\nendobj\n`,
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  ];

  const chunks = [Buffer.from('%PDF-1.5\n', 'latin1')];
  const offsets = [0];
  let byteOffset = chunks[0].byteLength;

  for (const obj of objects) {
    offsets.push(byteOffset);
    const buf = Buffer.from(obj, 'latin1');
    chunks.push(buf);
    byteOffset += buf.byteLength;
  }

  const xrefStreamOffset = byteOffset;
  offsets.push(xrefStreamOffset);

  const rawEntries = Buffer.alloc(offsets.length * 4);
  rawEntries[0] = 0;
  rawEntries[1] = 0;
  rawEntries[2] = 0;
  rawEntries[3] = 255;
  for (let i = 1; i < offsets.length; i++) {
    const off = offsets[i];
    const base = i * 4;
    rawEntries[base] = 1;
    rawEntries[base + 1] = (off >> 8) & 0xff;
    rawEntries[base + 2] = off & 0xff;
    rawEntries[base + 3] = 0;
  }

  const compressed = zlib.deflateSync(rawEntries);
  const xrefHeader = Buffer.from(
    `6 0 obj<</DecodeParms<</Columns 4/Predictor 1>>/Filter/FlateDecode/Length ${compressed.byteLength}/Root 1 0 R/Size ${offsets.length}/Type/XRef/W[1 2 1]>>stream\r\n`,
    'latin1',
  );
  const xrefFooter = Buffer.from(
    `\r\nendstream\r\nendobj\r\nstartxref\r\n${xrefStreamOffset}\r\n%%EOF\r\n`,
    'latin1',
  );

  return Buffer.concat([...chunks, xrefHeader, compressed, xrefFooter]);
}

async function httpEdgeSubmitPdf({
  apiUrl,
  anonKey,
  token,
  processRequirementId,
  idempotencyKey,
  fileBytes,
  filename = 'documento.pdf',
  mimeType = 'application/pdf',
  signal,
}) {
  const formData = new FormData();
  if (processRequirementId !== undefined && processRequirementId !== null) {
    formData.append('process_requirement_id', processRequirementId);
  }
  if (idempotencyKey) {
    formData.append('idempotency_key', idempotencyKey);
  }
  if (fileBytes !== null && fileBytes !== undefined) {
    const blob = new Blob([fileBytes], { type: mimeType });
    formData.append('file', blob, filename);
  }

  const headers = {
    apikey: anonKey,
  };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const response = await fetch(`${apiUrl}/functions/v1/submit-requirement-pdf`, {
    method: 'POST',
    headers,
    body: formData,
    signal,
  });

  const text = await response.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { raw: text };
  }

  return {
    ok: response.ok,
    status: response.status,
    data,
    text,
  };
}

async function httpRawBytes(url, { method = 'GET', headers = {}, body } = {}) {
  const response = await fetch(url, { method, headers, body });
  const arrayBuffer = await response.arrayBuffer();
  const buffer = Buffer.from(arrayBuffer);
  return {
    ok: response.ok,
    status: response.status,
    headers: response.headers,
    buffer,
    text: buffer.toString('utf8'),
  };
}

function encodeStoragePathSegments(storagePath) {
  return storagePath
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
}

async function runLote3StorageAndSubmissionScenarios({
  env,
  runId,
  clientHeaders,
  serviceHeaders,
  sensitivePool,
}) {
  const passE = `DemoE!${crypto.randomBytes(8).toString('hex')}`;
  const passF = `DemoF!${crypto.randomBytes(8).toString('hex')}`;
  const passR5 = `DemoR5!${crypto.randomBytes(8).toString('hex')}`;
  const passR6 = `DemoR6!${crypto.randomBytes(8).toString('hex')}`;

  const studentE = await createConfirmedAdminUser(env.apiUrl, serviceHeaders, clientHeaders, env.anonKey, sensitivePool, {
    email: `estudante.e.l3.${runId}@demo.local`,
    password: passE,
    fullName: 'Estudante E Lote 3 HTTP',
  });
  const studentF = await createConfirmedAdminUser(env.apiUrl, serviceHeaders, clientHeaders, env.anonKey, sensitivePool, {
    email: `estudante.f.l3.${runId}@demo.local`,
    password: passF,
    fullName: 'Estudante F Lote 3 HTTP',
  });
  const reviewerR5 = await createConfirmedAdminUser(env.apiUrl, serviceHeaders, clientHeaders, env.anonKey, sensitivePool, {
    email: `revisor.r5.l3.${runId}@demo.local`,
    password: passR5,
    fullName: 'Revisor R5 Atribuido Lote 3 HTTP',
  });
  const reviewerR6 = await createConfirmedAdminUser(env.apiUrl, serviceHeaders, clientHeaders, env.anonKey, sensitivePool, {
    email: `revisor.r6.l3.${runId}@demo.local`,
    password: passR6,
    fullName: 'Revisor R6 Sem Escopo Lote 3 HTTP',
  });

  for (const rev of [reviewerR5, reviewerR6]) {
    const promote = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_set_user_role`, {
      method: 'POST',
      headers: serviceHeaders,
      body: {
        p_user_id: rev.id,
        p_new_role: 'reviewer',
        p_operator_type: OPERATOR_TYPE,
        p_operator_identifier: OPERATOR_IDENTIFIER,
        p_reason: 'Provisionamento Lote 3 HTTP',
      },
    });
    assert.equal(promote.status, 200, `Erro promovendo revisor L3: ${sanitizeHttpSummary(promote)}`);
  }

  const catA = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `L3_A_${runId}`,
    templateStatus: 'published',
    items: [
      {
        code: `L3_TCE_${runId}`,
        title: '[Demo L3] Termo de Compromisso',
        description: 'Enviar TCE assinado',
        acceptanceCriteria: 'PDF válido',
        isRequired: true,
        displayOrder: 1,
      },
      {
        code: `L3_PAE_${runId}`,
        title: '[Demo L3] Plano Opcional',
        description: 'Enviar plano opcional',
        acceptanceCriteria: 'PDF válido',
        isRequired: false,
        displayOrder: 2,
      },
    ],
  });

  const catOther = await createIsolatedCatalogRecord(env.apiUrl, serviceHeaders, {
    suffix: `L3_B_${runId}`,
    templateStatus: 'published',
    items: [
      {
        code: `L3_OTHER_${runId}`,
        title: '[Demo L3] Outro Documento',
        description: 'Outro requisito',
        acceptanceCriteria: 'PDF válido',
        isRequired: true,
        displayOrder: 1,
      },
    ],
  });

  // Atribuir R5 apenas a catA e R6 apenas a catOther
  const assignR5 = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_assign_reviewer_scope`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_reviewer_id: reviewerR5.id,
      p_institution_id: catA.institutionId,
      p_course_id: catA.courseId,
      p_course_modality_id: catA.modalityId,
      p_operator_type: OPERATOR_TYPE,
      p_operator_identifier: OPERATOR_IDENTIFIER,
      p_reason: 'Escopo L3 para R5',
    },
  });
  assert.equal(assignR5.status, 200, `Erro atribuindo R5: ${sanitizeHttpSummary(assignR5)}`);
  const r5AssignmentId = assignR5.data.id;

  const assignR6 = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_assign_reviewer_scope`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_reviewer_id: reviewerR6.id,
      p_institution_id: catOther.institutionId,
      p_course_id: catOther.courseId,
      p_course_modality_id: catOther.modalityId,
      p_operator_type: OPERATOR_TYPE,
      p_operator_identifier: OPERATOR_IDENTIFIER,
      p_reason: 'Escopo L3 para R6',
    },
  });
  assert.equal(assignR6.status, 200, `Erro atribuindo R6: ${sanitizeHttpSummary(assignR6)}`);

  // Abrir processos para Estudante E e Estudante F na modalidade catA
  const openE = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentE.token),
    body: { p_course_modality_id: catA.modalityId },
  });
  assert.equal(openE.status, 200, `Erro abrindo processo E L3: ${sanitizeHttpSummary(openE)}`);
  const procEId = openE.data.id;

  const openF = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentF.token),
    body: { p_course_modality_id: catA.modalityId },
  });
  assert.equal(openF.status, 200, `Erro abrindo processo F L3: ${sanitizeHttpSummary(openF)}`);
  const procFId = openF.data.id;

  const reqsERes = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${procEId}&order=display_order.asc`,
    { headers: clientHeaders(studentE.token) },
  );
  assert.equal(reqsERes.status, 200);
  assert.equal(reqsERes.data.length, 2);
  const reqEReq = reqsERes.data[0];
  const reqEOpt = reqsERes.data[1];

  const reqsFRes = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${procFId}&order=display_order.asc`,
    { headers: clientHeaders(studentF.token) },
  );
  assert.equal(reqsFRes.status, 200);
  const reqFReq = reqsFRes.data[0];
  const reqFOpt = reqsFRes.data[1];

  // 1) CORS OPTIONS preflight (Flutter Web) e verificação do bucket privado
  const corsPreflight = await fetch(`${env.apiUrl}/functions/v1/submit-requirement-pdf`, {
    method: 'OPTIONS',
    headers: {
      Origin: 'http://localhost:8080',
      'Access-Control-Request-Method': 'POST',
      'Access-Control-Request-Headers': 'authorization, apikey, content-type',
    },
  });
  assert.ok(
    corsPreflight.status === 200 || corsPreflight.status === 204,
    `Preflight OPTIONS na Edge Function devia retornar 200 ou 204 (recebido ${corsPreflight.status})`,
  );
  assert.equal(corsPreflight.headers.get('access-control-allow-origin'), '*');

  const bucketInfo = await httpJson(`${env.apiUrl}/storage/v1/bucket/internship-documents`, {
    headers: serviceHeaders,
  });
  assert.equal(bucketInfo.status, 200, `Bucket internship-documents ausente: ${sanitizeHttpSummary(bucketInfo)}`);
  assert.equal(bucketInfo.data.public, false, 'Bucket internship-documents precisa ter public = false');

  // 2) Anônimo e JWT inválido/expirado/revogado rejeitados na Edge Function
  const pdfV1Bytes = buildValidMinimalPdfBytes(`TCE Versao 1 ${runId}`);
  const pdfV1Sha256 = crypto.createHash('sha256').update(pdfV1Bytes).digest('hex');

  const anonEdgeAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: null,
    processRequirementId: reqEReq.id,
    fileBytes: pdfV1Bytes,
  });
  assert.equal(anonEdgeAttempt.status, 401, `Envio anônimo devia retornar 401: ${anonEdgeAttempt.status}`);

  const badJwtAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: 'invalid.jwt.token',
    processRequirementId: reqEReq.id,
    fileBytes: pdfV1Bytes,
  });
  assert.equal(badJwtAttempt.status, 401, `JWT inválido devia retornar 401: ${badJwtAttempt.status}`);

  // 3) Validações negativas de arquivo antes de gravar Storage ou banco
  const emptyPdfAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: Buffer.alloc(0),
    filename: 'vazio.pdf',
  });
  assert.equal(emptyPdfAttempt.status, 400);
  assert.equal(emptyPdfAttempt.data?.error?.code, 'empty_file');

  const txtRenamedAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: Buffer.from('Conteudo texto simples disfarçado de PDF com mais de 64 bytes para testar assinatura.', 'utf8'),
    filename: 'disfarce_txt.pdf',
    mimeType: 'application/pdf',
  });
  assert.equal(txtRenamedAttempt.status, 422);
  assert.equal(txtRenamedAttempt.data?.error?.code, 'invalid_pdf_signature');

  const pngBytes = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    Buffer.alloc(128, 0x41),
  ]);
  const pngRenamedAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: pngBytes,
    filename: 'imagem_falsa.pdf',
    mimeType: 'application/pdf',
  });
  assert.equal(pngRenamedAttempt.status, 422);
  assert.equal(pngRenamedAttempt.data?.error?.code, 'invalid_pdf_signature');

  const wrongMimeAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: pdfV1Bytes,
    filename: 'valido_mas_mime_errado.pdf',
    mimeType: 'image/png',
  });
  assert.equal(wrongMimeAttempt.status, 415);
  assert.equal(wrongMimeAttempt.data?.error?.code, 'unsupported_media_type');

  const wrongExtAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: pdfV1Bytes,
    filename: 'contrato.txt',
    mimeType: 'application/pdf',
  });
  assert.equal(wrongExtAttempt.status, 400);
  assert.equal(wrongExtAttempt.data?.error?.code, 'invalid_file_extension');

  const truncatedPdfAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: pdfV1Bytes.subarray(0, pdfV1Bytes.length - 25),
    filename: 'truncado.pdf',
  });
  assert.equal(truncatedPdfAttempt.status, 422);
  assert.equal(truncatedPdfAttempt.data?.error?.code, 'truncated_or_corrupted_pdf');

  // Regressão C3-03: arquivo inválido de 142 bytes com startxref=999999999 e ponteiro falso rejeitados antes do Storage/banco
  const solTruncated142 = buildSolTruncated142PdfBytes();
  assert.equal(solTruncated142.byteLength, 142);
  const solTruncatedAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: solTruncated142,
    filename: 'repro_sol_142b_startxref_invalido.pdf',
  });
  assert.equal(
    solTruncatedAttempt.status,
    422,
    `PDF de 142 bytes com startxref=999999999 devia retornar 422 (recebido ${solTruncatedAttempt.status}: ${solTruncatedAttempt.text})`,
  );
  assert.equal(solTruncatedAttempt.data?.error?.code, 'truncated_or_corrupted_pdf');

  const fakeInBoundsAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: buildFakeInBoundsStartxrefPdfBytes(),
    filename: 'startxref_apontando_para_obj.pdf',
  });
  assert.equal(fakeInBoundsAttempt.status, 422);
  assert.equal(fakeInBoundsAttempt.data?.error?.code, 'truncated_or_corrupted_pdf');

  const oversizedPdfBytes = Buffer.concat([
    pdfV1Bytes,
    Buffer.alloc(5 * 1024 * 1024 + 128, 0x20),
  ]);
  const oversizedAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: oversizedPdfBytes,
    filename: 'muito_grande.pdf',
  });
  assert.equal(oversizedAttempt.status, 413);
  assert.equal(oversizedAttempt.data?.error?.code, 'file_too_large');

  // Rejeição de outro estudante (Estudante F tentando enviar para requisito de Estudante E)
  const crossStudentSubmit = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentF.token,
    processRequirementId: reqEReq.id,
    fileBytes: pdfV1Bytes,
    filename: 'invasao.pdf',
  });
  assert.equal(crossStudentSubmit.status, 403);
  assert.equal(crossStudentSubmit.data?.error?.code, 'forbidden_owner');

  // Rejeição de revisor tentando submeter no lugar do estudante
  const reviewerSubmit = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: reviewerR5.token,
    processRequirementId: reqEReq.id,
    fileBytes: pdfV1Bytes,
    filename: 'revisor.pdf',
  });
  assert.equal(reviewerSubmit.status, 403);
  assert.equal(reviewerSubmit.data?.error?.code, 'forbidden_role');

  // Bloquear escrita direta pelo cliente no Storage e PostgREST
  const directStorageWrite = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/internship-documents/direct/${runId}.pdf`,
    {
      method: 'POST',
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentE.token}`,
        'Content-Type': 'application/pdf',
      },
      body: pdfV1Bytes,
    },
  );
  assert.equal(directStorageWrite.ok, false, `Upload direto ao Storage devia falhar: HTTP ${directStorageWrite.status}`);

  const directDbInsert = await httpJson(`${env.apiUrl}/rest/v1/document_submissions`, {
    method: 'POST',
    headers: clientHeaders(studentE.token),
    body: {
      process_id: procEId,
      process_requirement_id: reqEReq.id,
      submitted_by: studentE.id,
      version: 1,
      storage_path: `bypass/${runId}.pdf`,
      mime_type: 'application/pdf',
      size_bytes: pdfV1Bytes.byteLength,
    },
  });
  assert.equal(directDbInsert.ok, false, 'INSERT direto em document_submissions pelo cliente deve ser bloqueado');

  // Confirmar zero submissões antes do primeiro envio válido
  const preSubsCheck = await httpJson(
    `${env.apiUrl}/rest/v1/document_submissions?process_requirement_id=eq.${reqEReq.id}`,
    { headers: clientHeaders(studentE.token) },
  );
  assert.equal(preSubsCheck.data.length, 0);

  // 4) Envio válido v1 com idempotency_key via Edge Function + caminho opaco sem PII
  const idemV1Key = crypto.randomUUID();
  const submitV1 = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    idempotencyKey: idemV1Key,
    fileBytes: pdfV1Bytes,
    filename: 'C:\\fakepath\\Estudante_E_CPF123_Termo.pdf',
  });
  assert.equal(submitV1.status, 201, `Upload v1 válido falhou: HTTP ${submitV1.status} ${submitV1.text}`);
  assert.equal(submitV1.data.ok, true);
  assert.equal(submitV1.data.idempotent_replay, false);
  const subV1 = submitV1.data.submission;
  assert.equal(subV1.version, 1);
  assert.equal(subV1.status, 'under_review');
  assert.equal(subV1.sha256_checksum, pdfV1Sha256);
  assert.equal(subV1.size_bytes, pdfV1Bytes.byteLength);
  assert.equal(subV1.storage_bucket, 'internship-documents');
  assert.equal(subV1.original_filename, 'Estudante_E_CPF123_Termo.pdf');
  assert.match(
    subV1.storage_path,
    new RegExp(`^processes/${procEId}/requirements/${reqEReq.id}/submissions/[0-9a-f-]{36}\\.pdf$`),
  );
  assert.equal(subV1.storage_path.toLowerCase().includes('estudante'), false);
  assert.equal(subV1.storage_path.toLowerCase().includes('cpf'), false);
  assert.equal(subV1.storage_path.toLowerCase().includes('demo.local'), false);

  // 5) Retry idempotente não cria v2 nem duplica objeto; mesma chave com outro payload falha (409)
  const retryV1 = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    idempotencyKey: idemV1Key,
    fileBytes: pdfV1Bytes,
    filename: 'Estudante_E_CPF123_Termo.pdf',
  });
  assert.equal(retryV1.status, 200, `Retry idempotente devia retornar 200: ${retryV1.status} ${retryV1.text}`);
  assert.equal(retryV1.data.idempotent_replay, true);
  assert.equal(retryV1.data.submission.id, subV1.id);
  assert.equal(retryV1.data.submission.storage_path, subV1.storage_path);

  const mismatchIdem = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    idempotencyKey: idemV1Key,
    fileBytes: buildValidMinimalPdfBytes(`Outro Conteudo ${runId}`),
    filename: 'outro.pdf',
  });
  assert.equal(mismatchIdem.status, 409);
  assert.equal(mismatchIdem.data?.error?.code, 'idempotency_mismatch');

  // Novo envio sem reabrir para correção deve falhar enquanto under_review
  const dupWhileUnderReview = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    idempotencyKey: crypto.randomUUID(),
    fileBytes: buildValidMinimalPdfBytes(`Tentativa Bloqueada ${runId}`),
    filename: 'novo.pdf',
  });
  assert.equal(dupWhileUnderReview.status, 409);
  assert.equal(dupWhileUnderReview.data?.error?.code, 'requirement_status_conflict');

  // 6) Controle de acesso ao Storage privado (URL pública, anon, dono, outro estudante, R5, R6 e revogação R5)
  const encodedV1Path = encodeStoragePathSegments(subV1.storage_path);

  const publicUrlRead = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/public/internship-documents/${encodedV1Path}`,
  );
  assert.equal(publicUrlRead.ok, false, `Bucket privado nunca pode responder via URL pública (${publicUrlRead.status})`);

  const anonStorageRead = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodedV1Path}`,
    { headers: { apikey: env.anonKey } },
  );
  assert.equal(anonStorageRead.ok, false, `Anon não pode baixar PDF privado (${anonStorageRead.status})`);

  // Dono E baixa via endpoint padrão do storage_client (/object/<bucket>/<path>) e /object/authenticated/
  const ownerDownload = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/internship-documents/${encodedV1Path}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentE.token}`,
      },
    },
  );
  assert.equal(ownerDownload.status, 200, `Estudante dono E devia baixar v1: HTTP ${ownerDownload.status}`);
  assert.equal(Buffer.compare(ownerDownload.buffer, pdfV1Bytes), 0, 'Bytes baixados pelo dono devem ser idênticos aos enviados');

  const ownerAuthDownload = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodedV1Path}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentE.token}`,
      },
    },
  );
  assert.equal(ownerAuthDownload.status, 200, `Estudante dono E devia baixar v1 via /authenticated/: HTTP ${ownerAuthDownload.status}`);
  assert.equal(Buffer.compare(ownerAuthDownload.buffer, pdfV1Bytes), 0);

  // Regressão C3-01: usuários comuns (inclusive dono e revisor atribuído) NÃO podem gerar URLs assinadas
  const ownerSignRes = await httpJson(
    `${env.apiUrl}/storage/v1/object/sign/internship-documents/${encodedV1Path}`,
    {
      method: 'POST',
      headers: clientHeaders(studentE.token),
      body: { expiresIn: 315360000 },
    },
  );
  assert.equal(
    ownerSignRes.ok,
    false,
    `Dono authenticated não pode gerar signed URL (recebido ${ownerSignRes.status}: ${ownerSignRes.text})`,
  );

  const ownerSignManyRes = await httpJson(
    `${env.apiUrl}/storage/v1/object/sign/internship-documents`,
    {
      method: 'POST',
      headers: clientHeaders(studentE.token),
      body: { expiresIn: 315360000, paths: [subV1.storage_path] },
    },
  );
  assert.equal(
    !ownerSignManyRes.ok ||
      (Array.isArray(ownerSignManyRes.data) &&
        ownerSignManyRes.data.every((item) => item && item.signedURL === null && Boolean(item.error))),
    true,
    `Dono authenticated não pode obter signed URL em lote (recebido ${ownerSignManyRes.status}: ${ownerSignManyRes.text})`,
  );

  // Estudante F mesmo conhecendo storage_path exato é bloqueado no download e no sign
  const otherStudentDownload = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodedV1Path}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentF.token}`,
      },
    },
  );
  assert.equal(otherStudentDownload.ok, false, `Estudante F não pode baixar PDF de E (${otherStudentDownload.status})`);

  const otherStudentSign = await httpJson(
    `${env.apiUrl}/storage/v1/object/sign/internship-documents/${encodedV1Path}`,
    {
      method: 'POST',
      headers: clientHeaders(studentF.token),
      body: { expiresIn: 60 },
    },
  );
  assert.equal(otherStudentSign.ok, false, 'Estudante F não pode gerar signedURL para PDF de E');

  // Revisor R5 no escopo lê PDF v1 autenticado, mas é proibido de gerar signed URL (10 anos ou 60s)
  const r5SignRes = await httpJson(
    `${env.apiUrl}/storage/v1/object/sign/internship-documents/${encodedV1Path}`,
    {
      method: 'POST',
      headers: clientHeaders(reviewerR5.token),
      body: { expiresIn: 315360000 },
    },
  );
  assert.equal(
    r5SignRes.ok,
    false,
    `Revisor R5 não pode emitir signed URL de longa duração (${r5SignRes.status}: ${r5SignRes.text})`,
  );

  const r5SignManyRes = await httpJson(
    `${env.apiUrl}/storage/v1/object/sign/internship-documents`,
    {
      method: 'POST',
      headers: clientHeaders(reviewerR5.token),
      body: { expiresIn: 315360000, paths: [subV1.storage_path] },
    },
  );
  assert.equal(
    !r5SignManyRes.ok ||
      (Array.isArray(r5SignManyRes.data) &&
        r5SignManyRes.data.every((item) => item && item.signedURL === null && Boolean(item.error))),
    true,
    `Revisor R5 não pode obter signed URL em lote (recebido ${r5SignManyRes.status}: ${r5SignManyRes.text})`,
  );

  const r5Download = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodedV1Path}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${reviewerR5.token}`,
      },
    },
  );
  assert.equal(r5Download.status, 200, `Revisor atribuído R5 devia baixar PDF v1 (${r5Download.status})`);
  assert.equal(Buffer.compare(r5Download.buffer, pdfV1Bytes), 0);

  const r6Download = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodedV1Path}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${reviewerR6.token}`,
      },
    },
  );
  assert.equal(r6Download.ok, false, `Revisor sem assignment no escopo R6 não pode baixar PDF v1 (${r6Download.status})`);

  // Revogar assignment de R5 bloqueia novos acessos autenticados e sign imediatamente
  const revokeR5 = await httpJson(`${env.apiUrl}/rest/v1/rpc/admin_revoke_reviewer_assignment`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_assignment_id: r5AssignmentId,
      p_operator_type: OPERATOR_TYPE,
      p_operator_identifier: OPERATOR_IDENTIFIER,
      p_reason: 'Teste de bloqueio imediato após revogação L3',
    },
  });
  assert.equal(revokeR5.status, 200, `Erro revogando assignment R5: ${sanitizeHttpSummary(revokeR5)}`);

  const r5DownloadAfterRevoke = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodedV1Path}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${reviewerR5.token}`,
      },
    },
  );
  assert.equal(
    r5DownloadAfterRevoke.ok,
    false,
    `Revisor R5 após revogação deve ser bloqueado imediatamente (${r5DownloadAfterRevoke.status})`,
  );

  const r5DownloadDirectAfterRevoke = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/internship-documents/${encodedV1Path}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${reviewerR5.token}`,
      },
    },
  );
  assert.equal(
    r5DownloadDirectAfterRevoke.ok,
    false,
    `Revisor R5 após revogação não pode baixar nem por /object/ (${r5DownloadDirectAfterRevoke.status})`,
  );

  // 7) Concorrência HTTP real em requisito de F (Promise.all): apenas 1 sucesso, 1 conflito, órfão limpo
  const concPdf1 = buildValidMinimalPdfBytes(`Concorrente 1 ${runId}`);
  const concPdf2 = buildValidMinimalPdfBytes(`Concorrente 2 ${runId}`);
  const [concSubmit1, concSubmit2] = await Promise.all([
    httpEdgeSubmitPdf({
      apiUrl: env.apiUrl,
      anonKey: env.anonKey,
      token: studentF.token,
      processRequirementId: reqFReq.id,
      idempotencyKey: crypto.randomUUID(),
      fileBytes: concPdf1,
      filename: 'conc1.pdf',
    }),
    httpEdgeSubmitPdf({
      apiUrl: env.apiUrl,
      anonKey: env.anonKey,
      token: studentF.token,
      processRequirementId: reqFReq.id,
      idempotencyKey: crypto.randomUUID(),
      fileBytes: concPdf2,
      filename: 'conc2.pdf',
    }),
  ]);

  const concResponses = [concSubmit1, concSubmit2];
  const concWins = concResponses.filter((r) => r.status === 201);
  const concLosses = concResponses.filter((r) => r.status === 409);
  assert.equal(
    concWins.length,
    1,
    `Concorrência devia gerar exatamente 1 submissão 201 (${concResponses.map((r) => `${r.status}:${r.data?.error?.code}`).join(' | ')})`,
  );
  assert.equal(
    concLosses.length,
    1,
    `Concorrência devia rejeitar exatamente 1 tentativa com 409 (${concResponses.map((r) => `${r.status}:${r.data?.error?.code}`).join(' | ')})`,
  );

  const reqFSubs = await httpJson(
    `${env.apiUrl}/rest/v1/document_submissions?process_requirement_id=eq.${reqFReq.id}&order=version.desc`,
    { headers: clientHeaders(studentF.token) },
  );
  assert.equal(reqFSubs.data.length, 1);
  assert.equal(reqFSubs.data[0].version, 1);

  const reqFIntents = await httpJson(
    `${env.apiUrl}/rest/v1/document_submission_intents?process_requirement_id=eq.${reqFReq.id}`,
    { headers: serviceHeaders },
  );
  assert.equal(reqFIntents.status, 200);
  assert.equal(
    reqFIntents.data.some((i) => i.status === 'uploading' || i.status === 'orphan_cleanup_pending'),
    false,
    'Nenhuma intenção concorrente deve permanecer pendente ou órfã sem compensação',
  );

  const listReqFObjects = await httpJson(`${env.apiUrl}/storage/v1/object/list/internship-documents`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      prefix: `processes/${procFId}/requirements/${reqFReq.id}/submissions/`,
      limit: 20,
      offset: 0,
    },
  });
  assert.equal(listReqFObjects.status, 200);
  assert.equal(
    listReqFObjects.data.length,
    1,
    `Storage do requisito concorrente deve manter apenas o único objeto vencedor (encontrados ${listReqFObjects.data.length})`,
  );

  // 8) Compensação segura de objeto órfão após falha pós-upload sem tocar submissões persistidas
  const orphanPdfBytes = buildValidMinimalPdfBytes(`Orfao Simulado ${runId}`);
  const orphanSha = crypto.createHash('sha256').update(orphanPdfBytes).digest('hex');
  const prepOrphan = await httpJson(`${env.apiUrl}/rest/v1/rpc/prepare_document_submission`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_actor_id: studentE.id,
      p_process_requirement_id: reqEOpt.id,
      p_idempotency_key: crypto.randomUUID(),
      p_original_filename: 'orfao_pos_upload.pdf',
      p_size_bytes: orphanPdfBytes.byteLength,
      p_sha256_checksum: orphanSha,
      p_max_size_bytes: 5242880,
    },
  });
  assert.equal(prepOrphan.status, 200, `Erro preparando intent órfão: ${sanitizeHttpSummary(prepOrphan)}`);
  const orphanIntentId = prepOrphan.data.intent_id;
  const orphanPath = prepOrphan.data.storage_path;
  const encodedOrphanPath = encodeStoragePathSegments(orphanPath);

  const orphanUpload = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/internship-documents/${encodedOrphanPath}`,
    {
      method: 'POST',
      headers: {
        apikey: env.serviceRoleKey,
        Authorization: `Bearer ${env.serviceRoleKey}`,
        'Content-Type': 'application/pdf',
        'x-upsert': 'false',
      },
      body: orphanPdfBytes,
    },
  );
  assert.equal(orphanUpload.status, 200, `Upload do órfão ao Storage falhou: HTTP ${orphanUpload.status}`);

  // Simular cancelamento do processo F/requisito ou alterar status para causar falha no finalize_document_submission
  const orphanCleanupPrep = await httpJson(`${env.apiUrl}/rest/v1/rpc/prepare_submission_orphan_cleanup`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_intent_id: orphanIntentId,
      p_error_code: 'simulated_commit_failure',
      p_error_detail: 'Simulação de erro após upload no Storage',
    },
  });
  assert.equal(orphanCleanupPrep.status, 200);
  assert.equal(orphanCleanupPrep.data.safe_to_delete, true);

  const deleteOrphan = await httpJson(`${env.apiUrl}/storage/v1/object/internship-documents`, {
    method: 'DELETE',
    headers: serviceHeaders,
    body: { prefixes: [orphanPath] },
  });
  assert.equal(deleteOrphan.status, 200, `Exclusão de objeto órfão falhou: ${sanitizeHttpSummary(deleteOrphan)}`);

  const finishOrphanComp = await httpJson(`${env.apiUrl}/rest/v1/rpc/compensate_document_submission_intent`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_intent_id: orphanIntentId,
      p_outcome_status: 'orphan_cleaned',
      p_error_code: 'simulated_commit_failure',
      p_error_detail: 'Objeto órfão removido com segurança',
    },
  });
  assert.equal(finishOrphanComp.status, 200);
  assert.equal(finishOrphanComp.data.status, 'orphan_cleaned');

  const verifyOrphanGone = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodedOrphanPath}`,
    {
      headers: {
        apikey: env.serviceRoleKey,
        Authorization: `Bearer ${env.serviceRoleKey}`,
      },
    },
  );
  assert.equal(verifyOrphanGone.ok, false, 'Objeto órfão compensado não deve mais existir no Storage');

  // Confirmar que submissão v1 de reqEReq continua intacta no Storage e banco
  const checkV1StillIntact = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodedV1Path}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentE.token}`,
      },
    },
  );
  assert.equal(checkV1StillIntact.status, 200);
  assert.equal(Buffer.compare(checkV1StillIntact.buffer, pdfV1Bytes), 0);

  // 9) ESP-15: Reenvio após correction_requested gera v2 preservando v1 e ordem version DESC
  const revForCorrection = await httpJson(`${env.apiUrl}/rest/v1/document_reviews`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      process_id: procEId,
      process_requirement_id: reqEReq.id,
      submission_id: subV1.id,
      reviewer_id: reviewerR5.id,
      decision: 'correction_requested',
      reason: 'Documento ilegivel na segunda página (fixture HTTP L3).',
    },
  });
  assert.equal(revForCorrection.status, 201, `Erro criando fixture document_reviews: ${sanitizeHttpSummary(revForCorrection)}`);

  const patchSubCorr = await httpJson(`${env.apiUrl}/rest/v1/document_submissions?id=eq.${subV1.id}`, {
    method: 'PATCH',
    headers: serviceHeaders,
    body: { status: 'correction_requested' },
  });
  assert.equal(patchSubCorr.ok, true);

  const patchReqCorr = await httpJson(`${env.apiUrl}/rest/v1/process_requirements?id=eq.${reqEReq.id}`, {
    method: 'PATCH',
    headers: serviceHeaders,
    body: { status: 'correction_requested' },
  });
  assert.equal(patchReqCorr.ok, true);

  const pdfV2Bytes = buildValidMinimalPdfBytes(`TCE Corrigido Versao 2 ${runId}`);
  const submitV2 = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    idempotencyKey: crypto.randomUUID(),
    fileBytes: pdfV2Bytes,
    filename: 'termo_v2_corrigido.pdf',
  });
  assert.equal(submitV2.status, 201, `Reenvio v2 falhou: HTTP ${submitV2.status} ${submitV2.text}`);
  const subV2 = submitV2.data.submission;
  assert.equal(subV2.version, 2);
  assert.equal(subV2.status, 'under_review');
  assert.notEqual(subV2.storage_path, subV1.storage_path);
  assert.equal(submitV2.data.requirement.current_version, 2);
  assert.equal(submitV2.data.requirement.current_submission_id, subV2.id);

  // Histórico ordenado do mais recente para o mais antigo e download independente das duas versões
  const historyRes = await httpJson(
    `${env.apiUrl}/rest/v1/document_submissions?process_requirement_id=eq.${reqEReq.id}&order=version.desc`,
    { headers: clientHeaders(studentE.token) },
  );
  assert.equal(historyRes.status, 200);
  assert.equal(historyRes.data.length, 2);
  assert.deepEqual(
    historyRes.data.map((row) => [row.version, row.status]),
    [
      [2, 'under_review'],
      [1, 'correction_requested'],
    ],
  );

  const downloadV1AfterV2 = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodeStoragePathSegments(subV1.storage_path)}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentE.token}`,
      },
    },
  );
  const downloadV2AfterV2 = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodeStoragePathSegments(subV2.storage_path)}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentE.token}`,
      },
    },
  );
  assert.equal(Buffer.compare(downloadV1AfterV2.buffer, pdfV1Bytes), 0, 'Histórico v1 deve permanecer intacto após envio v2');
  assert.equal(Buffer.compare(downloadV2AfterV2.buffer, pdfV2Bytes), 0, 'Arquivo v2 deve estar acessível com bytes exatos');

  // 10) Requisito aprovado bloqueia novo envio e sessão após logout é rejeitada pela Edge Function
  const revApprove = await httpJson(`${env.apiUrl}/rest/v1/document_reviews`, {
    method: 'POST',
    headers: { ...serviceHeaders, Prefer: 'return=representation' },
    body: {
      process_id: procEId,
      process_requirement_id: reqEReq.id,
      submission_id: subV2.id,
      reviewer_id: reviewerR5.id,
      decision: 'approved',
      reason: null,
    },
  });
  assert.equal(revApprove.status, 201);

  const patchSubApp = await httpJson(`${env.apiUrl}/rest/v1/document_submissions?id=eq.${subV2.id}`, {
    method: 'PATCH',
    headers: serviceHeaders,
    body: { status: 'approved' },
  });
  assert.equal(patchSubApp.ok, true);

  const patchReqApp = await httpJson(`${env.apiUrl}/rest/v1/process_requirements?id=eq.${reqEReq.id}`, {
    method: 'PATCH',
    headers: serviceHeaders,
    body: { status: 'approved' },
  });
  assert.equal(patchReqApp.ok, true);

  const submitAfterApproved = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEReq.id,
    fileBytes: buildValidMinimalPdfBytes('Pos Aprovacao'),
    filename: 'pos_aprovacao.pdf',
  });
  assert.equal(submitAfterApproved.status, 409);
  assert.equal(submitAfterApproved.data?.error?.code, 'requirement_status_conflict');

  const logoutE = await httpJson(`${env.apiUrl}/auth/v1/logout?scope=global`, {
    method: 'POST',
    headers: clientHeaders(studentE.token),
  });
  assert.equal(logoutE.status, 204);

  const submitAfterLogout = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentE.token,
    processRequirementId: reqEOpt.id,
    fileBytes: buildValidMinimalPdfBytes('Pos Logout'),
    filename: 'pos_logout.pdf',
  });
  assert.equal(submitAfterLogout.status, 401, `Sessão revogada após logout deve ser rejeitada pela Edge Function (${submitAfterLogout.status})`);

  // 11) Regressões Gate C3: PDF 1.5+ Cross-Reference Stream (C3-03) e recuperação/concorrência de 'uploading' (C3-02)
  // 11a) PDF 1.5+ legítimo com Cross-Reference Stream (/Type /XRef) aceito com 201 e bytes preservados
  const xrefStreamPdf = buildValidXrefStreamPdfBytes(`XRef Stream Valido ${runId}`);
  const xrefSubmitRes = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentF.token,
    processRequirementId: reqFOpt.id,
    idempotencyKey: crypto.randomUUID(),
    fileBytes: xrefStreamPdf,
    filename: 'documento_pdf15_xref_stream.pdf',
  });
  assert.equal(
    xrefSubmitRes.status,
    201,
    `PDF 1.5+ válido com /Type /XRef stream devia retornar 201 (recebido ${xrefSubmitRes.status}: ${xrefSubmitRes.text})`,
  );
  const xrefDownload = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodeStoragePathSegments(xrefSubmitRes.data.submission.storage_path)}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentF.token}`,
      },
    },
  );
  assert.equal(xrefDownload.status, 200);
  assert.equal(Buffer.compare(xrefDownload.buffer, xrefStreamPdf), 0);

  // Provisionar estudante isolado de recuperação para cenários determinísticos C3-02
  const studentRecovery = await createConfirmedAdminUser(
    env.apiUrl,
    serviceHeaders,
    clientHeaders,
    env.anonKey,
    sensitivePool,
    {
      email: `estudante.rec.c3.${runId}@demo.local`,
      password: `DemoRec!${crypto.randomBytes(8).toString('hex')}`,
      fullName: 'Estudante Recuperacao C3',
    },
  );
  const openRecA = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentRecovery.token),
    body: { p_course_modality_id: catA.modalityId },
  });
  assert.equal(openRecA.status, 200);
  const recAReqsRes = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${openRecA.data.id}&order=display_order.asc`,
    { headers: clientHeaders(studentRecovery.token) },
  );
  assert.equal(recAReqsRes.data.length, 2);
  const reqRecLostPrep = recAReqsRes.data[0];
  const reqRecPostUpload = recAReqsRes.data[1];

  const openRecOther = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentRecovery.token),
    body: { p_course_modality_id: catOther.modalityId },
  });
  assert.equal(openRecOther.status, 200);
  const recOtherReqsRes = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${openRecOther.data.id}&order=display_order.asc`,
    { headers: clientHeaders(studentRecovery.token) },
  );
  const reqRecActiveRelease = recOtherReqsRes.data[0];

  const openFOther = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentF.token),
    body: { p_course_modality_id: catOther.modalityId },
  });
  assert.equal(openFOther.status, 200);
  const fOtherReqsRes = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${openFOther.data.id}&order=display_order.asc`,
    { headers: clientHeaders(studentF.token) },
  );
  const reqFConcurrentRec = fOtherReqsRes.data[0];

  // 11b) C3-02: Perda de resposta após preparação (intent 'uploading' expirado sem objeto no Storage) -> retry recupera 201
  const lostPrepPdf = buildValidMinimalPdfBytes(`Recuperacao Lost Prep ${runId}`);
  const lostPrepSha = crypto.createHash('sha256').update(lostPrepPdf).digest('hex');
  const lostPrepKey = crypto.randomUUID();
  const prepLost = await httpJson(`${env.apiUrl}/rest/v1/rpc/prepare_document_submission`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_actor_id: studentRecovery.id,
      p_process_requirement_id: reqRecLostPrep.id,
      p_idempotency_key: lostPrepKey,
      p_original_filename: 'lost_prep.pdf',
      p_size_bytes: lostPrepPdf.byteLength,
      p_sha256_checksum: lostPrepSha,
      p_max_size_bytes: 5242880,
      p_lease_ttl_seconds: 0,
    },
  });
  assert.equal(prepLost.status, 200, `Falha preparando fixture lost_prep: ${sanitizeHttpSummary(prepLost)}`);

  const retryLostPrep = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentRecovery.token,
    processRequirementId: reqRecLostPrep.id,
    idempotencyKey: lostPrepKey,
    fileBytes: lostPrepPdf,
    filename: 'lost_prep.pdf',
  });
  assert.equal(
    retryLostPrep.status,
    201,
    `Retry após perda de resposta pós-prepare devia retornar 201 (recebido ${retryLostPrep.status}: ${retryLostPrep.text})`,
  );
  assert.equal(retryLostPrep.data.submission.version, 1);

  // 11c) C3-02: Falha de transporte pós-upload no Storage (intent 'uploading' expirado COM objeto íntegro -> ready_to_finalize)
  const postUploadPdf = buildValidMinimalPdfBytes(`Recuperacao Post Upload ${runId}`);
  const postUploadSha = crypto.createHash('sha256').update(postUploadPdf).digest('hex');
  const postUploadKey = crypto.randomUUID();
  const prepPostUpload = await httpJson(`${env.apiUrl}/rest/v1/rpc/prepare_document_submission`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_actor_id: studentRecovery.id,
      p_process_requirement_id: reqRecPostUpload.id,
      p_idempotency_key: postUploadKey,
      p_original_filename: 'post_upload_recover.pdf',
      p_size_bytes: postUploadPdf.byteLength,
      p_sha256_checksum: postUploadSha,
      p_max_size_bytes: 5242880,
      p_lease_ttl_seconds: 0,
    },
  });
  assert.equal(prepPostUpload.status, 200);
  const interruptedPath = prepPostUpload.data.storage_path;
  const uploadInterruptedObj = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/internship-documents/${encodeStoragePathSegments(interruptedPath)}`,
    {
      method: 'POST',
      headers: {
        apikey: env.serviceRoleKey,
        Authorization: `Bearer ${env.serviceRoleKey}`,
        'Content-Type': 'application/pdf',
        'x-upsert': 'false',
      },
      body: postUploadPdf,
    },
  );
  assert.equal(uploadInterruptedObj.status, 200);

  const retryPostUpload = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentRecovery.token,
    processRequirementId: reqRecPostUpload.id,
    idempotencyKey: postUploadKey,
    fileBytes: postUploadPdf,
    filename: 'post_upload_recover.pdf',
  });
  assert.equal(
    retryPostUpload.status,
    201,
    `Retomada pós-upload no Storage devia finalizar em 201 sem re-upload (recebido ${retryPostUpload.status}: ${retryPostUpload.text})`,
  );
  assert.equal(retryPostUpload.data.submission.storage_path, interruptedPath);
  assert.equal(retryPostUpload.data.submission.version, 1);

  const replayPostUpload = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentRecovery.token,
    processRequirementId: reqRecPostUpload.id,
    idempotencyKey: postUploadKey,
    fileBytes: postUploadPdf,
    filename: 'post_upload_recover.pdf',
  });
  assert.equal(replayPostUpload.status, 200);
  assert.equal(replayPostUpload.data.idempotent_replay, true);
  assert.equal(replayPostUpload.data.submission.id, retryPostUpload.data.submission.id);

  // 11d) C3-02: Diferenciação operação ativa (409) vs liberação por falha de transporte + AbortController
  const activeLeasePdf = buildValidMinimalPdfBytes(`Active Lease Release ${runId}`);
  const activeLeaseSha = crypto.createHash('sha256').update(activeLeasePdf).digest('hex');
  const activeLeaseKey = crypto.randomUUID();
  const prepActiveLease = await httpJson(`${env.apiUrl}/rest/v1/rpc/prepare_document_submission`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_actor_id: studentRecovery.id,
      p_process_requirement_id: reqRecActiveRelease.id,
      p_idempotency_key: activeLeaseKey,
      p_original_filename: 'active_lease.pdf',
      p_size_bytes: activeLeasePdf.byteLength,
      p_sha256_checksum: activeLeaseSha,
      p_max_size_bytes: 5242880,
      p_lease_ttl_seconds: 30,
    },
  });
  assert.equal(prepActiveLease.status, 200);

  const conflictWhileLeaseActive = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentRecovery.token,
    processRequirementId: reqRecActiveRelease.id,
    idempotencyKey: activeLeaseKey,
    fileBytes: activeLeasePdf,
    filename: 'active_lease.pdf',
  });
  assert.equal(conflictWhileLeaseActive.status, 409);
  assert.equal(conflictWhileLeaseActive.data?.error?.code, 'submission_in_progress');

  // Simular liberação explícita executada pela Edge Function no catch de transporte/abort
  const releaseActiveAttempt = await httpJson(`${env.apiUrl}/rest/v1/rpc/release_document_submission_attempt`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_intent_id: prepActiveLease.data.intent_id,
      p_lease_token: prepActiveLease.data.lease_token,
      p_error_code: 'storage_upload_transport_error',
      p_error_detail: 'Falha simulada de transporte HTTP',
    },
  });
  assert.equal(releaseActiveAttempt.status, 200);
  assert.equal(releaseActiveAttempt.data.action, 'aborted_no_object');

  // Disparar AbortController real na Edge Function e recuperar imediatamente na tentativa seguinte
  const abortController = new AbortController();
  const abortPromise = httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentRecovery.token,
    processRequirementId: reqRecActiveRelease.id,
    idempotencyKey: activeLeaseKey,
    fileBytes: activeLeasePdf,
    filename: 'active_lease.pdf',
    signal: abortController.signal,
  }).catch((err) => ({ aborted: true, name: err?.name }));
  abortController.abort();
  await abortPromise;
  await new Promise((resolve) => setTimeout(resolve, 100));

  const retryAfterAbort = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentRecovery.token,
    processRequirementId: reqRecActiveRelease.id,
    idempotencyKey: activeLeaseKey,
    fileBytes: activeLeasePdf,
    filename: 'active_lease.pdf',
  });
  assert.ok(
    retryAfterAbort.status === 201 || retryAfterAbort.status === 200,
    `Retry após falha de transporte/abort não pode ficar preso em 409 (recebido ${retryAfterAbort.status}: ${retryAfterAbort.text})`,
  );
  assert.equal(retryAfterAbort.data.submission.version, 1);

  // 11e) C3-02: Retry concorrente (Promise.all) em intenção interrompida não gera duas versões nem dois objetos
  const concRecPdf = buildValidMinimalPdfBytes(`Retry Concorrente C3 ${runId}`);
  const concRecSha = crypto.createHash('sha256').update(concRecPdf).digest('hex');
  const concRecKey = crypto.randomUUID();
  const prepConcRec = await httpJson(`${env.apiUrl}/rest/v1/rpc/prepare_document_submission`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      p_actor_id: studentF.id,
      p_process_requirement_id: reqFConcurrentRec.id,
      p_idempotency_key: concRecKey,
      p_original_filename: 'conc_recovery.pdf',
      p_size_bytes: concRecPdf.byteLength,
      p_sha256_checksum: concRecSha,
      p_max_size_bytes: 5242880,
      p_lease_ttl_seconds: 0,
    },
  });
  assert.equal(prepConcRec.status, 200);
  const concRecStorageUpload = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/internship-documents/${encodeStoragePathSegments(prepConcRec.data.storage_path)}`,
    {
      method: 'POST',
      headers: {
        apikey: env.serviceRoleKey,
        Authorization: `Bearer ${env.serviceRoleKey}`,
        'Content-Type': 'application/pdf',
        'x-upsert': 'false',
      },
      body: concRecPdf,
    },
  );
  assert.equal(concRecStorageUpload.status, 200);

  const [concRecA, concRecB] = await Promise.all([
    httpEdgeSubmitPdf({
      apiUrl: env.apiUrl,
      anonKey: env.anonKey,
      token: studentF.token,
      processRequirementId: reqFConcurrentRec.id,
      idempotencyKey: concRecKey,
      fileBytes: concRecPdf,
      filename: 'conc_recovery.pdf',
    }),
    httpEdgeSubmitPdf({
      apiUrl: env.apiUrl,
      anonKey: env.anonKey,
      token: studentF.token,
      processRequirementId: reqFConcurrentRec.id,
      idempotencyKey: concRecKey,
      fileBytes: concRecPdf,
      filename: 'conc_recovery.pdf',
    }),
  ]);
  const concRecPair = [concRecA, concRecB];
  const concRecCreated = concRecPair.filter((r) => r.status === 201);
  assert.equal(
    concRecCreated.length,
    1,
    `Retomada concorrente devia criar exatamente 1 v1 (201), obtido: ${concRecPair.map((r) => `${r.status}:${r.data?.error?.code}`).join(' | ')}`,
  );
  const concRecOther = concRecPair.find((r) => r.status !== 201);
  assert.ok(
    concRecOther.status === 200 || concRecOther.status === 409,
    `Segundo retry concorrente devia receber replay 200 ou conflito de lease ativo 409 (obtido ${concRecOther.status}: ${concRecOther.text})`,
  );

  const concRecSubs = await httpJson(
    `${env.apiUrl}/rest/v1/document_submissions?process_requirement_id=eq.${reqFConcurrentRec.id}`,
    { headers: clientHeaders(studentF.token) },
  );
  assert.equal(concRecSubs.data.length, 1);
  assert.equal(concRecSubs.data[0].version, 1);

  const concRecObjs = await httpJson(`${env.apiUrl}/storage/v1/object/list/internship-documents`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      prefix: `processes/${openFOther.data.id}/requirements/${reqFConcurrentRec.id}/submissions/`,
      limit: 20,
      offset: 0,
    },
  });
  assert.equal(concRecObjs.data.length, 1);

  // 12) Regressões Gate B3-R2 (C3-03 — R1 a R6 em fixtures completamente isoladas)
  const studentC303 = await createConfirmedAdminUser(
    env.apiUrl,
    serviceHeaders,
    clientHeaders,
    env.anonKey,
    sensitivePool,
    {
      email: `estudante.c303.${runId}@demo.local`,
      password: `DemoC303!${crypto.randomBytes(8).toString('hex')}`,
      fullName: 'Estudante Gate B3 R2 C303',
    },
  );
  const studentC303Flate = await createConfirmedAdminUser(
    env.apiUrl,
    serviceHeaders,
    clientHeaders,
    env.anonKey,
    sensitivePool,
    {
      email: `estudante.c303.flate.${runId}@demo.local`,
      password: `DemoFlate!${crypto.randomBytes(8).toString('hex')}`,
      fullName: 'Estudante Gate B3 R2 Flate',
    },
  );

  const openC303A = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentC303.token),
    body: { p_course_modality_id: catA.modalityId },
  });
  assert.equal(openC303A.status, 200);
  const procC303AId = openC303A.data.id;
  const reqsC303ARes = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${procC303AId}&order=display_order.asc`,
    { headers: clientHeaders(studentC303.token) },
  );
  assert.equal(reqsC303ARes.data.length, 2);
  const reqC303Neg = reqsC303ARes.data[0];
  const reqC303Classic = reqsC303ARes.data[1];

  const openC303B = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentC303.token),
    body: { p_course_modality_id: catOther.modalityId },
  });
  assert.equal(openC303B.status, 200);
  const procC303BId = openC303B.data.id;
  const reqsC303BRes = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${procC303BId}&order=display_order.asc`,
    { headers: clientHeaders(studentC303.token) },
  );
  const reqC303Xref = reqsC303BRes.data[0];

  const openC303Flate = await httpJson(`${env.apiUrl}/rest/v1/rpc/create_internship_process`, {
    method: 'POST',
    headers: clientHeaders(studentC303Flate.token),
    body: { p_course_modality_id: catOther.modalityId },
  });
  assert.equal(openC303Flate.status, 200);
  const reqsC303FlateRes = await httpJson(
    `${env.apiUrl}/rest/v1/process_requirements?process_id=eq.${openC303Flate.data.id}&order=display_order.asc`,
    { headers: clientHeaders(studentC303Flate.token) },
  );
  const reqC303Flate = reqsC303FlateRes.data[0];

  // Confirmar isolamento absoluto antes de R1, R2 e R3
  const negInitialObjects = await httpJson(`${env.apiUrl}/storage/v1/object/list/internship-documents`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      prefix: `processes/${procC303AId}/requirements/${reqC303Neg.id}/submissions/`,
      limit: 20,
      offset: 0,
    },
  });
  assert.equal(negInitialObjects.status, 200);
  assert.equal(negInitialObjects.data.length, 0);

  // R1 — Dicionário /Type /XRef, /Length 28, sem stream correspondente -> HTTP 422
  const r1Attempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentC303.token,
    processRequirementId: reqC303Neg.id,
    idempotencyKey: crypto.randomUUID(),
    fileBytes: buildC303R1MissingStreamXrefPdfBytes(),
    filename: `r1_sem_stream_${runId}.pdf`,
  });
  assert.equal(r1Attempt.status, 422, `R1 devia retornar 422 (obtido ${r1Attempt.status}: ${r1Attempt.text})`);
  assert.equal(r1Attempt.data?.error?.code, 'truncated_or_corrupted_pdf');

  // R2 — Stream incompleto (menos bytes do que /Length 28 declarado) -> HTTP 422
  for (const [label, bytes] of [
    ['curto_direto', buildC303R2IncompleteStreamXrefPdfBytes({ withTrailingPadding: false })],
    ['curto_com_padding', buildC303R2IncompleteStreamXrefPdfBytes({ withTrailingPadding: true })],
  ]) {
    const r2Attempt = await httpEdgeSubmitPdf({
      apiUrl: env.apiUrl,
      anonKey: env.anonKey,
      token: studentC303.token,
      processRequirementId: reqC303Neg.id,
      idempotencyKey: crypto.randomUUID(),
      fileBytes: bytes,
      filename: `r2_incompleto_${label}_${runId}.pdf`,
    });
    assert.equal(
      r2Attempt.status,
      422,
      `R2 (${label}) devia retornar 422 (obtido ${r2Attempt.status}: ${r2Attempt.text})`,
    );
    assert.equal(r2Attempt.data?.error?.code, 'truncated_or_corrupted_pdf');
  }

  // R3 — Delimitador endstream ausente/desalinhado + /Length indireto não verificável -> HTTP 422
  for (const [label, bytes] of [
    ['sem_endstream', buildC303R3MissingEndstreamXrefPdfBytes({ lateEndstream: false })],
    ['endstream_desalinhado', buildC303R3MissingEndstreamXrefPdfBytes({ lateEndstream: true })],
    ['length_indireto', buildC303IndirectLengthXrefPdfBytes()],
  ]) {
    const r3Attempt = await httpEdgeSubmitPdf({
      apiUrl: env.apiUrl,
      anonKey: env.anonKey,
      token: studentC303.token,
      processRequirementId: reqC303Neg.id,
      idempotencyKey: crypto.randomUUID(),
      fileBytes: bytes,
      filename: `r3_${label}_${runId}.pdf`,
    });
    assert.equal(
      r3Attempt.status,
      422,
      `R3 (${label}) devia retornar 422 (obtido ${r3Attempt.status}: ${r3Attempt.text})`,
    );
    assert.equal(r3Attempt.data?.error?.code, 'truncated_or_corrupted_pdf');
  }

  // Verificar ausência total de submissões, intents e objetos novos no Storage após R1/R2/R3
  const negAfterSubs = await httpJson(
    `${env.apiUrl}/rest/v1/document_submissions?process_requirement_id=eq.${reqC303Neg.id}`,
    { headers: serviceHeaders },
  );
  assert.equal(negAfterSubs.status, 200);
  assert.equal(negAfterSubs.data.length, 0, 'R1/R2/R3 não podem gerar nenhuma submissão no banco');

  const negAfterIntents = await httpJson(
    `${env.apiUrl}/rest/v1/document_submission_intents?process_requirement_id=eq.${reqC303Neg.id}`,
    { headers: serviceHeaders },
  );
  assert.equal(negAfterIntents.status, 200);
  assert.equal(negAfterIntents.data.length, 0, 'R1/R2/R3 devem rejeitar antes mesmo de abrir intent no banco');

  const negAfterObjects = await httpJson(`${env.apiUrl}/storage/v1/object/list/internship-documents`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      prefix: `processes/${procC303AId}/requirements/${reqC303Neg.id}/submissions/`,
      limit: 20,
      offset: 0,
    },
  });
  assert.equal(negAfterObjects.status, 200);
  assert.equal(negAfterObjects.data.length, 0, 'R1/R2/R3 não podem gravar nenhum objeto no Storage');

  // R4 — PDF clássico válido -> HTTP 201 + download autorizado 200
  const r4Pdf = buildValidMinimalPdfBytes(`R4 Classico Valido ${runId}`);
  const r4IdemKey = crypto.randomUUID();
  const r4Attempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentC303.token,
    processRequirementId: reqC303Classic.id,
    idempotencyKey: r4IdemKey,
    fileBytes: r4Pdf,
    filename: `r4_classico_${runId}.pdf`,
  });
  assert.equal(r4Attempt.status, 201, `R4 devia retornar 201 (obtido ${r4Attempt.status}: ${r4Attempt.text})`);
  assert.equal(r4Attempt.data.idempotent_replay, false);
  const r4Download = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodeStoragePathSegments(r4Attempt.data.submission.storage_path)}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentC303.token}`,
      },
    },
  );
  assert.equal(r4Download.status, 200);
  assert.equal(Buffer.compare(r4Download.buffer, r4Pdf), 0);

  // R6 — Regressão de idempotência: replay com mesma chave retorna HTTP 200 sem criar v2 ou segundo objeto
  const r6Replay = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentC303.token,
    processRequirementId: reqC303Classic.id,
    idempotencyKey: r4IdemKey,
    fileBytes: r4Pdf,
    filename: `r4_classico_${runId}.pdf`,
  });
  assert.equal(r6Replay.status, 200, `R6 devia retornar 200 (obtido ${r6Replay.status}: ${r6Replay.text})`);
  assert.equal(r6Replay.data.idempotent_replay, true);
  assert.equal(r6Replay.data.submission.id, r4Attempt.data.submission.id);
  assert.equal(r6Replay.data.submission.version, 1);

  const r6Subs = await httpJson(
    `${env.apiUrl}/rest/v1/document_submissions?process_requirement_id=eq.${reqC303Classic.id}`,
    { headers: clientHeaders(studentC303.token) },
  );
  assert.equal(r6Subs.data.length, 1);
  const r6Objects = await httpJson(`${env.apiUrl}/storage/v1/object/list/internship-documents`, {
    method: 'POST',
    headers: serviceHeaders,
    body: {
      prefix: `processes/${procC303AId}/requirements/${reqC303Classic.id}/submissions/`,
      limit: 20,
      offset: 0,
    },
  });
  assert.equal(r6Objects.data.length, 1);

  // R5 — PDF 1.5+ válido com Cross-Reference Stream (binário bruto e comprimido FlateDecode) -> HTTP 201 + download exato
  const r5RawPdf = buildValidXrefStreamPdfBytes(`R5 Binario Valido ${runId}`);
  const r5RawAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentC303.token,
    processRequirementId: reqC303Xref.id,
    idempotencyKey: crypto.randomUUID(),
    fileBytes: r5RawPdf,
    filename: `r5_xref_raw_${runId}.pdf`,
  });
  assert.equal(r5RawAttempt.status, 201, `R5 (raw) devia retornar 201 (obtido ${r5RawAttempt.status}: ${r5RawAttempt.text})`);
  const r5RawDownload = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodeStoragePathSegments(r5RawAttempt.data.submission.storage_path)}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentC303.token}`,
      },
    },
  );
  assert.equal(r5RawDownload.status, 200);
  assert.equal(Buffer.compare(r5RawDownload.buffer, r5RawPdf), 0);

  const r5FlatePdf = buildValidFlateXrefStreamPdfBytes(`R5 FlateDecode Compacto ${runId}`);
  const r5FlateAttempt = await httpEdgeSubmitPdf({
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    token: studentC303Flate.token,
    processRequirementId: reqC303Flate.id,
    idempotencyKey: crypto.randomUUID(),
    fileBytes: r5FlatePdf,
    filename: `r5_xref_flate_${runId}.pdf`,
  });
  assert.equal(
    r5FlateAttempt.status,
    201,
    `R5 (FlateDecode) devia retornar 201 (obtido ${r5FlateAttempt.status}: ${r5FlateAttempt.text})`,
  );
  const r5FlateDownload = await httpRawBytes(
    `${env.apiUrl}/storage/v1/object/authenticated/internship-documents/${encodeStoragePathSegments(r5FlateAttempt.data.submission.storage_path)}`,
    {
      headers: {
        apikey: env.anonKey,
        Authorization: `Bearer ${studentC303Flate.token}`,
      },
    },
  );
  assert.equal(r5FlateDownload.status, 200);
  assert.equal(Buffer.compare(r5FlateDownload.buffer, r5FlatePdf), 0);

  console.log('✓ Gate B3-R2 (C3-03 — R1 a R6): XRef stream sem stream/incompleto/sem endstream rejeitados com 422 sem artefatos; clássico, XRef binário/FlateDecode 201 e replay 200 validados');
  console.log('✓ Lote 3 (ESP-13/14/15 + Gate C3-R1): Storage privado, bloqueio de signed URL para authenticated, recuperação de uploading, startxref estrito e versões v1/v2 validados');
}

function apiUrlOr(url) {
  return url;
}

main();
