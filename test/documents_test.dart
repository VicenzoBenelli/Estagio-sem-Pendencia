import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show FunctionException, StorageException, PostgrestException, AuthException;

import 'package:estagio_sem_pendencia/app/app.dart';
import 'package:estagio_sem_pendencia/features/auth/application/auth_controller.dart';
import 'package:estagio_sem_pendencia/features/auth/domain/auth_gateway.dart';
import 'package:estagio_sem_pendencia/features/auth/domain/user_profile.dart';
import 'package:estagio_sem_pendencia/features/processes/application/document_submission_controller.dart';
import 'package:estagio_sem_pendencia/features/processes/application/process_controller.dart';
import 'package:estagio_sem_pendencia/features/processes/data/supabase_document_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/document_models.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/document_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/process_models.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/process_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/presentation/requirement_documents_section.dart';
import 'package:estagio_sem_pendencia/features/processes/presentation/student_processes_workspace.dart';

Uint8List _sampleValidPdfBytes([String tag = 'Estagio Demo']) {
  return Uint8List.fromList(
    '%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n% $tag\nstartxref\n0\n%%EOF\n'
        .codeUnits,
  );
}

class _DocTestAuthGateway implements AuthGateway {
  _DocTestAuthGateway({this.restoredProfile});

  final StreamController<AuthGatewayEvent> _events =
      StreamController<AuthGatewayEvent>.broadcast();

  UserProfile? restoredProfile;
  UserProfile? signInProfile;

  @override
  bool get hasCurrentSession => restoredProfile != null;

  @override
  Stream<AuthGatewayEvent> get onAuthEvents => _events.stream;

  Future<void> dispose() => _events.close();

  @override
  Future<UserProfile?> restoreAndValidateSession() async => restoredProfile;

  @override
  Future<UserProfile> fetchCurrentProfile() async =>
      restoredProfile ?? signInProfile!;

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    return const SignUpOutcome(requiresEmailConfirmation: true);
  }

  @override
  Future<UserProfile> signIn({
    required String email,
    required String password,
  }) async {
    final profile = signInProfile ?? restoredProfile!;
    restoredProfile = profile;
    return profile;
  }

  @override
  Future<void> signOut() async {
    restoredProfile = null;
    _events.add(const AuthGatewayEvent(kind: AuthEventKind.signedOut));
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {}

  @override
  Future<void> updatePassword({required String newPassword}) async {}
}

class _DocTestProcessRepository implements ProcessRepository {
  _DocTestProcessRepository({
    required List<InternshipProcessSummary> processes,
    required Map<String, ProcessDetailBundle?> details,
  }) : _processes = List<InternshipProcessSummary>.from(processes),
       _details = Map<String, ProcessDetailBundle?>.from(details);

  List<InternshipProcessSummary> _processes;
  final Map<String, ProcessDetailBundle?> _details;
  int fetchDetailCalls = 0;
  int fetchProcessesCalls = 0;
  final List<String> fetchedDetailProcessIds = <String>[];
  Future<List<InternshipProcessSummary>> Function()? onFetchStudentProcesses;
  Future<ProcessDetailBundle?> Function(String processId)? onFetchProcessDetail;

  void updateDetail(String processId, ProcessDetailBundle bundle) {
    _details[processId] = bundle;
    _processes = _processes
        .map(
          (p) => p.id == processId ? p.copyWith(progress: bundle.progress) : p,
        )
        .toList(growable: false);
  }

  @override
  Future<List<CatalogModalityOption>> fetchActiveCatalog() async =>
      const <CatalogModalityOption>[];

  @override
  Future<List<InternshipProcessSummary>> fetchStudentProcesses() async {
    fetchProcessesCalls++;
    if (onFetchStudentProcesses != null) {
      return onFetchStudentProcesses!();
    }
    return List<InternshipProcessSummary>.from(_processes);
  }

  @override
  Future<InternshipProcessSummary> createProcess({
    required String courseModalityId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ProcessDetailBundle?> fetchProcessDetail({
    required String processId,
  }) async {
    fetchDetailCalls++;
    fetchedDetailProcessIds.add(processId);
    if (onFetchProcessDetail != null) {
      return onFetchProcessDetail!(processId);
    }
    return _details[processId];
  }
}

class _FakePdfPickerGateway implements PdfPickerGateway {
  _FakePdfPickerGateway({this.nextPickedFile});

  SelectedPdfFile? nextPickedFile;
  bool saveResult = true;
  int pickCalls = 0;
  int saveCalls = 0;
  String? lastSavedFilename;
  Uint8List? lastSavedBytes;

  @override
  Future<SelectedPdfFile?> pickPdf() async {
    pickCalls++;
    return nextPickedFile;
  }

  @override
  Future<bool> savePdf({
    required String filename,
    required Uint8List bytes,
  }) async {
    saveCalls++;
    lastSavedFilename = filename;
    lastSavedBytes = Uint8List.fromList(bytes);
    return saveResult;
  }
}

class _FakeDocumentRepository implements DocumentRepository {
  _FakeDocumentRepository({
    Map<String, List<DocumentSubmissionRecord>>? submissionsByReq,
    Map<String, List<DocumentReviewRecord>>? reviewsByReq,
    Map<String, Uint8List>? storageBytesByPath,
  }) : submissionsByReq = Map<String, List<DocumentSubmissionRecord>>.from(
         submissionsByReq ?? <String, List<DocumentSubmissionRecord>>{},
       ),
       reviewsByReq = Map<String, List<DocumentReviewRecord>>.from(
         reviewsByReq ?? <String, List<DocumentReviewRecord>>{},
       ),
       storageBytesByPath = Map<String, Uint8List>.from(
         storageBytesByPath ?? <String, Uint8List>{},
       );

  final Map<String, List<DocumentSubmissionRecord>> submissionsByReq;
  final Map<String, List<DocumentReviewRecord>> reviewsByReq;
  final Map<String, Uint8List> storageBytesByPath;

  final List<String> submittedIdempotencyKeys = <String>[];
  final List<String> reconciledIdempotencyKeys = <String>[];
  final List<String> downloadRequests = <String>[];

  int submitCalls = 0;
  int fetchHistoryCalls = 0;

  Completer<SubmitPdfOutcome>? pendingSubmit;
  Completer<List<DocumentSubmissionRecord>>? pendingFetchHistory;
  Completer<Uint8List>? pendingDownload;

  Object? nextSubmitError;
  Object? nextFetchHistoryError;
  Object? nextDownloadError;

  Future<SubmitPdfOutcome> Function({
    required String processRequirementId,
    required SelectedPdfFile file,
    required String idempotencyKey,
  })?
  onSubmit;

  @override
  Future<SubmitPdfOutcome> submitRequirementPdf({
    required String processRequirementId,
    required SelectedPdfFile file,
    required String idempotencyKey,
  }) async {
    submitCalls++;
    submittedIdempotencyKeys.add(idempotencyKey);

    if (pendingSubmit != null) {
      return pendingSubmit!.future;
    }
    if (nextSubmitError != null) {
      throw nextSubmitError!;
    }
    if (onSubmit != null) {
      return onSubmit!(
        processRequirementId: processRequirementId,
        file: file,
        idempotencyKey: idempotencyKey,
      );
    }

    final existing = submissionsByReq[processRequirementId] ?? const [];
    final match = existing
        .where((s) => s.idempotencyKey == idempotencyKey)
        .firstOrNull;
    if (match != null) {
      return SubmitPdfOutcome(
        submission: match,
        idempotentReplay: true,
        requirementStatus: RequirementStatus.underReview,
        currentVersion: match.version,
        currentSubmissionId: match.id,
      );
    }

    final nextVersion =
        (existing.map((e) => e.version).fold<int>(0, (a, b) => a > b ? a : b)) +
        1;
    final sub = DocumentSubmissionRecord(
      id: 'sub-$processRequirementId-v$nextVersion',
      processId: 'proc-1',
      processRequirementId: processRequirementId,
      submittedBy: 'student-a',
      version: nextVersion,
      storageBucket: kPrivateDocumentsBucket,
      storagePath:
          'processes/proc-1/requirements/$processRequirementId/submissions/uuid-v$nextVersion.pdf',
      originalFilename: file.basename,
      mimeType: 'application/pdf',
      sizeBytes: file.sizeBytes,
      sha256Checksum: 'a' * 64,
      idempotencyKey: idempotencyKey,
      status: SubmissionStatus.underReview,
      submittedAt: DateTime(2026, 11, 18, 10, 30),
      createdAt: DateTime(2026, 11, 18, 10, 30),
    );
    submissionsByReq[processRequirementId] = <DocumentSubmissionRecord>[
      sub,
      ...existing,
    ];
    storageBytesByPath[sub.storagePath] = Uint8List.fromList(file.bytes);

    return SubmitPdfOutcome(
      submission: sub,
      idempotentReplay: false,
      requirementStatus: RequirementStatus.underReview,
      currentVersion: nextVersion,
      currentSubmissionId: sub.id,
    );
  }

  @override
  Future<DocumentSubmissionRecord?> findSubmissionByIdempotencyKey({
    required String processRequirementId,
    required String idempotencyKey,
  }) async {
    reconciledIdempotencyKeys.add(idempotencyKey);
    final items = submissionsByReq[processRequirementId] ?? const [];
    for (final item in items) {
      if (item.idempotencyKey == idempotencyKey) {
        return item;
      }
    }
    return null;
  }

  @override
  Future<List<DocumentSubmissionRecord>> fetchRequirementSubmissions({
    required String processRequirementId,
  }) async {
    fetchHistoryCalls++;
    if (pendingFetchHistory != null) {
      return pendingFetchHistory!.future;
    }
    if (nextFetchHistoryError != null) {
      throw nextFetchHistoryError!;
    }
    return List<DocumentSubmissionRecord>.from(
      submissionsByReq[processRequirementId] ??
          const <DocumentSubmissionRecord>[],
    );
  }

  @override
  Future<List<DocumentReviewRecord>> fetchRequirementReviews({
    required String processRequirementId,
  }) async {
    return List<DocumentReviewRecord>.from(
      reviewsByReq[processRequirementId] ?? const <DocumentReviewRecord>[],
    );
  }

  @override
  Future<Uint8List> downloadSubmissionBytes({
    required String submissionId,
  }) async {
    downloadRequests.add(submissionId);
    if (pendingDownload != null) {
      return pendingDownload!.future;
    }
    if (nextDownloadError != null) {
      throw nextDownloadError!;
    }
    for (final subs in submissionsByReq.values) {
      for (final sub in subs) {
        if (sub.id == submissionId) {
          final bytes = storageBytesByPath[sub.storagePath];
          if (bytes != null) {
            return bytes;
          }
        }
      }
    }
    return _sampleValidPdfBytes('downloaded');
  }
}

const _studentA = UserProfile(
  id: 'student-a',
  email: 'estudante.a@demo.local',
  fullName: 'Estudante A Fictício',
  role: UserRole.student,
  active: true,
);

const _studentB = UserProfile(
  id: 'student-b',
  email: 'estudante.b@demo.local',
  fullName: 'Estudante B Fictício',
  role: UserRole.student,
  active: true,
);

const _reviewer = UserProfile(
  id: 'reviewer-1',
  email: 'revisor@demo.local',
  fullName: 'Revisor Escopo Fictício',
  role: UserRole.reviewer,
  active: true,
);

ProcessDetailBundle _buildBundle({
  String processId = 'proc-1',
  ProcessStatus processStatus = ProcessStatus.inProgress,
  required List<ProcessRequirementItem> requirements,
}) {
  final requiredItems = requirements.where((r) => r.isRequired).toList();
  final requiredApproved = requiredItems
      .where((r) => r.status == RequirementStatus.approved)
      .length;
  final requiredUnderReview = requiredItems
      .where((r) => r.status == RequirementStatus.underReview)
      .length;
  final requiredCorrection = requiredItems
      .where((r) => r.status == RequirementStatus.correctionRequested)
      .length;
  final progress = ProcessProgressSummary(
    processId: processId,
    ownerId: 'student-a',
    processStatus: processStatus,
    requiredTotal: requiredItems.length,
    requiredApproved: requiredApproved,
    requiredUnderReview: requiredUnderReview,
    requiredCorrectionRequested: requiredCorrection,
    progressStatus: requiredItems.isEmpty
        ? ProgressStatus.indeterminate
        : (requiredApproved == requiredItems.length
              ? ProgressStatus.documentallyComplete
              : ProgressStatus.inProgress),
    progressPercentage: requiredItems.isEmpty
        ? null
        : (requiredApproved / requiredItems.length) * 100.0,
  );
  final proc = InternshipProcessSummary(
    id: processId,
    ownerId: 'student-a',
    institutionId: 'inst-1',
    courseId: 'course-1',
    courseModalityId: 'mod-1',
    templateId: 'tpl-1',
    templateVersion: 1,
    status: processStatus,
    isDemo: true,
    openedAt: DateTime(2026, 11, 18),
    createdAt: DateTime(2026, 11, 18),
    updatedAt: DateTime(2026, 11, 18),
    institutionName: 'Centro Universitário Fictício',
    courseName: 'Engenharia de Software',
    modalityName: 'Estágio Obrigatório',
    templateTitle: 'Checklist Lote 3',
    progress: progress,
  );
  return ProcessDetailBundle(
    process: proc,
    requirements: requirements,
    progress: progress,
  );
}

ProcessRequirementItem _req({
  required String id,
  required String code,
  required String title,
  required RequirementStatus status,
  int currentVersion = 0,
  String? currentSubmissionId,
  int displayOrder = 1,
  bool isRequired = true,
}) {
  return ProcessRequirementItem(
    id: id,
    processId: 'proc-1',
    templateItemId: 'tpl-item-$id',
    code: code,
    title: title,
    description: 'Enviar documento PDF assinado.',
    acceptanceCriteria: 'PDF legível até 5 MiB.',
    isRequired: isRequired,
    displayOrder: displayOrder,
    status: status,
    currentSubmissionId: currentSubmissionId,
    currentVersion: currentVersion,
    createdAt: DateTime(2026, 11, 18),
    updatedAt: DateTime(2026, 11, 18),
  );
}

Future<void> _tapByKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openStudentDetail({
  required WidgetTester tester,
  required AuthController authController,
  required _DocTestProcessRepository processRepo,
  required _FakeDocumentRepository docRepo,
  required _FakePdfPickerGateway pickerGateway,
  Size surfaceSize = const Size(1280, 960),
  Key? appKey,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  await tester.pumpWidget(
    EstagioSemPendenciaApp(
      key: appKey,
      authController: authController,
      processRepository: processRepo,
      documentRepository: docRepo,
      pdfPickerGateway: pickerGateway,
    ),
  );
  await tester.pumpAndSettle();

  final detailBtn = find.byKey(const Key('open_process_detail_proc-1'));
  await tester.ensureVisible(detailBtn);
  await tester.tap(detailBtn);
  await tester.pumpAndSettle();
}

void main() {
  group('Lote 3 (ESP-13 / ESP-14 / ESP-15): Upload PDF, Versões e Download Privado', () {
    testWidgets(
      '1, 2 e 3: habilita envio apenas em not_submitted e correction_requested; bloqueia em under_review, approved e perfil revisor',
      (tester) async {
        final reqNotSubmitted = _req(
          id: 'req-1',
          code: 'REQ_NOT_SUB',
          title: 'Termo Inicial',
          status: RequirementStatus.notSubmitted,
          displayOrder: 1,
        );
        final reqCorrection = _req(
          id: 'req-2',
          code: 'REQ_CORR',
          title: 'Plano para Correção',
          status: RequirementStatus.correctionRequested,
          currentVersion: 1,
          currentSubmissionId: 'sub-req2-v1',
          displayOrder: 2,
        );
        final reqUnderReview = _req(
          id: 'req-3',
          code: 'REQ_REVIEW',
          title: 'Declaração em Análise',
          status: RequirementStatus.underReview,
          currentVersion: 1,
          currentSubmissionId: 'sub-req3-v1',
          displayOrder: 3,
        );
        final reqApproved = _req(
          id: 'req-4',
          code: 'REQ_APP',
          title: 'Seguro Aprovado',
          status: RequirementStatus.approved,
          currentVersion: 1,
          currentSubmissionId: 'sub-req4-v1',
          displayOrder: 4,
        );

        final bundle = _buildBundle(
          requirements: <ProcessRequirementItem>[
            reqNotSubmitted,
            reqCorrection,
            reqUnderReview,
            reqApproved,
          ],
        );
        final processRepo = _DocTestProcessRepository(
          processes: <InternshipProcessSummary>[bundle.process],
          details: <String, ProcessDetailBundle?>{'proc-1': bundle},
        );
        final docRepo = _FakeDocumentRepository();
        final picker = _FakePdfPickerGateway();
        final authGateway = _DocTestAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await _openStudentDetail(
          tester: tester,
          authController: authController,
          processRepo: processRepo,
          docRepo: docRepo,
          pickerGateway: picker,
        );

        expect(
          find.byKey(const Key('pick_pdf_button_REQ_NOT_SUB')),
          findsOneWidget,
        );
        expect(find.text('Selecionar PDF'), findsOneWidget);

        expect(
          find.byKey(const Key('pick_pdf_button_REQ_CORR')),
          findsOneWidget,
        );
        expect(find.text('Selecionar novo PDF (reenvio)'), findsOneWidget);

        expect(
          find.byKey(const Key('pick_pdf_button_REQ_REVIEW')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('upload_locked_notice_REQ_REVIEW')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('pick_pdf_button_REQ_APP')), findsNothing);
        expect(
          find.byKey(const Key('upload_locked_notice_REQ_APP')),
          findsOneWidget,
        );

        // Revisor autenticado na árvore principal não recebe ações nem upload de estudante
        final revGateway = _DocTestAuthGateway(restoredProfile: _reviewer);
        final revAuth = AuthController(gateway: revGateway);
        addTearDown(() async {
          revAuth.dispose();
          await revGateway.dispose();
        });
        await revAuth.initialize();
        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            key: const ValueKey('reviewer_app'),
            authController: revAuth,
            processRepository: processRepo,
            documentRepository: docRepo,
            pdfPickerGateway: picker,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Estágio sem Pendência — Revisor'), findsOneWidget);
        expect(find.text('Selecionar PDF'), findsNothing);

        // Defesa adicional: mesmo que RequirementDocumentsSection receba perfil reviewer, nunca mostra botão de envio.
        final docController = DocumentSubmissionController(
          repository: docRepo,
          pickerGateway: picker,
        );
        addTearDown(docController.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RequirementDocumentsSection(
                  item: reqNotSubmitted,
                  processStatus: ProcessStatus.inProgress,
                  userRole: _reviewer.role,
                  controller: docController,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('pick_pdf_button_REQ_NOT_SUB')),
          findsNothing,
        );
        expect(
          find.text('Apenas o estudante proprietário pode enviar documentos.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '4, 5, 6 e 7: validação local aceita PDF válido com nome/tamanho e rejeita vazio, grande, extensão errada ou bytes falsos',
      (tester) async {
        final req = _req(
          id: 'req-val',
          code: 'REQ_VAL',
          title: 'Termo de Estágio',
          status: RequirementStatus.notSubmitted,
        );
        final bundle = _buildBundle(
          requirements: <ProcessRequirementItem>[req],
        );
        final processRepo = _DocTestProcessRepository(
          processes: <InternshipProcessSummary>[bundle.process],
          details: <String, ProcessDetailBundle?>{'proc-1': bundle},
        );
        final docRepo = _FakeDocumentRepository();
        final picker = _FakePdfPickerGateway();
        final authGateway = _DocTestAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await _openStudentDetail(
          tester: tester,
          authController: authController,
          processRepo: processRepo,
          docRepo: docRepo,
          pickerGateway: picker,
        );

        // 5) Arquivo vazio
        picker.nextPickedFile = SelectedPdfFile(
          name: 'vazio.pdf',
          bytes: Uint8List(0),
        );
        await _tapByKey(tester, 'pick_pdf_button_REQ_VAL');
        expect(
          find.byKey(const Key('upload_error_banner_REQ_VAL')),
          findsOneWidget,
        );
        expect(find.textContaining('vazio'), findsOneWidget);
        expect(
          find.byKey(const Key('submit_pdf_button_REQ_VAL')),
          findsNothing,
        );

        // 6) PDF acima de 5 MiB
        picker.nextPickedFile = SelectedPdfFile(
          name: 'pesado.pdf',
          bytes: _sampleValidPdfBytes(),
          sizeBytes: kMaxPdfSizeBytes + 1,
        );
        await _tapByKey(tester, 'pick_pdf_button_REQ_VAL');
        expect(find.textContaining('5 MiB'), findsWidgets);
        expect(
          find.byKey(const Key('submit_pdf_button_REQ_VAL')),
          findsNothing,
        );

        // 7a) Extensão inválida (.txt)
        picker.nextPickedFile = SelectedPdfFile(
          name: 'contrato.txt',
          bytes: _sampleValidPdfBytes(),
        );
        await _tapByKey(tester, 'pick_pdf_button_REQ_VAL');
        expect(find.textContaining('.pdf'), findsWidgets);
        expect(
          find.byKey(const Key('submit_pdf_button_REQ_VAL')),
          findsNothing,
        );

        // 7b) PNG disfarçado de .pdf (sem assinatura %PDF-)
        picker.nextPickedFile = SelectedPdfFile(
          name: 'imagem.pdf',
          bytes: Uint8List.fromList(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D]),
        );
        await _tapByKey(tester, 'pick_pdf_button_REQ_VAL');
        expect(find.textContaining('%PDF-'), findsOneWidget);
        expect(
          find.byKey(const Key('submit_pdf_button_REQ_VAL')),
          findsNothing,
        );

        expect(docRepo.submitCalls, 0);

        // 4) PDF válido exibe nome, tamanho, confirmação do requisito e cancelar limpa
        picker.nextPickedFile = SelectedPdfFile(
          name: 'termo_assinado.pdf',
          bytes: _sampleValidPdfBytes('PDF Valido Teste'),
        );
        await _tapByKey(tester, 'pick_pdf_button_REQ_VAL');

        expect(
          find.byKey(const Key('selected_pdf_card_REQ_VAL')),
          findsOneWidget,
        );
        expect(find.text('termo_assinado.pdf'), findsOneWidget);
        expect(
          find.textContaining('Enviar para: Termo de Estágio (REQ_VAL)'),
          findsOneWidget,
        );
        expect(find.textContaining('Tamanho:'), findsOneWidget);

        await _tapByKey(tester, 'cancel_pdf_button_REQ_VAL');
        expect(
          find.byKey(const Key('selected_pdf_card_REQ_VAL')),
          findsNothing,
        );
        expect(docRepo.submitCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '8 e 9: duplo clique bloqueado durante envio e HTTP 201 atualiza checklist, versão, histórico e progresso sem mostrar Aprovado',
      (tester) async {
        final req = _req(
          id: 'req-up',
          code: 'REQ_UP',
          title: 'Termo de Compromisso',
          status: RequirementStatus.notSubmitted,
        );
        final initialBundle = _buildBundle(
          requirements: <ProcessRequirementItem>[req],
        );
        final processRepo = _DocTestProcessRepository(
          processes: <InternshipProcessSummary>[initialBundle.process],
          details: <String, ProcessDetailBundle?>{'proc-1': initialBundle},
        );

        final submitCompleter = Completer<SubmitPdfOutcome>();
        final docRepo = _FakeDocumentRepository()
          ..pendingSubmit = submitCompleter;
        final validPdfBytes = _sampleValidPdfBytes('Envio V1');
        final picker = _FakePdfPickerGateway(
          nextPickedFile: SelectedPdfFile(
            name: 'tce_v1.pdf',
            bytes: validPdfBytes,
          ),
        );

        final authGateway = _DocTestAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await _openStudentDetail(
          tester: tester,
          authController: authController,
          processRepo: processRepo,
          docRepo: docRepo,
          pickerGateway: picker,
        );

        await _tapByKey(tester, 'pick_pdf_button_REQ_UP');

        final submitBtnFinder = find.byKey(
          const Key('submit_pdf_button_REQ_UP'),
        );
        await tester.ensureVisible(submitBtnFinder);
        await tester.tap(submitBtnFinder);
        await tester.pump();

        // 8) Botão bloqueado e indicador de envio ativo enquanto requisição está pendente
        expect(find.byKey(const Key('upload_progress_REQ_UP')), findsOneWidget);
        final disabledSubmitBtn = tester.widget<FilledButton>(submitBtnFinder);
        expect(disabledSubmitBtn.onPressed, isNull);

        await tester.tap(submitBtnFinder, warnIfMissed: false);
        await tester.pump();
        expect(docRepo.submitCalls, 1);

        // Simular commit confirmado pelo banco + Edge Function
        final persistedSub = DocumentSubmissionRecord(
          id: 'sub-v1-real',
          processId: 'proc-1',
          processRequirementId: 'req-up',
          submittedBy: 'student-a',
          version: 1,
          storageBucket: kPrivateDocumentsBucket,
          storagePath:
              'processes/proc-1/requirements/req-up/submissions/uuid-1.pdf',
          originalFilename: 'tce_v1.pdf',
          mimeType: 'application/pdf',
          sizeBytes: validPdfBytes.lengthInBytes,
          sha256Checksum: 'b' * 64,
          idempotencyKey: docRepo.submittedIdempotencyKeys.single,
          status: SubmissionStatus.underReview,
          submittedAt: DateTime(2026, 11, 18, 11, 15),
          createdAt: DateTime(2026, 11, 18, 11, 15),
        );
        docRepo.submissionsByReq['req-up'] = <DocumentSubmissionRecord>[
          persistedSub,
        ];
        docRepo.storageBytesByPath[persistedSub.storagePath] = validPdfBytes;

        final updatedBundle = _buildBundle(
          requirements: <ProcessRequirementItem>[
            _req(
              id: 'req-up',
              code: 'REQ_UP',
              title: 'Termo de Compromisso',
              status: RequirementStatus.underReview,
              currentVersion: 1,
              currentSubmissionId: 'sub-v1-real',
            ),
          ],
        );
        processRepo.updateDetail('proc-1', updatedBundle);

        submitCompleter.complete(
          SubmitPdfOutcome(
            submission: persistedSub,
            idempotentReplay: false,
            requirementStatus: RequirementStatus.underReview,
            currentVersion: 1,
            currentSubmissionId: 'sub-v1-real',
          ),
        );
        await tester.pumpAndSettle();

        // 9) Mensagem obrigatória, status Em análise, v1 no histórico e jamais "Aprovado" no card
        expect(
          find.byKey(const Key('upload_success_banner_REQ_UP')),
          findsOneWidget,
        );
        expect(
          find.text('Documento recebido e enviado para análise.'),
          findsOneWidget,
        );
        expect(find.text('Em análise'), findsWidgets);
        expect(find.text('Versão da submissão: v1'), findsOneWidget);
        expect(find.text('Em análise: 1'), findsOneWidget);
        expect(
          find.byKey(const Key('current_version_badge_REQ_UP_v1')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('selected_pdf_card_REQ_UP')), findsNothing);
        // O botão de upload foi removido após transição para under_review
        expect(find.byKey(const Key('pick_pdf_button_REQ_UP')), findsNothing);
        // Verificar que o status retornado do upload nunca diz Aprovado
        expect(
          find.descendant(
            of: find.byKey(const Key('requirement_card_REQ_UP')),
            matching: find.text('Aprovado'),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    test('10, 11 e 12: timeout não marca sucesso, preserva idempotency_key no retry, reconcilia persistência e trata replay 200 sem duplicar versão', () async {
      final req = _req(
        id: 'req-idem',
        code: 'REQ_IDEM',
        title: 'Termo Idempotente',
        status: RequirementStatus.notSubmitted,
      );
      final docRepo = _FakeDocumentRepository();
      final picker = _FakePdfPickerGateway();
      final pdfBytes = _sampleValidPdfBytes('Retry PDF');

      var refreshedProcessCount = 0;
      final controller = DocumentSubmissionController(
        repository: docRepo,
        pickerGateway: picker,
        onSubmissionCommitted: (_) async {
          refreshedProcessCount++;
        },
      );
      addTearDown(controller.dispose);

      final selected = controller.selectPdfFileForRequirement(
        req,
        SelectedPdfFile(name: 'retry_doc.pdf', bytes: pdfBytes),
        processStatus: ProcessStatus.inProgress,
        userRole: UserRole.student,
      );
      expect(selected, isTrue);
      final firstIdempotencyKey = controller.pendingIdempotencyKey;
      expect(firstIdempotencyKey, isNotNull);

      // 11) Timeout no 1º envio: consulta findSubmissionByIdempotencyKey e NÃO encontra -> preserva arquivo e key
      docRepo.nextSubmitError = TimeoutException('timeout');
      final attempt1 = await controller.submitSelectedPdf(
        requirement: req,
        processStatus: ProcessStatus.inProgress,
        userRole: UserRole.student,
      );
      expect(attempt1, isFalse);
      expect(docRepo.reconciledIdempotencyKeys, <String>[firstIdempotencyKey!]);
      expect(controller.hasAmbiguousRetryPending, isTrue);
      expect(controller.selectedFile, isNotNull);
      expect(controller.pendingIdempotencyKey, firstIdempotencyKey);
      expect(controller.uploadSuccessMessage, isNull);
      expect(controller.uploadErrorMessage, contains('Tempo esgotado'));

      // 10 & 12) Retry manual com o MESMO idempotency_key recebe resposta idempotente 200 sem criar v2
      final v1Sub = DocumentSubmissionRecord(
        id: 'sub-idem-v1',
        processId: 'proc-1',
        processRequirementId: 'req-idem',
        submittedBy: 'student-a',
        version: 1,
        storageBucket: kPrivateDocumentsBucket,
        storagePath:
            'processes/proc-1/requirements/req-idem/submissions/uuid-idem.pdf',
        originalFilename: 'retry_doc.pdf',
        mimeType: 'application/pdf',
        sizeBytes: pdfBytes.lengthInBytes,
        sha256Checksum: 'c' * 64,
        idempotencyKey: firstIdempotencyKey,
        status: SubmissionStatus.underReview,
        submittedAt: DateTime(2026, 11, 18, 12, 0),
        createdAt: DateTime(2026, 11, 18, 12, 0),
      );
      docRepo.nextSubmitError = null;
      docRepo.submissionsByReq['req-idem'] = <DocumentSubmissionRecord>[v1Sub];

      final attempt2 = await controller.submitSelectedPdf(
        requirement: req,
        processStatus: ProcessStatus.inProgress,
        userRole: UserRole.student,
      );
      expect(attempt2, isTrue);
      expect(docRepo.submittedIdempotencyKeys, <String>[
        firstIdempotencyKey,
        firstIdempotencyKey,
      ]);
      expect(
        controller.uploadSuccessMessage,
        contains('Documento recebido e enviado para análise'),
      );
      expect(controller.submissionsForRequirement('req-idem').length, 1);
      expect(
        controller.submissionsForRequirement('req-idem').single.version,
        1,
      );
      expect(refreshedProcessCount, 1);

      // Reconciliação automática: se timeout acontece mas o banco já havia persistido com aquele idempotency_key,
      // controller confirma sem precisar reenviar.
      final req2 = _req(
        id: 'req-reconcile',
        code: 'REQ_REC',
        title: 'Reconciliação Automática',
        status: RequirementStatus.correctionRequested,
        currentVersion: 1,
      );
      controller.selectPdfFileForRequirement(
        req2,
        SelectedPdfFile(name: 'v2.pdf', bytes: _sampleValidPdfBytes('v2')),
        processStatus: ProcessStatus.inProgress,
        userRole: UserRole.student,
      );
      final key2 = controller.pendingIdempotencyKey!;
      final persistedV2 = DocumentSubmissionRecord(
        id: 'sub-rec-v2',
        processId: 'proc-1',
        processRequirementId: 'req-reconcile',
        submittedBy: 'student-a',
        version: 2,
        storageBucket: kPrivateDocumentsBucket,
        storagePath: 'processes/proc-1/requirements/req-reconcile/submissions/uuid-v2.pdf',
        originalFilename: 'v2.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 70,
        sha256Checksum: 'd' * 64,
        idempotencyKey: key2,
        status: SubmissionStatus.underReview,
        submittedAt: DateTime(2026, 11, 18, 12, 5),
        createdAt: DateTime(2026, 11, 18, 12, 5),
      );
      docRepo.onSubmit =
          ({
            required String processRequirementId,
            required SelectedPdfFile file,
            required String idempotencyKey,
          }) async {
            // Simula que o backend commitou v2 antes da resposta cair na rede
            docRepo.submissionsByReq[processRequirementId] =
                <DocumentSubmissionRecord>[persistedV2];
            throw TimeoutException('conexão encerrada após commit');
          };

      final reconciled = await controller.submitSelectedPdf(
        requirement: req2,
        processStatus: ProcessStatus.inProgress,
        userRole: UserRole.student,
      );
      expect(reconciled, isTrue);
      expect(controller.selectedFile, isNull);
      expect(controller.hasAmbiguousRetryPending, isFalse);
    });

    testWidgets(
      '13, 14 e download privado: histórico ordena versões, identifica versão vigente via current_submission_id e baixa via storage privado',
      (tester) async {
        final subV1 = DocumentSubmissionRecord(
          id: 'sub-v1-id',
          processId: 'proc-1',
          processRequirementId: 'req-hist',
          submittedBy: 'student-a',
          version: 1,
          storageBucket: kPrivateDocumentsBucket,
          storagePath:
              'processes/proc-1/requirements/req-hist/submissions/obj-v1.pdf',
          originalFilename: 'termo_antigo_v1.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 1536,
          sha256Checksum: 'e' * 64,
          status: SubmissionStatus.correctionRequested,
          submittedAt: DateTime(2026, 11, 17, 14, 20),
          createdAt: DateTime(2026, 11, 17, 14, 20),
        );
        final subV2 = DocumentSubmissionRecord(
          id: 'sub-v2-id',
          processId: 'proc-1',
          processRequirementId: 'req-hist',
          submittedBy: 'student-a',
          version: 2,
          storageBucket: kPrivateDocumentsBucket,
          storagePath:
              'processes/proc-1/requirements/req-hist/submissions/obj-v2.pdf',
          originalFilename: 'termo_atual_v2.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 2560,
          sha256Checksum: 'f' * 64,
          status: SubmissionStatus.underReview,
          submittedAt: DateTime(2026, 11, 18, 9, 45),
          createdAt: DateTime(2026, 11, 18, 9, 45),
        );

        // API propositalmente retorna [subV1, subV2] (v2 por último) e current_submission_id aponta para subV1
        // para comprovar que a UI identifica a versão vigente por current_submission_id, e NÃO por posição no array.
        final req = _req(
          id: 'req-hist',
          code: 'REQ_HIST',
          title: 'Histórico Versionado',
          status: RequirementStatus.correctionRequested,
          currentVersion: 1,
          currentSubmissionId: 'sub-v1-id',
        );
        final bundle = _buildBundle(
          requirements: <ProcessRequirementItem>[req],
        );
        final processRepo = _DocTestProcessRepository(
          processes: <InternshipProcessSummary>[bundle.process],
          details: <String, ProcessDetailBundle?>{'proc-1': bundle},
        );
        final expectedV2Bytes = _sampleValidPdfBytes('Conteudo V2 Privado');
        final docRepo = _FakeDocumentRepository(
          submissionsByReq: <String, List<DocumentSubmissionRecord>>{
            'req-hist': <DocumentSubmissionRecord>[subV1, subV2],
          },
          reviewsByReq: <String, List<DocumentReviewRecord>>{
            'req-hist': <DocumentReviewRecord>[
              DocumentReviewRecord(
                id: 'rev-1',
                processId: 'proc-1',
                processRequirementId: 'req-hist',
                submissionId: 'sub-v1-id',
                reviewerId: 'reviewer-1',
                decision: ReviewDecision.correctionRequested,
                reason: 'Assinatura ausente na folha 2.',
                reviewedAt: DateTime(2026, 11, 17, 16, 0),
              ),
            ],
          },
          storageBytesByPath: <String, Uint8List>{
            subV2.storagePath: expectedV2Bytes,
          },
        );
        final picker = _FakePdfPickerGateway();
        final authGateway = _DocTestAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await _openStudentDetail(
          tester: tester,
          authController: authController,
          processRepo: processRepo,
          docRepo: docRepo,
          pickerGateway: picker,
        );

        expect(
          find.byKey(const Key('submission_version_row_REQ_HIST_v2')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('submission_version_row_REQ_HIST_v1')),
          findsOneWidget,
        );

        // v2 aparece primeiro visualmente (ordenação decrescente por versão)
        final v2Top = tester
            .getTopLeft(
              find.byKey(const Key('submission_version_row_REQ_HIST_v2')),
            )
            .dy;
        final v1Top = tester
            .getTopLeft(
              find.byKey(const Key('submission_version_row_REQ_HIST_v1')),
            )
            .dy;
        expect(v2Top, lessThan(v1Top));

        // 14) Versão vigente é determinada exclusivamente por current_submission_id ('sub-v1-id')
        expect(
          find.byKey(const Key('current_version_badge_REQ_HIST_v1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('current_version_badge_REQ_HIST_v2')),
          findsNothing,
        );

        // Campos exigidos e motivo persistido da revisão
        expect(find.text('termo_antigo_v1.pdf'), findsOneWidget);
        expect(find.text('termo_atual_v2.pdf'), findsOneWidget);
        expect(
          find.textContaining('Assinatura ausente na folha 2.'),
          findsOneWidget,
        );
        expect(find.textContaining('1.5 KB'), findsOneWidget);
        expect(find.textContaining('2.5 KB'), findsOneWidget);
        expect(find.textContaining('17/11/2026'), findsOneWidget);

        // Download privado usa bucket privado e storage_path sem getPublicUrl
        final downloadBtn = find.byKey(
          const Key('download_submission_button_REQ_HIST_v2'),
        );
        await tester.ensureVisible(downloadBtn);
        await tester.tap(downloadBtn);
        await tester.pumpAndSettle();

        expect(docRepo.downloadRequests, <String>[subV2.id]);
        expect(picker.saveCalls, 1);
        expect(picker.lastSavedFilename, 'termo_atual_v2.pdf');
        expect(picker.lastSavedBytes, expectedV2Bytes);
        expect(tester.takeException(), isNull);
      },
    );

    test('15: erro 403 e códigos HTTP/Storage/PostgREST são mapeados com mensagens seguras sem vazar SQL, JWT ou paths internos', () {
      const sensitiveToken = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.secret';
      final cases = <(int status, String code, String mustNotContain)>[
        (403, 'forbidden_owner', 'ERROR: [ERR:forbidden_owner] owner=123'),
        (403, 'forbidden_inactive_profile', 'profiles.active = false'),
        (400, 'empty_file', 'sqlstate 22023'),
        (400, 'invalid_submission_id', 'uuid parse error'),
        (400, 'unsupported_destination_parameter', 'storage_path supplied'),
        (401, 'invalid_or_expired_session', sensitiveToken),
        (404, 'requirement_not_found', 'SELECT * FROM process_requirements'),
        (404, 'submission_not_found', 'SELECT * FROM document_submissions'),
        (409, 'requirement_status_conflict', 'uq_document_submissions'),
        (413, 'file_too_large', '5242880 stack trace'),
        (415, 'unsupported_media_type', '/storage/v1/object'),
        (422, 'truncated_or_corrupted_pdf', 'startxref raw error'),
        (502, 'storage_upload_failed', 'supabase_storage_admin'),
        (500, 'unexpected', 'pg_catalog stack'),
      ];

      for (final c in cases) {
        final failure = SupabaseDocumentRepository.mapError(
          FunctionException(
            status: c.$1,
            details: <String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{'code': c.$2, 'message': c.$3},
            },
          ),
        );
        expect(failure.httpStatus, c.$1);
        expect(failure.message.isNotEmpty, isTrue);
        expect(failure.message.contains(sensitiveToken), isFalse);
        expect(failure.message.contains('SELECT *'), isFalse);
        expect(failure.message.contains('sqlstate'), isFalse);
        expect(failure.message.contains('stack trace'), isFalse);
        expect(failure.message.contains('pg_catalog'), isFalse);
      }

      final storage403 = SupabaseDocumentRepository.mapError(
        const StorageException(
          'new row violates row-level security policy',
          statusCode: '403',
        ),
      );
      expect(storage403.isUnauthorized, isTrue);
      expect(storage403.message, isNot(contains('row-level security')));

      final pg42501 = SupabaseDocumentRepository.mapError(
        const PostgrestException(
          message: 'permission denied for table document_submission_intents',
          code: '42501',
        ),
      );
      expect(pg42501.isUnauthorized, isTrue);
      expect(pg42501.message, isNot(contains('document_submission_intents')));

      final authErr = SupabaseDocumentRepository.mapError(
        const AuthException('JWT expired'),
      );
      expect(authErr.isUnauthorized, isTrue);
      expect(authErr.message, isNot(contains('JWT')));
    });

    testWidgets(
      '16 e 17: logout limpa bytes e histórico e requisições tardias de upload/histórico/download não contaminam nova sessão ou pós-dispose',
      (tester) async {
        final reqA = _req(
          id: 'req-a-secret',
          code: 'REQ_SECRET_A',
          title: 'Documento Secreto Estudante A',
          status: RequirementStatus.notSubmitted,
        );
        final bundleA = _buildBundle(
          requirements: <ProcessRequirementItem>[reqA],
        );
        final reqB = _req(
          id: 'req-b-clean',
          code: 'REQ_CLEAN_B',
          title: 'Documento Estudante B',
          status: RequirementStatus.notSubmitted,
        );
        final bundleB = _buildBundle(
          requirements: <ProcessRequirementItem>[reqB],
        );

        final processRepo = _DocTestProcessRepository(
          processes: <InternshipProcessSummary>[bundleA.process],
          details: <String, ProcessDetailBundle?>{'proc-1': bundleA},
        );

        final pendingUploadA = Completer<SubmitPdfOutcome>();
        final pendingHistoryA = Completer<List<DocumentSubmissionRecord>>();
        final docRepo = _FakeDocumentRepository()
          ..pendingSubmit = pendingUploadA;
        final picker = _FakePdfPickerGateway(
          nextPickedFile: SelectedPdfFile(
            name: 'sigilo_a.pdf',
            bytes: _sampleValidPdfBytes('Sigilo A'),
          ),
        );

        final authGateway = _DocTestAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await _openStudentDetail(
          tester: tester,
          authController: authController,
          processRepo: processRepo,
          docRepo: docRepo,
          pickerGateway: picker,
        );

        await _tapByKey(tester, 'pick_pdf_button_REQ_SECRET_A');
        expect(find.text('sigilo_a.pdf'), findsOneWidget);

        final submitSecretFinder = find.byKey(
          const Key('submit_pdf_button_REQ_SECRET_A'),
        );
        await tester.ensureVisible(submitSecretFinder);
        await tester.tap(submitSecretFinder);
        await tester.pump();

        // Logout enquanto upload de A ainda está pendente
        final logoutBtn = find.byKey(const Key('logout_button'));
        await tester.ensureVisible(logoutBtn);
        await tester.tap(logoutBtn);
        await tester.pumpAndSettle();
        expect(find.text('Entrar na conta'), findsOneWidget);

        // Prepara sessão do Estudante B e faz login
        processRepo.updateDetail('proc-1', bundleB);
        docRepo.pendingSubmit = null;
        authGateway.signInProfile = _studentB;
        await authController.signIn(
          email: _studentB.email,
          password: 'DemoPassword!123',
        );
        await tester.pumpAndSettle();

        // Conclui tardiamente o upload pendente do Estudante A após entrada de B
        pendingUploadA.complete(
          SubmitPdfOutcome(
            submission: DocumentSubmissionRecord(
              id: 'sub-late-a',
              processId: 'proc-1',
              processRequirementId: 'req-a-secret',
              submittedBy: 'student-a',
              version: 1,
              storageBucket: kPrivateDocumentsBucket,
              storagePath: 'processes/proc-1/requirements/req-a/sub-late.pdf',
              originalFilename: 'sigilo_a.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 120,
              status: SubmissionStatus.underReview,
              submittedAt: DateTime(2026, 11, 18),
              createdAt: DateTime(2026, 11, 18),
            ),
            idempotentReplay: false,
            requirementStatus: RequirementStatus.underReview,
            currentVersion: 1,
            currentSubmissionId: 'sub-late-a',
          ),
        );
        await tester.pumpAndSettle();

        // Nenhum dado ou banner do upload de A aparece para B
        expect(find.text('sigilo_a.pdf'), findsNothing);
        expect(
          find.text('Documento recebido e enviado para análise.'),
          findsNothing,
        );

        // Teste direto de ciclo de vida no DocumentSubmissionController: clearPrivateState + dispose
        final lateHistoryRepo = _FakeDocumentRepository()
          ..pendingFetchHistory = pendingHistoryA;
        final lateDownloadCompleter = Completer<Uint8List>();
        lateHistoryRepo.pendingDownload = lateDownloadCompleter;

        final directCtrl = DocumentSubmissionController(
          repository: lateHistoryRepo,
          pickerGateway: picker,
        );
        var isDisposed = false;
        var notificationsAfterDispose = 0;
        directCtrl.addListener(() {
          if (isDisposed) {
            notificationsAfterDispose++;
          }
        });

        final histFuture = directCtrl.loadHistoryForRequirement('req-a-secret');
        directCtrl.clearPrivateState();
        isDisposed = true;
        directCtrl.dispose();

        pendingHistoryA.complete(<DocumentSubmissionRecord>[
          DocumentSubmissionRecord(
            id: 'sub-orphan',
            processId: 'proc-1',
            processRequirementId: 'req-a-secret',
            submittedBy: 'student-a',
            version: 1,
            storageBucket: kPrivateDocumentsBucket,
            storagePath: 'processes/proc-1/req-a/x.pdf',
            originalFilename: 'sigilo_a.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 100,
            status: SubmissionStatus.underReview,
            submittedAt: DateTime(2026, 11, 18),
            createdAt: DateTime(2026, 11, 18),
          ),
        ]);
        await histFuture;

        expect(notificationsAfterDispose, 0);
        expect(directCtrl.submissionsForRequirement('req-a-secret'), isEmpty);
        expect(directCtrl.selectedFile, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '18: layout Android compacto (320x640 e 360x780) sem overflow com nome de arquivo longo e histórico expandido',
      (tester) async {
        final subV1 = DocumentSubmissionRecord(
          id: 'sub-mob-v1',
          processId: 'proc-1',
          processRequirementId: 'req-mob',
          submittedBy: 'student-a',
          version: 1,
          storageBucket: kPrivateDocumentsBucket,
          storagePath:
              'processes/proc-1/requirements/req-mob/submissions/1.pdf',
          originalFilename: 'termo_de_compromisso_de_estagio_supervisionado_assinado_completo_v1.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 345678,
          status: SubmissionStatus.correctionRequested,
          submittedAt: DateTime(2026, 11, 17, 9, 0),
          createdAt: DateTime(2026, 11, 17, 9, 0),
        );
        final req = _req(
          id: 'req-mob',
          code: 'REQ_MOB_CHECKLIST',
          title: 'Termo de Compromisso de Estágio Obrigatório Completo',
          status: RequirementStatus.correctionRequested,
          currentVersion: 1,
          currentSubmissionId: 'sub-mob-v1',
        );
        final bundle = _buildBundle(
          requirements: <ProcessRequirementItem>[req],
        );
        final processRepo = _DocTestProcessRepository(
          processes: <InternshipProcessSummary>[bundle.process],
          details: <String, ProcessDetailBundle?>{'proc-1': bundle},
        );
        final docRepo = _FakeDocumentRepository(
          submissionsByReq: <String, List<DocumentSubmissionRecord>>{
            'req-mob': <DocumentSubmissionRecord>[subV1],
          },
        );
        final picker = _FakePdfPickerGateway(
          nextPickedFile: SelectedPdfFile(
            name: 'termo_compromisso_corrigido_versao_2_assinado_estudante_instituicao.pdf',
            bytes: _sampleValidPdfBytes('Mobile Compact PDF'),
          ),
        );
        final authGateway = _DocTestAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        for (final size in const <Size>[Size(320, 640), Size(360, 780)]) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await _openStudentDetail(
            tester: tester,
            authController: authController,
            processRepo: processRepo,
            docRepo: docRepo,
            pickerGateway: picker,
            surfaceSize: size,
            appKey: ValueKey('compact_app_${size.width}_${size.height}'),
          );

          final pickBtn = find.byKey(
            const Key('pick_pdf_button_REQ_MOB_CHECKLIST'),
          );
          await tester.ensureVisible(pickBtn);
          await tester.tap(pickBtn);
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('selected_pdf_card_REQ_MOB_CHECKLIST')),
            findsOneWidget,
          );
          expect(
            find.byKey(
              const Key('download_submission_button_REQ_MOB_CHECKLIST_v1'),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      },
    );

    test('19 (C3-04): refreshAfterDocumentUpdate de processo A não invalida carregamento pendente do detalhe de B e preserva descarte obsoleto/logout/dispose', () async {
      final reqA = _req(
        id: 'req-proc-a',
        code: 'REQ_A',
        title: 'Documento A',
        status: RequirementStatus.underReview,
        currentVersion: 1,
        currentSubmissionId: 'sub-a-v1',
      );
      final reqB = _req(
        id: 'req-proc-b',
        code: 'REQ_B',
        title: 'Documento B',
        status: RequirementStatus.notSubmitted,
      );
      final bundleA = _buildBundle(
        processId: 'proc-A',
        requirements: <ProcessRequirementItem>[reqA],
      );
      final bundleB = _buildBundle(
        processId: 'proc-B',
        requirements: <ProcessRequirementItem>[reqB],
      );

      final repo = _DocTestProcessRepository(
        processes: <InternshipProcessSummary>[bundleA.process, bundleB.process],
        details: <String, ProcessDetailBundle?>{
          'proc-A': bundleA,
          'proc-B': bundleB,
        },
      );
      final controller = ProcessController(repository: repo);

      // 1) Carregamento de detalhe de B fica pendente em um Completer
      final detailBCompleter = Completer<ProcessDetailBundle?>();
      repo.onFetchProcessDetail = (processId) {
        if (processId == 'proc-B') {
          return detailBCompleter.future;
        }
        return Future<ProcessDetailBundle?>.value(
          processId == 'proc-A' ? bundleA : null,
        );
      };

      final openBFuture = controller.openProcessDetail('proc-B');
      expect(controller.detailStatus, ProcessLoadStatus.loading);
      expect(controller.activeDetailProcessId, 'proc-B');

      // 2) Upload tardio de A dispara refreshAfterDocumentUpdate('proc-A') enquanto B ainda carrega
      await controller.refreshAfterDocumentUpdate('proc-A');

      // Detalhe de A não pode ser disparado por cima de B nem invalidar a época de B
      expect(repo.fetchedDetailProcessIds, <String>['proc-B']);
      expect(controller.detailStatus, ProcessLoadStatus.loading);
      expect(controller.activeDetailProcessId, 'proc-B');

      // 3) Concluir Completer de B -> sai de loading e exibe exatamente bundleB
      detailBCompleter.complete(bundleB);
      await openBFuture;

      expect(controller.detailStatus, ProcessLoadStatus.loaded);
      expect(controller.activeDetailProcessId, 'proc-B');
      expect(controller.detailBundle?.process.id, 'proc-B');

      // 4) Resposta tardia de refreshAfterDocumentUpdate('proc-A') não sobrescreve troca posterior para B
      final staleRefreshACompleter = Completer<ProcessDetailBundle?>();
      final nextDetailBCompleter = Completer<ProcessDetailBundle?>();
      repo.onFetchProcessDetail = (processId) {
        if (processId == 'proc-A') return staleRefreshACompleter.future;
        if (processId == 'proc-B') return nextDetailBCompleter.future;
        return Future<ProcessDetailBundle?>.value(null);
      };

      // Abre A imediatamente e começa refreshAfterDocumentUpdate('proc-A') pendente
      final openACompleter = Completer<ProcessDetailBundle?>()
        ..complete(bundleA);
      repo.onFetchProcessDetail = (processId) => openACompleter.future;
      await controller.openProcessDetail('proc-A');
      expect(controller.activeDetailProcessId, 'proc-A');

      repo.onFetchProcessDetail = (processId) {
        if (processId == 'proc-A') return staleRefreshACompleter.future;
        return nextDetailBCompleter.future;
      };
      final refreshAFuture = controller.refreshAfterDocumentUpdate('proc-A');
      final switchToBFuture = controller.openProcessDetail('proc-B');
      nextDetailBCompleter.complete(bundleB);
      await switchToBFuture;

      staleRefreshACompleter.complete(bundleA);
      await refreshAFuture;
      expect(controller.activeDetailProcessId, 'proc-B');
      expect(controller.detailBundle?.process.id, 'proc-B');

      // 5) Proteções de clearPrivateState (logout/troca) e dispose mantidas
      final postLogoutCompleter = Completer<ProcessDetailBundle?>();
      repo.onFetchProcessDetail = (_) => postLogoutCompleter.future;
      final pendingLogoutFuture = controller.openProcessDetail('proc-A');
      controller.clearPrivateState();
      postLogoutCompleter.complete(bundleA);
      await pendingLogoutFuture;
      expect(controller.detailBundle, isNull);
      expect(controller.processes, isEmpty);

      var isDisposed = false;
      var notificationsAfterDispose = 0;
      controller.addListener(() {
        if (isDisposed) notificationsAfterDispose++;
      });
      final postDisposeCompleter = Completer<ProcessDetailBundle?>();
      repo.onFetchProcessDetail = (_) => postDisposeCompleter.future;
      final pendingDisposeFuture = controller.openProcessDetail('proc-A');
      isDisposed = true;
      controller.dispose();
      postDisposeCompleter.complete(bundleA);
      await pendingDisposeFuture;
      expect(notificationsAfterDispose, 0);
    });

    testWidgets(
      '20 (C3-05): falha na consulta substituta após refreshAfterDocumentUpdate sai de loading, notifica UI com retry, descarta resposta obsoleta e preserva C2-01',
      (tester) async {
        final reqA = _req(
          id: 'req-c305-a',
          code: 'REQ_C305',
          title: 'Documento Lista',
          status: RequirementStatus.notSubmitted,
        );
        final bundleA = _buildBundle(
          processId: 'proc-c305-a',
          requirements: <ProcessRequirementItem>[reqA],
        );

        final firstListCompleter = Completer<List<InternshipProcessSummary>>();
        var fetchCall = 0;
        final repo = _DocTestProcessRepository(
          processes: <InternshipProcessSummary>[bundleA.process],
          details: <String, ProcessDetailBundle?>{'proc-c305-a': bundleA},
        );
        repo.onFetchStudentProcesses = () {
          fetchCall++;
          if (fetchCall == 1) {
            return firstListCompleter.future;
          }
          if (fetchCall == 2) {
            return Future<List<InternshipProcessSummary>>.error(
              const PostgrestException(
                message: 'connection reset during replacement list query',
              ),
            );
          }
          return Future<List<InternshipProcessSummary>>.value(
            <InternshipProcessSummary>[bundleA.process],
          );
        };

        final controller = ProcessController(repository: repo);
        addTearDown(controller.dispose);

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StudentProcessesWorkspace(
                profile: _studentA,
                controller: controller,
              ),
            ),
          ),
        );
        await tester.pump();

        // Listagem inicial está carregando
        expect(controller.listStatus, ProcessLoadStatus.loading);
        expect(find.text('Carregando processos de estágio...'), findsOneWidget);

        // Upload conclui enquanto listagem inicial estava em andamento,
        // invalidando a consulta anterior e a consulta substituta falha:
        await controller.refreshAfterDocumentUpdate('proc-c305-a');
        await tester.pumpAndSettle();

        expect(controller.listStatus, ProcessLoadStatus.error);
        expect(controller.listErrorMessage, isNotNull);
        expect(find.byKey(const Key('processes_retry_button')), findsOneWidget);
        expect(find.text('Carregando processos de estágio...'), findsNothing);
        final refreshBtnDuringError = tester.widget<OutlinedButton>(
          find.byKey(const Key('refresh_processes_button')),
        );
        expect(refreshBtnDuringError.onPressed, isNotNull);

        // Resposta tardia da listagem obsoleta (#1) deve continuar descartada
        firstListCompleter.complete(<InternshipProcessSummary>[
          bundleA.process,
        ]);
        await tester.pumpAndSettle();
        expect(controller.listStatus, ProcessLoadStatus.error);
        expect(controller.processes, isEmpty);

        // Usuário aciona Retry -> lista carrega e UI recupera estado loaded
        await tester.tap(find.byKey(const Key('processes_retry_button')));
        await tester.pumpAndSettle();

        expect(controller.listStatus, ProcessLoadStatus.loaded);
        expect(controller.processes.length, 1);
        expect(
          find.byKey(const Key('process_card_proc-c305-a')),
          findsOneWidget,
        );

        // Garantir não regressão de C2-01: erro posterior ao já loaded não apaga lista exibida
        repo.onFetchStudentProcesses = () => Future.error(
          const PostgrestException(message: 'transient error after loaded'),
        );
        await controller.refreshAfterDocumentUpdate('proc-c305-a');
        await tester.pumpAndSettle();
        expect(controller.listStatus, ProcessLoadStatus.loaded);
        expect(
          find.byKey(const Key('process_card_proc-c305-a')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
