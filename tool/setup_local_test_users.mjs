#!/usr/bin/env node
/**
 * Procedimento isolado para preparar contas fictícias locais (ESP-08 / ESP-09):
 * - Estudante A (papel: student)
 * - Estudante B (papel: student)
 * - Revisor R1 (papel: reviewer, atribuído ao catálogo demo inicial)
 * - Revisor R2 (papel: reviewer, sem atribuição de escopo)
 *
 * Segurança:
 * - Opera exclusivamente em instância local (127.0.0.1 / localhost / 10.0.2.2).
 * - Não armazena senhas nem chaves administrativas no repositório nem em arquivos locais.
 * - Mantém credenciais exclusivamente em memória via --ephemeral ou LOCAL_TEST_USER_PASSWORD.
 * - Rejeita --password, --password= e --password-out antes de qualquer conexão.
 * - Não imprime senhas, tokens, argumentos sensíveis ou chaves em logs/stdout/stderr.
 * - Utiliza o contrato auditável de operador `local_demo_provisioning`.
 */

import { execFileSync, execSync } from 'node:child_process';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const DEMO_INSTITUTION_ID = '10000000-0000-4000-8000-000000000001';
const DEMO_COURSE_ID = '20000000-0000-4000-8000-000000000001';
const DEMO_MODALITY_ID = '30000000-0000-4000-8000-000000000001';
const OPERATOR_TYPE = 'local_demo_provisioning';
const OPERATOR_IDENTIFIER = 'tool/setup_local_test_users.mjs';

const DISABLED_PASSWORD_ARG_MESSAGE =
  'Opção --password desabilitada por segurança. Utilize --ephemeral ou LOCAL_TEST_USER_PASSWORD.';
const DISABLED_PASSWORD_OUT_MESSAGE =
  'A opção --password-out foi removida por segurança: credenciais fictícias locais são mantidas apenas em memória (sem persistência em disco). Use LOCAL_TEST_USER_PASSWORD no ambiente ou --ephemeral.';
const UNSUPPORTED_ARG_MESSAGE =
  'Argumento de linha de comando não suportado por segurança. Utilize apenas --ephemeral, --self-test ou LOCAL_TEST_USER_PASSWORD.';

function parseArgs(argv) {
  const result = {
    ephemeral: false,
    selfTest: false,
  };
  for (const arg of argv) {
    if (arg === '--ephemeral') {
      result.ephemeral = true;
    } else if (arg === '--self-test') {
      result.selfTest = true;
    } else if (arg === '--password' || arg.startsWith('--password=')) {
      throw new Error(DISABLED_PASSWORD_ARG_MESSAGE);
    } else if (arg === '--password-out' || arg.startsWith('--password-out=')) {
      throw new Error(DISABLED_PASSWORD_OUT_MESSAGE);
    } else {
      // Mensagem fixa: nunca ecoa o argumento completo nem valores passados na CLI.
      throw new Error(UNSUPPORTED_ARG_MESSAGE);
    }
  }
  return result;
}

function buildSanitizedSubprocessEnv(baseEnv = process.env) {
  const sanitized = {};
  for (const [key, value] of Object.entries(baseEnv ?? {})) {
    if (key.toUpperCase() === 'LOCAL_TEST_USER_PASSWORD') {
      continue;
    }
    sanitized[key] = value;
  }
  return sanitized;
}

function getLocalSupabaseConfig(env = process.env) {
  const envUrl = env.SUPABASE_URL;
  const envServiceKey = env.SUPABASE_SERVICE_ROLE_KEY;
  if (envUrl && envServiceKey) {
    return {
      apiUrl: envUrl.replace(/\/$/, ''),
      serviceRoleKey: envServiceKey,
    };
  }

  const raw = execSync('npx supabase status -o json', {
    encoding: 'utf8',
    env: buildSanitizedSubprocessEnv(env),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const jsonStart = raw.indexOf('{');
  if (jsonStart === -1) {
    throw new Error('Saída inválida de `npx supabase status -o json`.');
  }
  const parsed = JSON.parse(raw.slice(jsonStart));
  if (!parsed.API_URL || !parsed.SERVICE_ROLE_KEY) {
    throw new Error('Supabase local não está ativo ou não retornou API_URL/SERVICE_ROLE_KEY.');
  }
  return {
    apiUrl: parsed.API_URL.replace(/\/$/, ''),
    serviceRoleKey: parsed.SERVICE_ROLE_KEY,
  };
}

function assertLocalhostOnly(apiUrl) {
  const parsed = new URL(apiUrl);
  const allowedHosts = new Set(['127.0.0.1', 'localhost', '10.0.2.2']);
  if (!allowedHosts.has(parsed.hostname)) {
    throw new Error(
      `Operação recusada: URL não local (${parsed.hostname}). Este script só pode rodar em ambiente local descartável.`,
    );
  }
}

async function apiRequest(baseUrl, reqPath, { method = 'GET', serviceRoleKey, body } = {}) {
  const response = await fetch(`${baseUrl}${reqPath}`, {
    method,
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/json',
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
  if (!response.ok) {
    const safeCode = json?.code ?? json?.error_code ?? json?.error ?? 'unknown_error';
    throw new Error(`HTTP ${response.status} em ${method} ${reqPath} (${safeCode})`);
  }
  return json;
}

function generateEphemeralPassword() {
  return `Demo!${crypto.randomBytes(12).toString('hex')}`;
}

function redactSecret(text, secrets = []) {
  let out = String(text ?? '');
  const list = Array.isArray(secrets) ? secrets : [secrets];
  for (const secret of list) {
    if (typeof secret === 'string' && secret.length >= 4) {
      out = out.split(secret).join('[REDACTED]');
    }
  }
  out = out.replace(/--password=[^\s"']+/gi, '--password=[REDACTED]');
  return out;
}

async function provisionAccounts({
  argv = process.argv.slice(2),
  env = process.env,
  configLoader = getLocalSupabaseConfig,
  requestFn = apiRequest,
  logger = console,
} = {}) {
  // 1. Validação estrita de argumentos ANTES de qualquer leitura de config ou conexão
  const args = parseArgs(argv);
  if (args.selfTest) {
    await runSelfTestNoPersistence();
    return { mode: 'self-test' };
  }

  const envPassword = typeof env.LOCAL_TEST_USER_PASSWORD === 'string' ? env.LOCAL_TEST_USER_PASSWORD : '';
  let password = envPassword;
  if (!password) {
    if (!args.ephemeral) {
      throw new Error(
        'Informe a senha de teste via variável de ambiente LOCAL_TEST_USER_PASSWORD ou utilize --ephemeral.',
      );
    }
    password = generateEphemeralPassword();
  }
  if (password.length < 8) {
    throw new Error('A senha de teste precisa ter pelo menos 8 caracteres.');
  }

  const knownSecrets = [password, envPassword].filter(Boolean);
  try {
    const { apiUrl, serviceRoleKey } = configLoader(env);
    if (serviceRoleKey) knownSecrets.push(serviceRoleKey);
    assertLocalhostOnly(apiUrl);

    const accounts = [
      { key: 'estudante_a', email: 'estudante.a@demo.local', fullName: 'Estudante A Fictício', role: 'student', assignScope: false },
      { key: 'estudante_b', email: 'estudante.b@demo.local', fullName: 'Estudante B Fictício', role: 'student', assignScope: false },
      { key: 'revisor_r1', email: 'revisor.r1@demo.local', fullName: 'Revisor R1 Fictício', role: 'reviewer', assignScope: true },
      { key: 'revisor_r2', email: 'revisor.r2@demo.local', fullName: 'Revisor R2 Fictício', role: 'reviewer', assignScope: false },
    ];

    const provisioned = [];

    for (const account of accounts) {
      const list = await requestFn(apiUrl, '/auth/v1/admin/users?page=1&per_page=200', {
        serviceRoleKey,
      });
      const existing = (list?.users ?? []).find(
        (u) => (u.email ?? '').toLowerCase() === account.email.toLowerCase(),
      );

      let userId;
      if (existing) {
        const updated = await requestFn(apiUrl, `/auth/v1/admin/users/${existing.id}`, {
          method: 'PUT',
          serviceRoleKey,
          body: {
            password,
            email_confirm: true,
            user_metadata: { full_name: account.fullName },
          },
        });
        userId = updated?.id ?? existing.id;
      } else {
        const created = await requestFn(apiUrl, '/auth/v1/admin/users', {
          method: 'POST',
          serviceRoleKey,
          body: {
            email: account.email,
            password,
            email_confirm: true,
            user_metadata: { full_name: account.fullName },
          },
        });
        userId = created.id;
      }

      await requestFn(apiUrl, '/rest/v1/rpc/admin_set_user_role', {
        method: 'POST',
        serviceRoleKey,
        body: {
          p_user_id: userId,
          p_new_role: account.role,
          p_operator_type: OPERATOR_TYPE,
          p_operator_identifier: OPERATOR_IDENTIFIER,
          p_reason: 'Preparação isolada de contas fictícias locais',
        },
      });

      if (account.assignScope) {
        const existingAssignments = await requestFn(
          apiUrl,
          `/rest/v1/reviewer_assignments?reviewer_id=eq.${userId}&course_id=eq.${DEMO_COURSE_ID}&active=eq.true&select=id`,
          { serviceRoleKey },
        );
        if ((existingAssignments?.length ?? 0) === 0) {
          await requestFn(apiUrl, '/rest/v1/rpc/admin_assign_reviewer_scope', {
            method: 'POST',
            serviceRoleKey,
            body: {
              p_reviewer_id: userId,
              p_institution_id: DEMO_INSTITUTION_ID,
              p_course_id: DEMO_COURSE_ID,
              p_course_modality_id: DEMO_MODALITY_ID,
              p_operator_type: OPERATOR_TYPE,
              p_operator_identifier: OPERATOR_IDENTIFIER,
              p_reason: 'Escopo demo local do Revisor R1',
            },
          });
        }
      }

      provisioned.push({
        conta: account.key,
        id: userId,
        email: account.email,
        role: account.role,
        escopo_atribuido: account.assignScope,
      });
    }

    logger.log('Contas fictícias locais preparadas com sucesso (credenciais omitidas dos logs):');
    logger.table(provisioned);
    if (args.ephemeral) {
      logger.log(
        'Modo efêmero sem persistência em disco: credenciais mantidas apenas em memória e omitidas dos logs.',
      );
    }
    return { mode: args.ephemeral ? 'ephemeral' : 'env', provisionedCount: provisioned.length };
  } catch (err) {
    throw new Error(redactSecret(err?.message ?? String(err), knownSecrets));
  }
}

async function runSelfTestNoPersistence() {
  const legacyOutPath = path.resolve('supabase/.temp/local_test_password.txt');
  const hadLegacyFileBefore = fs.existsSync(legacyOutPath);
  const syntheticCliSecret = 'SEGREDO_SINTETICO_TESTE';
  const syntheticEnvSecret = 'SEGREDO_ENV_SINTETICO_123456';

  let configCalls = 0;
  let networkCalls = 0;
  const failIfCalledConfig = () => {
    configCalls++;
    throw new Error('Supabase config não deveria ser inicializado para argumentos rejeitados');
  };
  const failIfCalledRequest = async () => {
    networkCalls++;
    throw new Error('Nenhuma requisição HTTP deveria ocorrer para argumentos rejeitados');
  };

  // 1, 2, 3 e 4: --password=<valor>, --password e opções inválidas são rejeitadas ANTES de inicializar Supabase/rede e sem vazar valor
  for (const rejectedArgv of [
    [`--password=${syntheticCliSecret}`],
    ['--password'],
    ['--password', syntheticCliSecret],
    ['--ephemeral', `--password=${syntheticCliSecret}`],
    ['--password-out=supabase/.temp/local_test_password.txt'],
    ['--password-out'],
    [`--flag-desconhecida=${syntheticCliSecret}`],
    [syntheticCliSecret],
  ]) {
    let caughtError = null;
    try {
      await provisionAccounts({
        argv: rejectedArgv,
        env: {},
        configLoader: failIfCalledConfig,
        requestFn: failIfCalledRequest,
      });
    } catch (err) {
      caughtError = err;
    }
    assert.ok(caughtError instanceof Error, `Argumentos ${rejectedArgv[0]} deveriam falhar`);
    const combinedErr = `${caughtError.message}\n${caughtError.stack ?? ''}`;
    assert.equal(
      combinedErr.includes(syntheticCliSecret),
      false,
      'Mensagem/stack de erro nunca pode conter o segredo sintético passado na CLI',
    );
  }
  assert.equal(configCalls, 0, 'Nenhuma chamada rejeitada pode inicializar configuração do Supabase');
  assert.equal(networkCalls, 0, 'Nenhuma chamada rejeitada pode executar requisições HTTP');

  // 6, 7 e 8: --ephemeral e LOCAL_TEST_USER_PASSWORD permanecem funcionais em memória sem imprimir credenciais nem criar arquivos
  const capturedLogs = [];
  const silentLogger = {
    log: (...items) => capturedLogs.push(items.map(String).join(' ')),
    table: (rows) => capturedLogs.push(JSON.stringify(rows)),
  };
  const capturedPasswordsInMemory = [];
  const mockConfigLoader = () => ({
    apiUrl: 'http://127.0.0.1:54321',
    serviceRoleKey: 'service_role_synthetic_key_only_in_memory',
  });
  const mockRequestFn = async (_apiUrl, reqPath, opts = {}) => {
    if (reqPath.startsWith('/auth/v1/admin/users?')) {
      return { users: [] };
    }
    if (reqPath === '/auth/v1/admin/users' && opts.method === 'POST') {
      capturedPasswordsInMemory.push(opts.body.password);
      return { id: `00000000-0000-4000-8000-${String(capturedPasswordsInMemory.length).padStart(12, '0')}` };
    }
    if (reqPath.startsWith('/rest/v1/reviewer_assignments')) {
      return [];
    }
    return {};
  };

  const ephResult = await provisionAccounts({
    argv: ['--ephemeral'],
    env: {},
    configLoader: mockConfigLoader,
    requestFn: mockRequestFn,
    logger: silentLogger,
  });
  assert.equal(ephResult.mode, 'ephemeral');
  assert.equal(ephResult.provisionedCount, 4);
  assert.equal(capturedPasswordsInMemory.length, 4);
  const ephemeralGenerated = capturedPasswordsInMemory[0];
  assert.ok(ephemeralGenerated && ephemeralGenerated.length >= 16);

  const envResult = await provisionAccounts({
    argv: [],
    env: { LOCAL_TEST_USER_PASSWORD: syntheticEnvSecret },
    configLoader: mockConfigLoader,
    requestFn: mockRequestFn,
    logger: silentLogger,
  });
  assert.equal(envResult.mode, 'env');
  assert.equal(envResult.provisionedCount, 4);
  assert.equal(capturedPasswordsInMemory[4], syntheticEnvSecret);

  const serializedLogs = capturedLogs.join('\n');
  assert.equal(serializedLogs.includes(ephemeralGenerated), false, 'Logs não podem conter senha efêmera');
  assert.equal(serializedLogs.includes(syntheticEnvSecret), false, 'Logs não podem conter LOCAL_TEST_USER_PASSWORD');
  assert.equal(serializedLogs.includes(syntheticCliSecret), false, 'Logs não podem conter segredo sintético CLI');

  // 9. Sanitização case-insensitive de LOCAL_TEST_USER_PASSWORD (maiúscula, minúscula e mista) na função real e em subprocesso Node
  const passwordCasings = [
    'LOCAL_TEST_USER_PASSWORD',
    'local_test_user_password',
    'Local_Test_User_Password',
  ];
  for (const casingKey of passwordCasings) {
    const sanitizedSingle = buildSanitizedSubprocessEnv({
      ...process.env,
      [casingKey]: syntheticEnvSecret,
      KEEP_SAFE_VAR: 'preserved_ok',
    });
    assert.equal(
      Object.keys(sanitizedSingle).some((k) => k.toUpperCase() === 'LOCAL_TEST_USER_PASSWORD'),
      false,
      `Nenhuma variante (${casingKey}) pode permanecer no ambiente sanitizado`,
    );
    assert.equal(sanitizedSingle[casingKey], undefined);
    assert.equal(sanitizedSingle.KEEP_SAFE_VAR, 'preserved_ok');
  }

  const sanitizedCombined = buildSanitizedSubprocessEnv({
    ...process.env,
    LOCAL_TEST_USER_PASSWORD: syntheticEnvSecret,
    local_test_user_password: syntheticEnvSecret,
    Local_Test_User_Password: syntheticEnvSecret,
    KEEP_SAFE_VAR: 'preserved_ok',
  });
  assert.equal(
    Object.keys(sanitizedCombined).some((k) => k.toUpperCase() === 'LOCAL_TEST_USER_PASSWORD'),
    false,
    'Nenhuma das três grafias combinadas pode permanecer no ambiente sanitizado',
  );
  assert.equal(sanitizedCombined.KEEP_SAFE_VAR, 'preserved_ok');

  const childProbeScript = [
    'const keys = Object.keys(process.env);',
    'const hasAnyPasswordKey = keys.some((k) => k.toUpperCase() === "LOCAL_TEST_USER_PASSWORD");',
    'const result = {',
    '  hasAnyPasswordKey,',
    '  upperDefined: process.env.LOCAL_TEST_USER_PASSWORD !== undefined,',
    '  lowerDefined: process.env.local_test_user_password !== undefined,',
    '  mixedDefined: process.env.Local_Test_User_Password !== undefined,',
    '  keepSafeVar: process.env.KEEP_SAFE_VAR ?? null,',
    '};',
    'process.stdout.write(JSON.stringify(result));',
  ].join(' ');

  for (const casingKey of passwordCasings) {
    const childEnv = buildSanitizedSubprocessEnv({
      ...process.env,
      [casingKey]: syntheticEnvSecret,
      KEEP_SAFE_VAR: 'preserved_ok',
    });
    const childRaw = execFileSync(process.execPath, ['-e', childProbeScript], {
      env: childEnv,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    assert.equal(childRaw.includes(syntheticEnvSecret), false);
    const childReport = JSON.parse(childRaw);
    assert.deepEqual(childReport, {
      hasAnyPasswordKey: false,
      upperDefined: false,
      lowerDefined: false,
      mixedDefined: false,
      keepSafeVar: 'preserved_ok',
    });
  }

  // 5. Nenhum arquivo de senha criado e trava loopback ativa
  assert.equal(
    fs.existsSync(legacyOutPath),
    hadLegacyFileBefore,
    'Nenhum arquivo de senha pode ser criado em supabase/.temp/local_test_password.txt',
  );
  assertLocalhostOnly('http://127.0.0.1:54321');
  assertLocalhostOnly('http://localhost:54321');
  assert.throws(() => assertLocalhostOnly('https://example.supabase.co'), /URL não local/i);

  console.log(
    '✓ Auto-teste R1-04 concluído: --password e --password=<valor> rejeitados antes de qualquer conexão e sem ecoar segredo; --ephemeral e LOCAL_TEST_USER_PASSWORD validados exclusivamente em memória sem arquivos ou vazamento em logs.',
  );
}

async function main() {
  await provisionAccounts();
}

main().catch((err) => {
  const safeMsg = redactSecret(err?.message ?? String(err), [
    process.env.LOCAL_TEST_USER_PASSWORD ?? '',
  ]);
  console.error('Erro ao preparar usuários fictícios locais:', safeMsg);
  process.exit(1);
});
