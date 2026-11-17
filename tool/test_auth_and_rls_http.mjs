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

    console.log('\nTODOS OS CENÁRIOS HTTP/AUTH/RLS E HARDENING PASSARAM COM SUCESSO.');
  } catch (err) {
    const safeMessage = redactKnownSecrets(err?.message ?? String(err), sensitivePool);
    console.error(`\n[FALHA NO TESTE HTTP]: ${safeMessage}`);
    process.exit(1);
  }
}

function apiUrlOr(url) {
  return url;
}

main();
