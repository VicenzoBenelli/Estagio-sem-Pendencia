import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:estagio_sem_pendencia/core/config/supabase_config.dart';
import 'package:estagio_sem_pendencia/features/auth/application/auth_controller.dart';
import 'package:estagio_sem_pendencia/features/auth/data/supabase_auth_gateway.dart';
import 'package:estagio_sem_pendencia/features/auth/domain/user_profile.dart';
import 'package:estagio_sem_pendencia/features/processes/application/document_submission_controller.dart';
import 'package:estagio_sem_pendencia/features/processes/application/process_controller.dart';
import 'package:estagio_sem_pendencia/features/processes/data/supabase_document_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/data/supabase_process_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/document_models.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/document_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/process_models.dart';
import 'package:estagio_sem_pendencia/features/review/application/process_timeline_controller.dart';
import 'package:estagio_sem_pendencia/features/review/application/reviewer_controller.dart';
import 'package:estagio_sem_pendencia/features/review/data/pdf_document_renderer.dart';
import 'package:estagio_sem_pendencia/features/review/data/pdf_web_bridge.dart';
import 'package:estagio_sem_pendencia/features/review/data/supabase_review_repository.dart';
import 'package:estagio_sem_pendencia/features/review/domain/review_models.dart';

const String _kDemoInstitutionId = '10000000-0000-4000-8000-000000000001';
const String _kDemoCourseId = '20000000-0000-4000-8000-000000000001';
const String _kDemoModalityId = '30000000-0000-4000-8000-000000000001';

Uint8List _buildMinimalValidPdfBytes(String label) {
  final safeLabel = label.replaceAll(RegExp(r'[()\\]'), ' ');
  final stream = 'BT\n/F1 12 Tf\n72 720 Td\n($safeLabel) Tj\nET\n';
  final objects = <String>[
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n',
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n',
    '4 0 obj\n<< /Length ${latin1.encode(stream).length} >>\nstream\n$stream'
        'endstream\nendobj\n',
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  ];

  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  var offset = latin1.encode('%PDF-1.4\n').length;
  for (final obj in objects) {
    offsets.add(offset);
    buffer.write(obj);
    offset += latin1.encode(obj).length;
  }
  final xrefOffset = offset;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (var i = 1; i < offsets.length; i++) {
    buffer.write('${offsets[i].toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF\n',
  );
  return Uint8List.fromList(latin1.encode(buffer.toString()));
}

Uint8List _buildMultiPageValidPdfBytes(List<String> pageLabels) {
  final labels = pageLabels.isEmpty ? const <String>['Pagina 1'] : pageLabels;
  final builder = BytesBuilder(copy: false);
  final offsetsById = <int, int>{};

  void writeAscii(String text) {
    builder.add(latin1.encode(text));
  }

  void writeObject(int id, String body) {
    offsetsById[id] = builder.length;
    writeAscii('$id 0 obj\n$body\nendobj\n');
  }

  writeAscii('%PDF-1.4\n');
  const fontId = 3;
  var nextId = 4;
  final pageEntries = <({int pageId, int contentId, String label})>[];
  for (final label in labels) {
    final pId = nextId++;
    final cId = nextId++;
    pageEntries.add((pageId: pId, contentId: cId, label: label));
  }

  writeObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  final kids = pageEntries.map((e) => '${e.pageId} 0 R').join(' ');
  writeObject(
    2,
    '<< /Type /Pages /Kids [$kids] /Count ${pageEntries.length} >>',
  );
  writeObject(fontId, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');

  for (final entry in pageEntries) {
    final safe = entry.label.replaceAll(RegExp(r'[()\\]'), ' ');
    final stream = 'BT\n/F1 12 Tf\n72 720 Td\n($safe) Tj\nET\n';
    final streamLen = latin1.encode(stream).length;
    writeObject(
      entry.pageId,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
      '/Resources << /Font << /F1 $fontId 0 R >> >> '
      '/Contents ${entry.contentId} 0 R >>',
    );
    writeObject(
      entry.contentId,
      '<< /Length $streamLen >>\nstream\n${stream}endstream',
    );
  }

  final totalObjects = nextId;
  final xrefOffset = builder.length;
  writeAscii('xref\n0 $totalObjects\n0000000000 65535 f \n');
  for (var id = 1; id < totalObjects; id++) {
    final off = (offsetsById[id] ?? 0).toString().padLeft(10, '0');
    writeAscii('$off 00000 n \n');
  }
  writeAscii(
    'trailer\n<< /Size $totalObjects /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF\n',
  );
  return builder.takeBytes();
}

Map<String, String> _readLocalSupabaseStatus() {
  final result = Process.runSync(
    Platform.isWindows ? 'npx.cmd' : 'npx',
    const <String>['supabase', 'status', '-o', 'json'],
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Supabase local precisa estar em execução para o teste de integração real.',
    );
  }
  final raw = result.stdout.toString();
  final idx = raw.indexOf('{');
  if (idx == -1) {
    throw StateError('Saída inesperada de supabase status -o json.');
  }
  final decoded = jsonDecode(raw.substring(idx)) as Map<String, dynamic>;
  return <String, String>{
    'apiUrl': (decoded['API_URL'] as String).replaceAll(RegExp(r'/$'), ''),
    'anonKey': decoded['ANON_KEY'] as String,
    'serviceRoleKey': decoded['SERVICE_ROLE_KEY'] as String,
  };
}

void _provisionCanonicalDemoAccounts(String ephemeralPassword) {
  final result = Process.runSync(
    'node',
    const <String>['tool/setup_local_test_users.mjs'],
    environment: <String, String>{
      ...Platform.environment,
      'LOCAL_TEST_USER_PASSWORD': ephemeralPassword,
    },
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Falha ao provisionar contas demo locais via tool/setup_local_test_users.mjs (exit ${result.exitCode}).',
    );
  }
}

Future<String> _createIsolatedUser({
  required String apiUrl,
  required String serviceRoleKey,
  required String email,
  required String password,
  required String fullName,
  String role = 'student',
}) async {
  final createRes = await http.post(
    Uri.parse('$apiUrl/auth/v1/admin/users'),
    headers: <String, String>{
      'apikey': serviceRoleKey,
      'Authorization': 'Bearer $serviceRoleKey',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(<String, dynamic>{
      'email': email,
      'password': password,
      'email_confirm': true,
      'user_metadata': <String, dynamic>{'full_name': fullName},
    }),
  );
  expect(createRes.statusCode, 200);
  final created = jsonDecode(createRes.body) as Map<String, dynamic>;
  final userId = created['id'] as String;

  if (role != 'student') {
    final roleRes = await http.post(
      Uri.parse('$apiUrl/rest/v1/rpc/admin_set_user_role'),
      headers: <String, String>{
        'apikey': serviceRoleKey,
        'Authorization': 'Bearer $serviceRoleKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'p_user_id': userId,
        'p_new_role': role,
        'p_operator_type': 'local_demo_provisioning',
        'p_operator_identifier':
            'tool/test_flutter_document_supabase_integration.dart',
        'p_reason': 'Fixture isolada de integracao Flutter Lote 4',
      }),
    );
    expect(roleRes.statusCode, anyOf(200, 204));
  }

  return userId;
}

class _QueuedPickerGateway implements PdfPickerGateway {
  final List<SelectedPdfFile> queue = <SelectedPdfFile>[];
  final List<({String filename, Uint8List bytes})> savedFiles =
      <({String filename, Uint8List bytes})>[];

  @override
  Future<SelectedPdfFile?> pickPdf() async {
    if (queue.isEmpty) return null;
    return queue.removeAt(0);
  }

  @override
  Future<bool> savePdf({
    required String filename,
    required Uint8List bytes,
  }) async {
    savedFiles.add((filename: filename, bytes: Uint8List.fromList(bytes)));
    return true;
  }
}

class _TrackingPdfWebBridge implements PdfWebBridge {
  int _counter = 0;
  final List<PdfWebSessionHandle> createdHandles = <PdfWebSessionHandle>[];
  final List<String> revokedUrls = <String>[];
  int revokeAllCalls = 0;

  @override
  bool get isSupported => true;

  @override
  PdfWebSessionHandle? createSession({
    required Uint8List bytes,
    required String submissionId,
    required int submissionVersion,
    int initialPage = 1,
  }) {
    if (bytes.isEmpty) return null;
    final id = 'int_web_session_${++_counter}';
    final handle = PdfWebSessionHandle(
      sessionId: id,
      viewType: 'estagio-pdf-viewer-$id',
      objectUrl: 'blob:http://127.0.0.1:54321/$id',
      submissionId: submissionId,
      submissionVersion: submissionVersion,
      currentPage: initialPage,
    );
    createdHandles.add(handle);
    return handle;
  }

  @override
  void navigateToPage(PdfWebSessionHandle? handle, int pageNumber) {
    if (handle == null || handle.isRevoked) return;
    handle.currentPage = pageNumber;
  }

  @override
  bool openInBrowserTab(PdfWebSessionHandle? handle, {int? pageNumber}) {
    if (handle == null || handle.isRevoked) return false;
    handle.openTabCalls++;
    return true;
  }

  @override
  void revokeSession(PdfWebSessionHandle? handle) {
    if (handle == null) return;
    if (!handle.isRevoked) {
      handle.isRevoked = true;
      revokedUrls.add(handle.objectUrl);
    }
  }

  @override
  void revokeAllSessions() {
    revokeAllCalls++;
    for (final h in createdHandles) {
      revokeSession(h);
    }
  }
}

void main() {
  late final Map<String, String> env;
  late final String apiUrl;
  late final String anonKey;
  late final String serviceRoleKey;
  late final String sharedRunTag;
  late final String demoPassword;

  setUpAll(() {
    HttpOverrides.global = null;
    env = _readLocalSupabaseStatus();
    apiUrl = env['apiUrl']!;
    anonKey = env['anonKey']!;
    serviceRoleKey = env['serviceRoleKey']!;
    sharedRunTag = DateTime.now().microsecondsSinceEpoch.toString();
    demoPassword = 'DemoLote4!$sharedRunTag';
    _provisionCanonicalDemoAccounts(demoPassword);
  });

  test(
    'Integração real Flutter SDK -> GoTrue, create_internship_process, Edge submit-requirement-pdf e Storage privado',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final runTag = DateTime.now().microsecondsSinceEpoch.toString();
      final email = 'flutter.int.l3.$runTag@demo.local';
      final password = 'DemoFlutter!$runTag';

      // Provisiona apenas a fixture isolada do usuário no backend local de teste
      final createRes = await http.post(
        Uri.parse('$apiUrl/auth/v1/admin/users'),
        headers: <String, String>{
          'apikey': serviceRoleKey,
          'Authorization': 'Bearer $serviceRoleKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'email': email,
          'password': password,
          'email_confirm': true,
          'user_metadata': const <String, dynamic>{
            'full_name': 'Estudante Integracao Flutter L3',
          },
        }),
      );
      expect(createRes.statusCode, 200);

      // Cliente SDK real utilizando exclusivamente a chave pública (nunca service_role)
      final client = SupabaseClient(apiUrl, anonKey);
      addTearDown(client.dispose);

      final signIn = await client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      expect(signIn.session?.accessToken, isNotEmpty);

      final processRepo = SupabaseProcessRepository(client);
      final documentRepo = SupabaseDocumentRepository(client);

      final catalog = await processRepo.fetchActiveCatalog();
      final targetModality = catalog.firstWhere((m) => m.hasPublishedTemplate);

      final createdProcess = await processRepo.createProcess(
        courseModalityId: targetModality.id,
      );
      final detailBefore = await processRepo.fetchProcessDetail(
        processId: createdProcess.id,
      );
      expect(detailBefore, isNotNull);
      expect(detailBefore!.requirements, isNotEmpty);
      final targetReq = detailBefore.requirements.first;
      expect(targetReq.status, RequirementStatus.notSubmitted);

      final pdfBytes = _buildMinimalValidPdfBytes('Integracao Flutter $runTag');
      final idemKey = generateUuidV4();
      final selected = SelectedPdfFile(
        name: 'termo_integracao_flutter.pdf',
        bytes: pdfBytes,
      );

      // 1) Envio real para Edge Function submit-requirement-pdf
      final outcome1 = await documentRepo.submitRequirementPdf(
        processRequirementId: targetReq.id,
        file: selected,
        idempotencyKey: idemKey,
      );
      expect(outcome1.idempotentReplay, isFalse);
      expect(outcome1.submission.version, 1);
      expect(outcome1.submission.status, SubmissionStatus.underReview);
      expect(outcome1.requirementStatus, RequirementStatus.underReview);
      expect(outcome1.currentVersion, 1);
      expect(outcome1.currentSubmissionId, outcome1.submission.id);
      expect(outcome1.submission.storageBucket, kPrivateDocumentsBucket);

      // 2) Retry idempotente real retorna 200 replay sem criar v2
      final outcomeReplay = await documentRepo.submitRequirementPdf(
        processRequirementId: targetReq.id,
        file: selected,
        idempotencyKey: idemKey,
      );
      expect(outcomeReplay.idempotentReplay, isTrue);
      expect(outcomeReplay.submission.id, outcome1.submission.id);
      expect(outcomeReplay.submission.version, 1);

      // 3) Consulta via RLS por idempotency_key + histórico de versões
      final foundByKey = await documentRepo.findSubmissionByIdempotencyKey(
        processRequirementId: targetReq.id,
        idempotencyKey: idemKey,
      );
      expect(foundByKey?.id, outcome1.submission.id);

      final history = await documentRepo.fetchRequirementSubmissions(
        processRequirementId: targetReq.id,
      );
      expect(history.length, 1);
      expect(history.single.id, outcome1.submission.id);

      // 4) Download privado real via Edge Function download-submission-pdf (enquanto leitura direta do Storage é bloqueada)
      await expectLater(
        client.storage
            .from(outcome1.submission.storageBucket)
            .download(outcome1.submission.storagePath),
        throwsA(isA<StorageException>()),
      );

      final downloadedBytes = await documentRepo.downloadSubmissionBytes(
        submissionId: outcome1.submission.id,
      );
      expect(downloadedBytes, equals(pdfBytes));

      // 5) Após logout, download e novo upload falham com erro autorizado seguro
      await client.auth.signOut();
      await expectLater(
        documentRepo.downloadSubmissionBytes(
          submissionId: outcome1.submission.id,
        ),
        throwsA(
          isA<DocumentFailure>()
              .having((e) => e.httpStatus, 'httpStatus', 401)
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
    },
  );

  test(
    'Integração real Lote 4 (ESP-18..22) — Repositories Flutter reais, jornada documental de 31 etapas, filtros, paginação, versionamento v1/v2 e isolamento cruzado',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final runTag = DateTime.now().microsecondsSinceEpoch.toString();

      // Cria estudante isolado para esta execução (permitindo reexecuções sem conflito 23505 no catálogo DEMO)
      final studentAEmail = 'estudante.a.int.$runTag@demo.local';
      await _createIsolatedUser(
        apiUrl: apiUrl,
        serviceRoleKey: serviceRoleKey,
        email: studentAEmail,
        password: demoPassword,
        fullName: 'Estudante A Jornada Lote 4 ($runTag)',
      );

      final config = SupabaseConfig(url: apiUrl, publishableKey: anonKey);

      // 1) Verifica autenticação real e perfis das 4 contas demo via SupabaseAuthGateway
      final verifyClient = SupabaseClient(apiUrl, anonKey);
      addTearDown(verifyClient.dispose);
      final verifyAuthGateway = SupabaseAuthGateway(
        verifyClient,
        config: config,
      );

      final profileEstudanteA = await verifyAuthGateway.signIn(
        email: 'estudante.a@demo.local',
        password: demoPassword,
      );
      expect(profileEstudanteA.role, UserRole.student);
      expect(profileEstudanteA.active, isTrue);
      await verifyAuthGateway.signOut();

      final profileEstudanteB = await verifyAuthGateway.signIn(
        email: 'estudante.b@demo.local',
        password: demoPassword,
      );
      expect(profileEstudanteB.role, UserRole.student);
      expect(profileEstudanteB.active, isTrue);
      await verifyAuthGateway.signOut();

      final profileRevisorR1 = await verifyAuthGateway.signIn(
        email: 'revisor.r1@demo.local',
        password: demoPassword,
      );
      expect(profileRevisorR1.role, UserRole.reviewer);
      expect(profileRevisorR1.active, isTrue);
      await verifyAuthGateway.signOut();

      final profileRevisorR2 = await verifyAuthGateway.signIn(
        email: 'revisor.r2@demo.local',
        password: demoPassword,
      );
      expect(profileRevisorR2.role, UserRole.reviewer);
      expect(profileRevisorR2.active, isTrue);
      await verifyAuthGateway.signOut();

      // Clientes SDK independentes (exclusivamente com chave pública ANON_KEY)
      final studentAClient = SupabaseClient(apiUrl, anonKey);
      final studentBClient = SupabaseClient(apiUrl, anonKey);
      final reviewerR1Client = SupabaseClient(apiUrl, anonKey);
      final reviewerR2Client = SupabaseClient(apiUrl, anonKey);
      addTearDown(() async {
        await studentAClient.dispose();
        await studentBClient.dispose();
        await reviewerR1Client.dispose();
        await reviewerR2Client.dispose();
      });

      final studentAProcessRepo = SupabaseProcessRepository(studentAClient);
      final studentADocRepo = SupabaseDocumentRepository(studentAClient);
      final studentAReviewRepo = SupabaseReviewRepository(studentAClient);

      final studentBProcessRepo = SupabaseProcessRepository(studentBClient);
      final studentBDocRepo = SupabaseDocumentRepository(studentBClient);
      final studentBReviewRepo = SupabaseReviewRepository(studentBClient);

      final reviewerR1Repo = SupabaseReviewRepository(reviewerR1Client);
      final reviewerR2Repo = SupabaseReviewRepository(reviewerR2Client);

      // Etapa 1: Autenticar estudante A da jornada
      final signInA = await studentAClient.auth.signInWithPassword(
        email: studentAEmail,
        password: demoPassword,
      );
      expect(signInA.session?.accessToken, isNotEmpty);

      // Etapa 2: Selecionar explicitamente o catálogo correto (INST_DEMO / TEC_DEMO / ESTAGIO_OBRIG_DEMO)
      final activeCatalog = await studentAProcessRepo.fetchActiveCatalog();
      final demoModality = activeCatalog.firstWhere(
        (m) =>
            m.id == _kDemoModalityId &&
            m.course.id == _kDemoCourseId &&
            m.institution.id == _kDemoInstitutionId,
      );
      expect(demoModality.code, 'ESTAGIO_OBRIG_DEMO');
      expect(demoModality.course.code, 'TEC_DEMO');
      expect(demoModality.institution.code, 'INST_DEMO');
      expect(demoModality.hasPublishedTemplate, isTrue);
      expect(demoModality.publishedTemplate?.version, 1);

      final createdProcess = await studentAProcessRepo.createProcess(
        courseModalityId: demoModality.id,
      );
      expect(createdProcess.status, ProcessStatus.inProgress);
      expect(createdProcess.templateVersion, 1);

      // Etapa 3: Confirmar 2 requisitos obrigatórios e 1 requisito opcional
      final initialDetail = await studentAProcessRepo.fetchProcessDetail(
        processId: createdProcess.id,
      );
      expect(initialDetail, isNotNull);
      expect(initialDetail!.requirements.length, 3);
      final reqObrig1 = initialDetail.requirements.firstWhere(
        (r) => r.code == 'DEMO_REQ_OBRIG_01',
      );
      final reqObrig2 = initialDetail.requirements.firstWhere(
        (r) => r.code == 'DEMO_REQ_OBRIG_02',
      );
      final reqOpc1 = initialDetail.requirements.firstWhere(
        (r) => r.code == 'DEMO_REQ_OPC_01',
      );
      expect(reqObrig1.isRequired, isTrue);
      expect(reqObrig2.isRequired, isTrue);
      expect(reqOpc1.isRequired, isFalse);
      expect(initialDetail.progress?.requiredTotal, 2);
      expect(initialDetail.progress?.requiredApproved, 0);
      expect(initialDetail.progress?.progressPercentage, 0);

      // Etapas 4, 5 e 6: Enviar PDF v1 para DEMO_REQ_OBRIG_01 pela Edge Function e confirmar under_review
      final pdfV1Bytes = _buildMultiPageValidPdfBytes(<String>[
        'DEMO_REQ_OBRIG_01 VERSAO V1 PAGINA 1 - $runTag',
        'DEMO_REQ_OBRIG_01 VERSAO V1 PAGINA 2 ASSINATURA PENDENTE - $runTag',
      ]);
      final v1Outcome = await studentADocRepo.submitRequirementPdf(
        processRequirementId: reqObrig1.id,
        file: SelectedPdfFile(
          name: 'termo_compromisso_v1.pdf',
          bytes: pdfV1Bytes,
        ),
        idempotencyKey: generateUuidV4(),
      );
      expect(v1Outcome.submission.version, 1);
      expect(v1Outcome.submission.status, SubmissionStatus.underReview);
      expect(v1Outcome.requirementStatus, RequirementStatus.underReview);
      expect(v1Outcome.currentVersion, 1);

      // Etapa 7: Encerrar sessão do estudante
      await studentAClient.auth.signOut();

      // Etapa 8: Autenticar revisor autorizado (revisor.r1@demo.local)
      final signInR1 = await reviewerR1Client.auth.signInWithPassword(
        email: 'revisor.r1@demo.local',
        password: demoPassword,
      );
      expect(signInR1.session?.accessToken, isNotEmpty);

      // Etapas 9 e 10: Encontrar v1 na fila real de revisão e validar filtros e versão
      final queuePage = await reviewerR1Repo.fetchReviewerQueue(
        query: ReviewerQueueQuery(
          processId: createdProcess.id,
          courseModalityId: _kDemoModalityId,
          requirementCode: 'DEMO_REQ_OBRIG_01',
          onlyRequired: true,
          onlyResubmissions: false,
          searchQuery: 'DEMO_REQ_OBRIG_01',
          pageSize: 10,
        ),
      );
      expect(queuePage.totalCount, 1);
      expect(queuePage.items.length, 1);
      final queuedV1 = queuePage.items.single;
      expect(queuedV1.submissionId, v1Outcome.submission.id);
      expect(queuedV1.submissionVersion, 1);
      expect(queuedV1.currentVersion, 1);
      expect(queuedV1.isResubmission, isFalse);
      expect(queuedV1.requirementStatus, RequirementStatus.underReview);
      expect(queuedV1.submissionStatus, SubmissionStatus.underReview);

      // Filtro de apenas reenvios não deve retornar v1
      final queueOnlyResub = await reviewerR1Repo.fetchReviewerQueue(
        query: ReviewerQueueQuery(
          processId: createdProcess.id,
          onlyResubmissions: true,
        ),
      );
      expect(queueOnlyResub.totalCount, 0);
      expect(queueOnlyResub.items, isEmpty);

      // Etapa 11: Baixar e verificar conteúdo efetivo do PDF v1 via gateway server-side download-submission-pdf
      final downloadedV1ByR1 = await reviewerR1Repo.downloadSubmissionBytes(
        submissionId: queuedV1.submissionId,
      );
      expect(downloadedV1ByR1, equals(pdfV1Bytes));
      expect(
        latin1.decode(downloadedV1ByR1, allowInvalid: true),
        contains('VERSAO V1 PAGINA 2 ASSINATURA PENDENTE'),
      );

      // Validações negativas de parâmetros na RPC review_submission
      await expectLater(
        reviewerR1Repo.reviewSubmission(
          submissionId: queuedV1.submissionId,
          decision: ReviewDecision.correctionRequested,
          reason: '   ',
        ),
        throwsA(
          isA<ReviewFailure>().having(
            (e) => e.code,
            'code',
            'missing_correction_reason',
          ),
        ),
      );

      await expectLater(
        reviewerR1Repo.reviewSubmission(
          submissionId: '00000000-0000-4000-8000-999999999999',
          decision: ReviewDecision.approved,
        ),
        throwsA(
          isA<ReviewFailure>()
              .having((e) => e.code, 'code', 'submission_not_found')
              .having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );

      // Fase E (Isolamento): Revisor não autorizado (revisor.r2@demo.local) e Estudante B (estudante.b@demo.local)
      // não enxergam nem conseguem baixar ou decidir sobre v1 enquanto está under_review
      await reviewerR2Client.auth.signInWithPassword(
        email: 'revisor.r2@demo.local',
        password: demoPassword,
      );
      final r2Queue = await reviewerR2Repo.fetchReviewerQueue(
        query: ReviewerQueueQuery(processId: createdProcess.id),
      );
      expect(r2Queue.totalCount, 0);
      expect(r2Queue.items, isEmpty);

      await expectLater(
        reviewerR2Repo.downloadSubmissionBytes(
          submissionId: queuedV1.submissionId,
        ),
        throwsA(isA<ReviewFailure>()),
      );

      await expectLater(
        reviewerR2Repo.reviewSubmission(
          submissionId: queuedV1.submissionId,
          decision: ReviewDecision.approved,
        ),
        throwsA(
          isA<ReviewFailure>()
              .having((e) => e.code, 'code', 'forbidden_scope')
              .having((e) => e.isForbiddenScope, 'isForbiddenScope', isTrue),
        ),
      );

      final r2Timeline = await reviewerR2Repo.fetchProcessAuditTimeline(
        processId: createdProcess.id,
      );
      expect(r2Timeline.totalCount, 0);
      expect(r2Timeline.items, isEmpty);
      await reviewerR2Client.auth.signOut();

      await studentBClient.auth.signInWithPassword(
        email: 'estudante.b@demo.local',
        password: demoPassword,
      );
      final studentBProcesses = await studentBProcessRepo
          .fetchStudentProcesses();
      expect(studentBProcesses.any((p) => p.id == createdProcess.id), isFalse);
      final studentBCrossDetail = await studentBProcessRepo.fetchProcessDetail(
        processId: createdProcess.id,
      );
      expect(studentBCrossDetail, isNull);
      await expectLater(
        studentBDocRepo.downloadSubmissionBytes(
          submissionId: queuedV1.submissionId,
        ),
        throwsA(isA<DocumentFailure>()),
      );
      final studentBCrossSubs = await studentBDocRepo
          .fetchRequirementSubmissions(processRequirementId: reqObrig1.id);
      expect(studentBCrossSubs, isEmpty);
      final studentBCrossReviews = await studentBDocRepo
          .fetchRequirementReviews(processRequirementId: reqObrig1.id);
      expect(studentBCrossReviews, isEmpty);
      final studentBCrossTimeline = await studentBReviewRepo
          .fetchProcessAuditTimeline(processId: createdProcess.id);
      expect(studentBCrossTimeline.totalCount, 0);
      expect(studentBCrossTimeline.items, isEmpty);
      await expectLater(
        studentBReviewRepo.reviewSubmission(
          submissionId: queuedV1.submissionId,
          decision: ReviewDecision.approved,
        ),
        throwsA(
          isA<ReviewFailure>()
              .having((e) => e.code, 'code', 'forbidden_role')
              .having((e) => e.isForbiddenRole, 'isForbiddenRole', isTrue),
        ),
      );
      await studentBClient.auth.signOut();

      // Etapa 12: Solicitar correção com justificativa reconhecível e não sensível
      final correctionReason =
          'Incluir assinatura do supervisor na pagina 2 e reenviar PDF atualizado ($runTag).';
      final correctionIdemKey = generateUuidV4();
      final correctionOutcome = await reviewerR1Repo.reviewSubmission(
        submissionId: queuedV1.submissionId,
        decision: ReviewDecision.correctionRequested,
        reason: correctionReason,
        idempotencyKey: correctionIdemKey,
      );
      expect(correctionOutcome.ok, isTrue);
      expect(correctionOutcome.idempotentReplay, isFalse);
      expect(
        correctionOutcome.review.decision,
        ReviewDecision.correctionRequested,
      );
      expect(correctionOutcome.review.reason, correctionReason);
      expect(
        correctionOutcome.submission.status,
        SubmissionStatus.correctionRequested,
      );
      expect(
        correctionOutcome.requirement.status,
        RequirementStatus.correctionRequested,
      );

      // Replay idempotente com a mesma chave retorna 200 idempotentReplay=true
      final correctionReplay = await reviewerR1Repo.reviewSubmission(
        submissionId: queuedV1.submissionId,
        decision: ReviewDecision.correctionRequested,
        reason: correctionReason,
        idempotencyKey: correctionIdemKey,
      );
      expect(correctionReplay.idempotentReplay, isTrue);
      expect(correctionReplay.review.id, correctionOutcome.review.id);

      // Mesma idempotency_key com payload divergente retorna 409 idempotency_mismatch
      await expectLater(
        reviewerR1Repo.reviewSubmission(
          submissionId: queuedV1.submissionId,
          decision: ReviewDecision.approved,
          idempotencyKey: correctionIdemKey,
        ),
        throwsA(
          isA<ReviewFailure>()
              .having((e) => e.code, 'code', 'idempotency_mismatch')
              .having(
                (e) => e.isIdempotencyMismatch,
                'isIdempotencyMismatch',
                isTrue,
              ),
        ),
      );

      // Etapa 13: Confirmar saída da v1 da fila de revisão
      final queueAfterCorrection = await reviewerR1Repo.fetchReviewerQueue(
        query: ReviewerQueueQuery(processId: createdProcess.id),
      );
      expect(queueAfterCorrection.totalCount, 0);
      expect(queueAfterCorrection.items, isEmpty);

      // Etapa 14: Encerrar sessão do revisor
      await reviewerR1Client.auth.signOut();

      // Etapas 15, 16 e 17: Autenticar novamente estudante A, confirmar exibição da justificativa e histórico v1
      await studentAClient.auth.signInWithPassword(
        email: studentAEmail,
        password: demoPassword,
      );
      final detailAfterCorrection = await studentAProcessRepo
          .fetchProcessDetail(processId: createdProcess.id);
      final reqObrig1AfterCorr = detailAfterCorrection!.requirements.firstWhere(
        (r) => r.id == reqObrig1.id,
      );
      expect(reqObrig1AfterCorr.status, RequirementStatus.correctionRequested);
      expect(reqObrig1AfterCorr.currentVersion, 1);

      final reviewsForObrig1 = await studentADocRepo.fetchRequirementReviews(
        processRequirementId: reqObrig1.id,
      );
      expect(reviewsForObrig1.length, 1);
      expect(reviewsForObrig1.single.reason, correctionReason);
      expect(
        reviewsForObrig1.single.decision,
        ReviewDecision.correctionRequested,
      );

      // Etapas 18 e 19: Reenviar documento corrigido como v2 e confirmar retorno a under_review
      final pdfV2Bytes = _buildMultiPageValidPdfBytes(<String>[
        'DEMO_REQ_OBRIG_01 VERSAO V2 CORRIGIDA PAGINA 1 - $runTag',
        'DEMO_REQ_OBRIG_01 VERSAO V2 ASSINATURA SUPERVISOR CONFIRMADA PAGINA 2 - $runTag',
      ]);
      expect(pdfV2Bytes, isNot(equals(pdfV1Bytes)));

      final v2Outcome = await studentADocRepo.submitRequirementPdf(
        processRequirementId: reqObrig1.id,
        file: SelectedPdfFile(
          name: 'termo_compromisso_v2_corrigido.pdf',
          bytes: pdfV2Bytes,
        ),
        idempotencyKey: generateUuidV4(),
      );
      expect(v2Outcome.submission.version, 2);
      expect(v2Outcome.submission.status, SubmissionStatus.underReview);
      expect(v2Outcome.requirementStatus, RequirementStatus.underReview);
      expect(v2Outcome.currentVersion, 2);

      // Histórico do requisito preserva v1 e v2 simultaneamente
      final historyAfterV2 = await studentADocRepo.fetchRequirementSubmissions(
        processRequirementId: reqObrig1.id,
      );
      expect(historyAfterV2.map((s) => s.version).toList(), <int>[2, 1]);
      expect(historyAfterV2[0].id, v2Outcome.submission.id);
      expect(historyAfterV2[0].status, SubmissionStatus.underReview);
      expect(historyAfterV2[1].id, v1Outcome.submission.id);
      expect(historyAfterV2[1].status, SubmissionStatus.correctionRequested);

      await studentAClient.auth.signOut();

      // Etapas 20 e 21: Autenticar novamente o revisor autorizado e confirmar v2 na fila como reenvio
      await reviewerR1Client.auth.signInWithPassword(
        email: 'revisor.r1@demo.local',
        password: demoPassword,
      );
      final queueWithV2 = await reviewerR1Repo.fetchReviewerQueue(
        query: ReviewerQueueQuery(
          processId: createdProcess.id,
          onlyResubmissions: true,
        ),
      );
      expect(queueWithV2.totalCount, 1);
      final queuedV2 = queueWithV2.items.single;
      expect(queuedV2.submissionId, v2Outcome.submission.id);
      expect(queuedV2.submissionVersion, 2);
      expect(queuedV2.currentVersion, 2);
      expect(queuedV2.isResubmission, isTrue);

      // Etapa 22: Abrir o PDF v2 e comprovar que seu conteúdo é diferente da versão v1 (preservando download histórico da v1)
      final downloadedV2ByR1 = await reviewerR1Repo.downloadSubmissionBytes(
        submissionId: queuedV2.submissionId,
      );
      expect(downloadedV2ByR1, equals(pdfV2Bytes));
      expect(downloadedV2ByR1, isNot(equals(downloadedV1ByR1)));
      final historicalV1ByR1 = await reviewerR1Repo.downloadSubmissionBytes(
        submissionId: v1Outcome.submission.id,
      );
      expect(historicalV1ByR1, equals(pdfV1Bytes));
      expect(
        latin1.decode(downloadedV2ByR1, allowInvalid: true),
        contains('VERSAO V2 ASSINATURA SUPERVISOR CONFIRMADA'),
      );

      // Etapa 23: Verificar rejeição de tentativa de decisão sobre a versão v1 obsoleta/já decidida
      await expectLater(
        reviewerR1Repo.reviewSubmission(
          submissionId: v1Outcome.submission.id,
          decision: ReviewDecision.approved,
        ),
        throwsA(
          isA<ReviewFailure>()
              .having(
                (e) => e.code,
                'code',
                anyOf(
                  'obsolete_submission_version',
                  'submission_already_reviewed',
                ),
              )
              .having((e) => e.httpStatus, 'httpStatus', 409)
              .having((e) => e.isConflict, 'isConflict', isTrue)
              .having((e) => e.shouldReloadQueue, 'shouldReloadQueue', isTrue),
        ),
      );

      // Etapas 24 e 25: Aprovar v2 e confirmar atualização do checklist e progresso documental (50%)
      final approveV2Outcome = await reviewerR1Repo.reviewSubmission(
        submissionId: queuedV2.submissionId,
        decision: ReviewDecision.approved,
        reason: 'Termo v2 conferido e aprovado documentalmente.',
        idempotencyKey: generateUuidV4(),
      );
      expect(approveV2Outcome.ok, isTrue);
      expect(approveV2Outcome.review.decision, ReviewDecision.approved);
      expect(approveV2Outcome.submission.status, SubmissionStatus.approved);
      expect(approveV2Outcome.requirement.status, RequirementStatus.approved);
      expect(approveV2Outcome.process.status, ProcessStatus.inProgress);
      expect(approveV2Outcome.progress?.requiredTotal, 2);
      expect(approveV2Outcome.progress?.requiredApproved, 1);
      expect(approveV2Outcome.progress?.progressPercentage, 50.0);

      // Tentativa de segunda decisão sobre v2 já aprovada deve falhar com 409 submission_already_reviewed
      await expectLater(
        reviewerR1Repo.reviewSubmission(
          submissionId: queuedV2.submissionId,
          decision: ReviewDecision.approved,
          idempotencyKey: generateUuidV4(),
        ),
        throwsA(
          isA<ReviewFailure>()
              .having((e) => e.code, 'code', 'submission_already_reviewed')
              .having((e) => e.httpStatus, 'httpStatus', 409)
              .having((e) => e.isAlreadyReviewed, 'isAlreadyReviewed', isTrue),
        ),
      );

      await reviewerR1Client.auth.signOut();

      // Etapas 26, 27, 28, 29, 30 e 31: Enviar e aprovar o 2º requisito obrigatório (DEMO_REQ_OBRIG_02),
      // mantendo o opcional DEMO_REQ_OPC_01 não enviado, e confirmar 100% documentally_complete
      await studentAClient.auth.signInWithPassword(
        email: studentAEmail,
        password: demoPassword,
      );
      final pdfReq2Bytes = _buildMultiPageValidPdfBytes(<String>[
        'DEMO_REQ_OBRIG_02 PLANO DE ATIVIDADES V1 - $runTag',
      ]);
      final req2SubOutcome = await studentADocRepo.submitRequirementPdf(
        processRequirementId: reqObrig2.id,
        file: SelectedPdfFile(
          name: 'plano_atividades_v1.pdf',
          bytes: pdfReq2Bytes,
        ),
        idempotencyKey: generateUuidV4(),
      );
      expect(req2SubOutcome.submission.version, 1);
      expect(req2SubOutcome.requirementStatus, RequirementStatus.underReview);
      await studentAClient.auth.signOut();

      await reviewerR1Client.auth.signInWithPassword(
        email: 'revisor.r1@demo.local',
        password: demoPassword,
      );
      final approveReq2Outcome = await reviewerR1Repo.reviewSubmission(
        submissionId: req2SubOutcome.submission.id,
        decision: ReviewDecision.approved,
        reason: 'Plano de atividades aprovado documentalmente.',
        idempotencyKey: generateUuidV4(),
      );
      expect(approveReq2Outcome.ok, isTrue);
      expect(
        approveReq2Outcome.process.status,
        ProcessStatus.documentallyComplete,
      );
      expect(approveReq2Outcome.progress?.requiredTotal, 2);
      expect(approveReq2Outcome.progress?.requiredApproved, 2);
      expect(approveReq2Outcome.progress?.progressPercentage, 100.0);
      expect(
        approveReq2Outcome.progress?.progressStatus,
        ProgressStatus.documentallyComplete,
      );
      await reviewerR1Client.auth.signOut();

      // Estudante A confirma checklist final, timeline completa e que opcional não bloqueia conclusão
      await studentAClient.auth.signInWithPassword(
        email: studentAEmail,
        password: demoPassword,
      );
      final finalDetail = await studentAProcessRepo.fetchProcessDetail(
        processId: createdProcess.id,
      );
      expect(finalDetail!.process.status, ProcessStatus.documentallyComplete);
      expect(finalDetail.process.status.label, 'Sem pendências documentais');
      expect(
        finalDetail.process.status.label.toLowerCase(),
        isNot(contains('estágio autorizado')),
      );
      expect(finalDetail.progress?.progressPercentage, 100.0);

      final finalOpc = finalDetail.requirements.firstWhere(
        (r) => r.code == 'DEMO_REQ_OPC_01',
      );
      expect(finalOpc.status, RequirementStatus.notSubmitted);

      // Etapa 30: Timeline completa e paginada via process_audit_timeline_v (8 eventos no ciclo completo)
      final timelinePage1 = await studentAReviewRepo.fetchProcessAuditTimeline(
        processId: createdProcess.id,
        page: 0,
        pageSize: 3,
        oldestFirst: true,
      );
      expect(timelinePage1.totalCount, 8);
      expect(timelinePage1.items.length, 3);
      expect(timelinePage1.hasNextPage, isTrue);

      final fullTimeline = await studentAReviewRepo.fetchProcessAuditTimeline(
        processId: createdProcess.id,
        page: 0,
        pageSize: 20,
        oldestFirst: true,
      );
      expect(fullTimeline.totalCount, 8);
      expect(
        fullTimeline.items.map((e) => e.eventType).toList(),
        <AuditEventType>[
          AuditEventType.processCreated,
          AuditEventType.documentSubmitted,
          AuditEventType.documentCorrectionRequested,
          AuditEventType.documentSubmitted,
          AuditEventType.documentApproved,
          AuditEventType.documentSubmitted,
          AuditEventType.documentApproved,
          AuditEventType.processDocumentallyCompleted,
        ],
      );
      final completionEvent = fullTimeline.items.firstWhere(
        (e) => e.eventType == AuditEventType.processDocumentallyCompleted,
      );
      expect(completionEvent.isNotOfficialAuthorization, isTrue);
      expect(
        completionEvent.metadata['not_official_internship_authorization'],
        isTrue,
      );
      final correctionEvent = fullTimeline.items.firstWhere(
        (e) => e.eventType == AuditEventType.documentCorrectionRequested,
      );
      expect(correctionEvent.reason, correctionReason);
      expect(correctionEvent.submissionVersion, 1);
      expect(correctionEvent.actorDisplayName, isNotEmpty);
    },
  );

  test(
    'Integração real Controllers Flutter + Supabase local: ReviewerController, ProcessController, DocumentSubmissionController, ProcessTimelineController e privacidade de sessão no logout com PDF aberto',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final runTag = DateTime.now().microsecondsSinceEpoch.toString();
      final studentCtrlEmail = 'estudante.ctrl.l4.$runTag@demo.local';
      await _createIsolatedUser(
        apiUrl: apiUrl,
        serviceRoleKey: serviceRoleKey,
        email: studentCtrlEmail,
        password: demoPassword,
        fullName: 'Estudante Controllers Lote 4 ($runTag)',
      );

      final client = SupabaseClient(apiUrl, anonKey);
      addTearDown(client.dispose);

      final config = SupabaseConfig(url: apiUrl, publishableKey: anonKey);
      final authController = AuthController(
        gateway: SupabaseAuthGateway(client, config: config),
      );
      await authController.initialize();
      addTearDown(authController.dispose);

      final processRepo = SupabaseProcessRepository(client);
      final docRepo = SupabaseDocumentRepository(client);
      final reviewRepo = SupabaseReviewRepository(client);
      final pickerGateway = _QueuedPickerGateway();
      final trackingWebBridge = _TrackingPdfWebBridge();
      final pdfRendererGateway = PlatformPdfRendererGateway(
        webBridge: trackingWebBridge,
        useAndroidNativeChannel: false,
      );

      // 1) Login real via AuthController do estudante e abertura de processo no catálogo DEMO via ProcessController
      await authController.signIn(
        email: studentCtrlEmail,
        password: demoPassword,
      );
      expect(authController.status, AuthViewStatus.authenticatedStudent);
      expect(authController.profile?.role, UserRole.student);

      final processController = ProcessController(repository: processRepo);
      final timelineController = ProcessTimelineController(
        repository: reviewRepo,
      );
      final docController = DocumentSubmissionController(
        repository: docRepo,
        pickerGateway: pickerGateway,
        onSubmissionCommitted: (processId) async {
          await processController.refreshAfterDocumentUpdate(processId);
          await timelineController.loadTimeline(processId);
        },
      );
      addTearDown(() {
        docController.dispose();
        timelineController.dispose();
        processController.dispose();
      });

      await processController.openCreateProcessForm();
      processController.selectInstitution(_kDemoInstitutionId);
      processController.selectCourse(_kDemoCourseId);
      processController.selectModality(_kDemoModalityId);
      expect(processController.canSubmitCreateProcess, isTrue);

      final createdOk = await processController.submitCreateProcess();
      expect(createdOk, isTrue);
      expect(processController.detailBundle, isNotNull);
      final procId = processController.detailBundle!.process.id;

      final req1 = processController.detailBundle!.requirements.firstWhere(
        (r) => r.code == 'DEMO_REQ_OBRIG_01',
      );
      final req2 = processController.detailBundle!.requirements.firstWhere(
        (r) => r.code == 'DEMO_REQ_OBRIG_02',
      );

      // Envia 2 PDFs pelos controllers reais para testar troca rápida e logout com PDF aberto no ReviewerController
      final pdf1Bytes = _buildMultiPageValidPdfBytes(<String>[
        'CTRL REQ 1 PAGINA 1 - $runTag',
        'CTRL REQ 1 PAGINA 2 - $runTag',
      ]);
      final pdf2Bytes = _buildMultiPageValidPdfBytes(<String>[
        'CTRL REQ 2 PAGINA UNICA - $runTag',
      ]);
      pickerGateway.queue.add(
        SelectedPdfFile(name: 'ctrl_req1_v1.pdf', bytes: pdf1Bytes),
      );
      final picked1 = await docController.pickPdfForRequirement(
        req1,
        processStatus: ProcessStatus.inProgress,
        userRole: UserRole.student,
      );
      expect(picked1, isTrue);
      final submitted1 = await docController.submitSelectedPdf(
        requirement: req1,
        processStatus: ProcessStatus.inProgress,
        userRole: UserRole.student,
      );
      expect(submitted1, isTrue);

      pickerGateway.queue.add(
        SelectedPdfFile(name: 'ctrl_req2_v1.pdf', bytes: pdf2Bytes),
      );
      final picked2 = await docController.pickPdfForRequirement(
        req2,
        processStatus: ProcessStatus.inProgress,
        userRole: UserRole.student,
      );
      expect(picked2, isTrue);
      final submitted2 = await docController.submitSelectedPdf(
        requirement: req2,
        processStatus: ProcessStatus.inProgress,
        userRole: UserRole.student,
      );
      expect(submitted2, isTrue);

      // Logout do estudante limpa estados privados
      docController.clearPrivateState();
      timelineController.clearPrivateState();
      processController.clearPrivateState();
      await authController.signOut();
      expect(authController.status, AuthViewStatus.unauthenticated);

      // 2) Login real como revisor.r1@demo.local e uso do ReviewerController real
      await authController.signIn(
        email: 'revisor.r1@demo.local',
        password: demoPassword,
      );
      expect(authController.status, AuthViewStatus.authenticatedReviewer);

      final reviewerController = ReviewerController(
        repository: reviewRepo,
        pickerGateway: pickerGateway,
        pdfRendererGateway: pdfRendererGateway,
      );
      addTearDown(reviewerController.dispose);

      await reviewerController.loadQueue(
        newQuery: ReviewerQueueQuery(processId: procId),
      );
      expect(reviewerController.queueItems.length, 2);

      final item1 = reviewerController.queueItems.firstWhere(
        (i) => i.requirementCode == 'DEMO_REQ_OBRIG_01',
      );
      final item2 = reviewerController.queueItems.firstWhere(
        (i) => i.requirementCode == 'DEMO_REQ_OBRIG_02',
      );

      reviewerController.selectQueueItem(item1);
      final loaded1Ok = await reviewerController
          .loadAuthenticatedPdfForSelected();
      expect(loaded1Ok, isTrue);
      final payload1 = reviewerController.loadedPdf!;
      expect(payload1.isWiped, isFalse);
      expect(payload1.bytes, equals(pdf1Bytes));
      expect(trackingWebBridge.createdHandles.length, 1);
      final handle1 = trackingWebBridge.createdHandles.first;
      expect(handle1.isRevoked, isFalse);

      // Abre em nova aba Web
      final openedTab = reviewerController.openPdfInBrowserOrFallback();
      expect(openedTab, isTrue);
      expect(handle1.openTabCalls, 1);

      // Troca para item2: descarta imediatamente bytes de item1 e revoga URL blob: de item1
      reviewerController.selectQueueItem(item2);
      expect(payload1.isWiped, isTrue);
      expect(payload1.bytes.every((b) => b == 0), isTrue);
      expect(handle1.isRevoked, isTrue);
      expect(trackingWebBridge.revokedUrls, contains(handle1.objectUrl));
      expect(reviewerController.loadedPdf, isNull);

      // Carrega PDF de item2 e executa logout com o visualizador aberto
      final loaded2Ok = await reviewerController
          .loadAuthenticatedPdfForSelected();
      expect(loaded2Ok, isTrue);
      final payload2 = reviewerController.loadedPdf!;
      final handle2 = trackingWebBridge.createdHandles.last;
      expect(payload2.isWiped, isFalse);
      expect(handle2.isRevoked, isFalse);

      // Logout com PDF aberto
      reviewerController.clearPrivateState();
      await authController.signOut();
      expect(payload2.isWiped, isTrue);
      expect(payload2.bytes.every((b) => b == 0), isTrue);
      expect(handle2.isRevoked, isTrue);
      expect(trackingWebBridge.revokedUrls, contains(handle2.objectUrl));
      expect(reviewerController.loadedPdf, isNull);
      expect(reviewerController.queueItems, isEmpty);
      expect(reviewerController.selectedItem, isNull);
      expect(reviewerController.timelineController.events, isEmpty);

      // 3) Login de revisor.r2@demo.local (sem escopo): fila vazia e zero dados residuais
      await authController.signIn(
        email: 'revisor.r2@demo.local',
        password: demoPassword,
      );
      expect(authController.status, AuthViewStatus.authenticatedReviewer);
      await reviewerController.loadQueue();
      expect(reviewerController.totalQueueCount, 0);
      expect(reviewerController.queueItems, isEmpty);
      expect(reviewerController.loadedPdf, isNull);
    },
  );
}
