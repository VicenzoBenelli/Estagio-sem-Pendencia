import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        AuthException,
        FunctionException,
        PostgrestException,
        StorageException,
        SupabaseClient;

import 'package:estagio_sem_pendencia/app/app.dart';
import 'package:estagio_sem_pendencia/features/auth/application/auth_controller.dart';
import 'package:estagio_sem_pendencia/features/auth/domain/auth_gateway.dart';
import 'package:estagio_sem_pendencia/features/auth/domain/user_profile.dart';
import 'package:estagio_sem_pendencia/features/processes/data/supabase_document_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/document_models.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/document_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/process_models.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/process_repository.dart';
import 'package:estagio_sem_pendencia/features/review/application/process_timeline_controller.dart';
import 'package:estagio_sem_pendencia/features/review/application/reviewer_controller.dart';
import 'package:estagio_sem_pendencia/features/review/data/pdf_document_renderer.dart';
import 'package:estagio_sem_pendencia/features/review/data/pdf_web_bridge.dart';
import 'package:estagio_sem_pendencia/features/review/data/supabase_review_repository.dart';
import 'package:estagio_sem_pendencia/features/review/domain/review_models.dart';
import 'package:estagio_sem_pendencia/features/review/domain/review_repository.dart';
import 'package:estagio_sem_pendencia/features/review/presentation/pdf_document_viewer.dart';

final Uint8List _sample1x1PngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC',
);

/// Constrói um PNG 1x1 válido mas com byte final distinto por página para permitir
/// comprovar nos testes que o widget `Image.memory` recebeu o bitmap específico daquela página.
Uint8List _distinctPagePngBytes(int pageNumber) {
  final copy = Uint8List.fromList(_sample1x1PngBytes);
  return Uint8List.fromList(<int>[...copy, pageNumber & 0xFF]);
}

class _PdfPageSpec {
  const _PdfPageSpec({
    required this.text,
    this.widthPt = 595,
    this.heightPt = 842,
    this.flateCompress = false,
    this.scannedImageOnly = false,
  });

  final String text;
  final int widthPt;
  final int heightPt;
  final bool flateCompress;
  final bool scannedImageOnly;
}

/// Construtor de PDF 1.4 estruturalmente válido com cálculo real de offsets em bytes
/// na tabela `xref` e `startxref` exato. Suporta streams de texto, streams comprimidas
/// com `/Filter /FlateDecode` (`zlib.encode`) e páginas digitalizadas (`/Subtype /Image`)
/// sem operadores de texto.
Uint8List _buildRealXrefPdfBytes({
  List<_PdfPageSpec>? pages,
  List<String> pageTexts = const <String>['Documento PDF Valido'],
  int widthPt = 595,
  int heightPt = 842,
  bool compressWithFlateDecode = false,
  bool scannedImageOnly = false,
}) {
  final resolvedPages =
      pages ??
      (pageTexts.isEmpty ? const <String>[''] : pageTexts)
          .map(
            (t) => _PdfPageSpec(
              text: t,
              widthPt: widthPt,
              heightPt: heightPt,
              flateCompress: compressWithFlateDecode,
              scannedImageOnly: scannedImageOnly,
            ),
          )
          .toList(growable: false);

  final builder = BytesBuilder(copy: false);
  final offsetsById = <int, int>{};

  void writeAscii(String text) {
    builder.add(latin1.encode(text));
  }

  void writeObject(int id, String dictAndBody) {
    offsetsById[id] = builder.length;
    writeAscii('$id 0 obj\n$dictAndBody\nendobj\n');
  }

  void writeStreamObject(
    int id, {
    required String dictEntries,
    required List<int> rawStreamBytes,
    required bool flateCompress,
  }) {
    offsetsById[id] = builder.length;
    final payload = flateCompress
        ? zlib.encode(rawStreamBytes)
        : rawStreamBytes;
    final filterPart = flateCompress ? ' /Filter /FlateDecode' : '';
    writeAscii(
      '$id 0 obj\n<< $dictEntries /Length ${payload.length}$filterPart >>\nstream\n',
    );
    builder.add(payload);
    writeAscii('\nendstream\nendobj\n');
  }

  // Cabeçalho PDF 1.4 com comentário binário padrão de 4 bytes > 128
  builder.add(const <int>[
    0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, // %PDF-1.4\n
    0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A, // %....\n
  ]);

  final pageCount = resolvedPages.length;
  var nextId = 3;
  final fontObjId = nextId++;
  final pageConfigs =
      <({int pageId, int contentId, int? imageId, _PdfPageSpec spec})>[];

  for (var i = 0; i < pageCount; i++) {
    final spec = resolvedPages[i];
    final pId = nextId++;
    final cId = nextId++;
    final imgId = spec.scannedImageOnly ? nextId++ : null;
    pageConfigs.add((pageId: pId, contentId: cId, imageId: imgId, spec: spec));
  }

  // 1: Catalog
  writeObject(1, '<< /Type /Catalog /Pages 2 0 R >>');

  // 2: Pages root
  final kidsRefs = pageConfigs.map((p) => '${p.pageId} 0 R').join(' ');
  writeObject(2, '<< /Type /Pages /Kids [$kidsRefs] /Count $pageCount >>');

  // 3: Font resource
  writeObject(
    fontObjId,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  );

  for (final cfg in pageConfigs) {
    final spec = cfg.spec;
    final pageW = spec.widthPt;
    final pageH = spec.heightPt;
    if (spec.scannedImageOnly && cfg.imageId != null) {
      writeObject(
        cfg.pageId,
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pageW $pageH] '
        '/Resources << /XObject << /Im1 ${cfg.imageId} 0 R >> >> '
        '/Contents ${cfg.contentId} 0 R >>',
      );
      // 2x2 RGB bitmap (12 bytes) para página digitalizada sem texto
      writeStreamObject(
        cfg.imageId!,
        dictEntries:
            '/Type /XObject /Subtype /Image /Width 2 /Height 2 '
            '/ColorSpace /DeviceRGB /BitsPerComponent 8',
        rawStreamBytes: const <int>[
          255,
          255,
          255,
          200,
          200,
          200,
          200,
          200,
          200,
          255,
          255,
          255,
        ],
        flateCompress: spec.flateCompress,
      );
      final drawImageOps = latin1.encode(
        'q $pageW 0 0 $pageH 0 0 cm /Im1 Do Q',
      );
      writeStreamObject(
        cfg.contentId,
        dictEntries: '',
        rawStreamBytes: drawImageOps,
        flateCompress: spec.flateCompress,
      );
    } else {
      writeObject(
        cfg.pageId,
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pageW $pageH] '
        '/Resources << /Font << /F1 $fontObjId 0 R >> >> '
        '/Contents ${cfg.contentId} 0 R >>',
      );
      final escaped = spec.text
          .replaceAll(r'\', r'\\')
          .replaceAll('(', r'\(')
          .replaceAll(')', r'\)');
      final textOps = latin1.encode('BT /F1 12 Tf 72 750 Td ($escaped) Tj ET');
      writeStreamObject(
        cfg.contentId,
        dictEntries: '',
        rawStreamBytes: textOps,
        flateCompress: spec.flateCompress,
      );
    }
  }

  final totalObjects = nextId;
  final xrefOffset = builder.length;
  writeAscii('xref\n0 $totalObjects\n');
  writeAscii('0000000000 65535 f \n');
  for (var id = 1; id < totalObjects; id++) {
    final off = offsetsById[id] ?? 0;
    final padded = off.toString().padLeft(10, '0');
    writeAscii('$padded 00000 n \n');
  }
  writeAscii(
    'trailer\n<< /Size $totalObjects /Root 1 0 R >>\n'
    'startxref\n$xrefOffset\n%%EOF\n',
  );

  return builder.takeBytes();
}

Uint8List _multiPagePdfBytes(
  List<String> pageContents, {
  int widthPt = 595,
  int heightPt = 842,
  bool compressWithFlateDecode = false,
  bool scannedImageOnly = false,
}) {
  return _buildRealXrefPdfBytes(
    pageTexts: pageContents,
    widthPt: widthPt,
    heightPt: heightPt,
    compressWithFlateDecode: compressWithFlateDecode,
    scannedImageOnly: scannedImageOnly,
  );
}

const MethodChannel _kTestPdfRendererChannel = MethodChannel(
  'estagio_sem_pendencia/pdf_renderer',
);

/// Simula o comportamento do `android.graphics.pdf.PdfRenderer` no canal nativo
/// durante os testes automatizados em VM desktop, aplicando o mesmo cálculo de
/// escala (`PdfBitmapScaleCalculator.computeTargetDimensions`) do `MainActivity.kt`.
void _installDefaultAndroidPdfChannelSimulator() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kTestPdfRendererChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'clearTemporaryPdfs') {
          return true;
        }
        if (call.method != 'renderPdfDocument') {
          return null;
        }

        final args = call.arguments as Map<dynamic, dynamic>?;
        final bytes = args?['bytes'] as Uint8List?;
        final maxDimension =
            (args?['maxDimension'] as int?) ?? kDefaultMaxPdfBitmapDimension;

        if (bytes == null ||
            bytes.length < 5 ||
            !PdfPreliminaryValidation.hasPdfHeader(bytes)) {
          throw PlatformException(
            code: 'INVALID_PDF_SIGNATURE',
            message: 'Assinatura %PDF- ausente.',
          );
        }

        final raw = latin1.decode(bytes, allowInvalid: true);
        if (!raw.contains('%%EOF') || !raw.contains('endobj')) {
          throw PlatformException(
            code: 'CORRUPTED_PDF',
            message: 'Não foi possível renderizar as páginas do documento PDF.',
          );
        }

        // Localiza exclusivamente o dicionário do objeto `/Type /Pages` (sem atravessar `endobj`)
        var pageCount = 1;
        final objRegex = RegExp(r'\d+\s+0\s+obj\b([\s\S]*?)endobj');
        final pageDims = <(int w, int h)>[];

        for (final m in objRegex.allMatches(raw)) {
          final body = m.group(1) ?? '';
          if (RegExp(r'/Type\s*/Pages\b').hasMatch(body)) {
            final countMatch = RegExp(r'/Count\s+(\d+)\b').firstMatch(body);
            if (countMatch != null) {
              pageCount = int.tryParse(countMatch.group(1) ?? '') ?? 1;
            }
          }
          if (RegExp(r'/Type\s*/Page\b(?!s)').hasMatch(body)) {
            final box = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+(\d+)\s+(\d+)\s*\]')
                .firstMatch(body);
            final w = int.tryParse(box?.group(1) ?? '') ?? 595;
            final h = int.tryParse(box?.group(2) ?? '') ?? 842;
            pageDims.add((w, h));
          }
        }

        if (pageCount <= 0) {
          throw PlatformException(
            code: 'EMPTY_PDF_PAGES',
            message: 'O documento PDF não contém páginas renderizáveis.',
          );
        }

        final pages = <Map<String, dynamic>>[];
        for (var i = 0; i < pageCount; i++) {
          final dims = i < pageDims.length ? pageDims[i] : (595, 842);
          final scaled = PdfBitmapScaleCalculator.computeTargetDimensions(
            widthPt: dims.$1,
            heightPt: dims.$2,
            maxDimension: maxDimension,
          );
          pages.add(<String, dynamic>{
            'pageNumber': i + 1,
            'widthPt': dims.$1,
            'heightPt': dims.$2,
            'bitmapWidth': scaled.width,
            'bitmapHeight': scaled.height,
            'pngBytes': _distinctPagePngBytes(i + 1),
          });
        }

        return <String, dynamic>{'pageCount': pageCount, 'pages': pages};
      });
}

class _SpyPdfWebBridge implements PdfWebBridge {
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
    final id = 'spy_session_${++_counter}';
    final handle = PdfWebSessionHandle(
      sessionId: id,
      viewType: 'spy-pdf-view-$id',
      objectUrl: 'blob:http://localhost/ephemeral-$id',
      submissionId: submissionId,
      submissionVersion: submissionVersion,
      currentPage: initialPage,
    );
    createdHandles.add(handle);
    return handle;
  }

  @override
  void navigateToPage(PdfWebSessionHandle? handle, int pageNumber) {
    if (handle != null && !handle.isRevoked) {
      handle.currentPage = pageNumber;
    }
  }

  @override
  bool openInBrowserTab(PdfWebSessionHandle? handle, {int? pageNumber}) {
    if (handle == null || handle.isRevoked) {
      return false;
    }
    if (pageNumber != null) {
      handle.currentPage = pageNumber;
    }
    handle.openTabCalls++;
    return true;
  }

  @override
  void revokeSession(PdfWebSessionHandle? handle) {
    if (handle != null && !handle.isRevoked) {
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

Uint8List _validPdfBytes([String label = 'Documento Estagio PDF']) {
  return Uint8List.fromList(
    '%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n% $label\nstartxref\n0\n%%EOF\n'
        .codeUnits,
  );
}

const UserProfile _studentA = UserProfile(
  id: 'student-a',
  email: 'estudante.a@demo.local',
  fullName: 'Estudante A Fictício',
  role: UserRole.student,
  active: true,
);

const UserProfile _studentB = UserProfile(
  id: 'student-b',
  email: 'estudante.b@demo.local',
  fullName: 'Estudante B Fictício',
  role: UserRole.student,
  active: true,
);

const UserProfile _assignedReviewerR1 = UserProfile(
  id: 'reviewer-r1',
  email: 'revisor.r1@demo.local',
  fullName: 'Revisor Atribuído R1',
  role: UserRole.reviewer,
  active: true,
);

const UserProfile _unassignedReviewerR2 = UserProfile(
  id: 'reviewer-r2',
  email: 'revisor.r2@demo.local',
  fullName: 'Revisor Sem Escopo R2',
  role: UserRole.reviewer,
  active: true,
);

class _ReviewTestAuthGateway implements AuthGateway {
  _ReviewTestAuthGateway({this.currentProfile});

  final StreamController<AuthGatewayEvent> _events =
      StreamController<AuthGatewayEvent>.broadcast();

  UserProfile? currentProfile;
  UserProfile? nextSignInProfile;
  int signOutCalls = 0;

  @override
  bool get hasCurrentSession => currentProfile != null;

  @override
  Stream<AuthGatewayEvent> get onAuthEvents => _events.stream;

  Future<void> dispose() => _events.close();

  @override
  Future<UserProfile?> restoreAndValidateSession() async => currentProfile;

  @override
  Future<UserProfile> fetchCurrentProfile() async {
    final profile = currentProfile ?? nextSignInProfile;
    if (profile == null) {
      throw const AuthFailure('Sessão inválida.', isSessionInvalid: true);
    }
    return profile;
  }

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
    final profile = nextSignInProfile ?? currentProfile!;
    currentProfile = profile;
    return profile;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    currentProfile = null;
    _events.add(const AuthGatewayEvent(kind: AuthEventKind.signedOut));
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {}

  @override
  Future<void> updatePassword({required String newPassword}) async {}
}

class _FakePdfPicker implements PdfPickerGateway {
  _FakePdfPicker();

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

/// Simulador integrado de backend que aplica exatamente as invariantes do Lote 4:
/// - Isolamento por usuário (`student-a`, `student-b`, `reviewer-r1` atribuído, `reviewer-r2` não atribuído);
/// - Fila `reviewer_queue_v` apenas com versões vigentes `under_review` dentro do escopo;
/// - RPC `review_submission` atômica com validação de motivo, idempotência, bloqueio de versão obsoleta e dupla decisão;
/// - Reenvio `v(n+1)` preservando `v(n)` e atualizando `process_progress_v` e `process_audit_timeline_v`.
class _InMemoryLot4Backend
    implements ProcessRepository, DocumentRepository, ReviewRepository {
  _InMemoryLot4Backend({required this.activeUserProvider}) {
    _seedInitialState();
  }

  final UserProfile? Function() activeUserProvider;

  final Set<String> assignedScopeKeysForR1 = <String>{'inst-1|course-1|mod-1'};
  final Set<String> assignedScopeKeysForR2 = <String>{};

  final Map<String, InternshipProcessSummary> processesById =
      <String, InternshipProcessSummary>{};
  final Map<String, List<ProcessRequirementItem>> requirementsByProcessId =
      <String, List<ProcessRequirementItem>>{};
  final Map<String, List<DocumentSubmissionRecord>> submissionsByReqId =
      <String, List<DocumentSubmissionRecord>>{};
  final Map<String, List<DocumentReviewRecord>> reviewsByReqId =
      <String, List<DocumentReviewRecord>>{};
  final Map<String, DocumentReviewRecord> reviewsByIdempotencyKey =
      <String, DocumentReviewRecord>{};
  final Map<String, List<ProcessAuditTimelineEvent>> timelineByProcessId =
      <String, List<ProcessAuditTimelineEvent>>{};
  final Map<String, Uint8List> storageObjects = <String, Uint8List>{};

  int fetchQueueCalls = 0;
  int downloadCalls = 0;
  int reviewRpcCalls = 0;
  int fetchTimelineCalls = 0;
  final List<String?> reviewIdempotencyKeys = <String?>[];
  final List<String> downloadRequests = <String>[];

  Completer<PaginatedResult<ReviewerQueueItem>>? pendingFetchQueue;
  Completer<Uint8List>? pendingDownload;
  Completer<ReviewDecisionOutcome>? pendingReviewRpc;
  Completer<PaginatedResult<ProcessAuditTimelineEvent>>? pendingFetchTimeline;

  Object? nextFetchQueueError;
  Object? nextDownloadError;
  Object? nextReviewRpcError;
  Object? nextTimelineError;

  int _eventCounter = 100;

  void _seedInitialState() {
    const procId = 'proc-a-1';
    final req1 = ProcessRequirementItem(
      id: 'req-a-1',
      processId: procId,
      templateItemId: 'tpl-item-1',
      code: 'TCE_OBRIG_01',
      title: 'Termo de Compromisso de Estágio (Fictício)',
      description: 'Enviar PDF do termo assinado pelas partes.',
      acceptanceCriteria: 'Assinaturas e vigência legíveis.',
      isRequired: true,
      displayOrder: 1,
      status: RequirementStatus.notSubmitted,
      currentVersion: 0,
      createdAt: DateTime(2026, 11, 19, 9, 0),
      updatedAt: DateTime(2026, 11, 19, 9, 0),
    );
    final req2 = ProcessRequirementItem(
      id: 'req-a-2',
      processId: procId,
      templateItemId: 'tpl-item-2',
      code: 'PLANO_OPC_01',
      title: 'Documento Complementar Opcional (Fictício)',
      description: 'Anexo complementar opcional.',
      acceptanceCriteria: 'PDF opcional legível.',
      isRequired: false,
      displayOrder: 2,
      status: RequirementStatus.notSubmitted,
      currentVersion: 0,
      createdAt: DateTime(2026, 11, 19, 9, 0),
      updatedAt: DateTime(2026, 11, 19, 9, 0),
    );

    requirementsByProcessId[procId] = <ProcessRequirementItem>[req1, req2];
    final progress = _computeProgress(procId, ProcessStatus.inProgress);

    processesById[procId] = InternshipProcessSummary(
      id: procId,
      ownerId: _studentA.id,
      institutionId: 'inst-1',
      courseId: 'course-1',
      courseModalityId: 'mod-1',
      templateId: 'tpl-1',
      templateVersion: 1,
      status: ProcessStatus.inProgress,
      isDemo: true,
      openedAt: DateTime(2026, 11, 19, 9, 0),
      createdAt: DateTime(2026, 11, 19, 9, 0),
      updatedAt: DateTime(2026, 11, 19, 9, 0),
      institutionCode: 'INST_DEMO',
      institutionName: 'Instituição Fictícia de Demonstração',
      courseCode: 'ENG_SW_DEMO',
      courseName: 'Engenharia de Software (Demonstração)',
      modalityCode: 'OBRIG_DEMO',
      modalityName: 'Estágio Curricular Obrigatório',
      templateTitle: 'Checklist Fictício v1',
      progress: progress,
    );

    timelineByProcessId[procId] = <ProcessAuditTimelineEvent>[
      ProcessAuditTimelineEvent(
        eventId: 'evt-1',
        processId: procId,
        eventType: AuditEventType.processCreated,
        rawEventType: 'process_created',
        actorId: _studentA.id,
        actorRole: 'student',
        actorDisplayName: _studentA.fullName!,
        targetUserId: _studentA.id,
        entityTable: 'internship_processes',
        entityId: procId,
        processStatus: ProcessStatus.inProgress,
        institutionId: 'inst-1',
        courseId: 'course-1',
        courseModalityId: 'mod-1',
        occurredAt: DateTime.utc(2026, 11, 19, 12, 0).toLocal(),
        metadata: const <String, dynamic>{
          'template_version': 1,
          'snapshot_item_count': 2,
          'required_item_count': 1,
        },
      ),
    ];
  }

  bool _isAssignedReviewer(UserProfile user, InternshipProcessSummary proc) {
    if (!user.active || user.role != UserRole.reviewer) {
      return false;
    }
    final key =
        '${proc.institutionId}|${proc.courseId}|${proc.courseModalityId}';
    if (user.id == _assignedReviewerR1.id) {
      return assignedScopeKeysForR1.contains(key);
    }
    if (user.id == _unassignedReviewerR2.id) {
      return assignedScopeKeysForR2.contains(key);
    }
    return false;
  }

  bool _canAccessProcess(UserProfile user, InternshipProcessSummary proc) {
    if (!user.active) return false;
    if (user.role == UserRole.student) {
      return proc.ownerId == user.id;
    }
    return _isAssignedReviewer(user, proc);
  }

  ProcessProgressSummary _computeProgress(
    String processId,
    ProcessStatus status,
  ) {
    final reqs = requirementsByProcessId[processId] ?? const [];
    final requiredItems = reqs.where((r) => r.isRequired).toList();
    final total = requiredItems.length;
    final approved = requiredItems
        .where((r) => r.status == RequirementStatus.approved)
        .length;
    final underReview = requiredItems
        .where((r) => r.status == RequirementStatus.underReview)
        .length;
    final correction = requiredItems
        .where((r) => r.status == RequirementStatus.correctionRequested)
        .length;

    final progressStatus = total == 0
        ? ProgressStatus.indeterminate
        : (approved == total
              ? ProgressStatus.documentallyComplete
              : ProgressStatus.inProgress);
    final pct = total == 0 ? null : (approved / total) * 100.0;

    return ProcessProgressSummary(
      processId: processId,
      ownerId: processesById[processId]?.ownerId ?? _studentA.id,
      processStatus: status,
      requiredTotal: total,
      requiredApproved: approved,
      requiredUnderReview: underReview,
      requiredCorrectionRequested: correction,
      progressStatus: progressStatus,
      progressPercentage: pct,
    );
  }

  void _refreshProcessSummary(String processId, {ProcessStatus? newStatus}) {
    final existing = processesById[processId];
    if (existing == null) return;
    final status = newStatus ?? existing.status;
    final progress = _computeProgress(processId, status);
    processesById[processId] = InternshipProcessSummary(
      id: existing.id,
      ownerId: existing.ownerId,
      institutionId: existing.institutionId,
      courseId: existing.courseId,
      courseModalityId: existing.courseModalityId,
      templateId: existing.templateId,
      templateVersion: existing.templateVersion,
      status: status,
      isDemo: existing.isDemo,
      openedAt: existing.openedAt,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
      institutionCode: existing.institutionCode,
      institutionName: existing.institutionName,
      courseCode: existing.courseCode,
      courseName: existing.courseName,
      modalityCode: existing.modalityCode,
      modalityName: existing.modalityName,
      templateTitle: existing.templateTitle,
      progress: progress,
    );
  }

  @override
  Future<List<CatalogModalityOption>> fetchActiveCatalog() async =>
      const <CatalogModalityOption>[];

  @override
  Future<List<InternshipProcessSummary>> fetchStudentProcesses() async {
    final user = activeUserProvider();
    if (user == null) {
      throw const PostgrestException(message: 'JWT expired', code: 'PGRST301');
    }
    return processesById.values
        .where((p) => p.ownerId == user.id)
        .toList(growable: false);
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
    final user = activeUserProvider();
    if (user == null) {
      throw const PostgrestException(message: 'JWT expired', code: 'PGRST301');
    }
    final proc = processesById[processId];
    if (proc == null || !_canAccessProcess(user, proc)) {
      return null;
    }
    final reqs = requirementsByProcessId[processId] ?? const [];
    return ProcessDetailBundle(
      process: proc,
      requirements: List<ProcessRequirementItem>.from(reqs),
      progress: proc.progress,
    );
  }

  @override
  Future<SubmitPdfOutcome> submitRequirementPdf({
    required String processRequirementId,
    required SelectedPdfFile file,
    required String idempotencyKey,
  }) async {
    final user = activeUserProvider();
    if (user == null || user.role != UserRole.student) {
      throw const DocumentFailure(
        'Apenas estudantes autenticados podem enviar documentos.',
        code: 'forbidden_role',
        httpStatus: 403,
        isUnauthorized: true,
      );
    }

    ProcessRequirementItem? targetReq;
    InternshipProcessSummary? targetProc;
    for (final entry in requirementsByProcessId.entries) {
      for (final req in entry.value) {
        if (req.id == processRequirementId) {
          targetReq = req;
          targetProc = processesById[entry.key];
          break;
        }
      }
    }

    if (targetReq == null ||
        targetProc == null ||
        targetProc.ownerId != user.id) {
      throw const DocumentFailure(
        'Requisito não encontrado ou inacessível para sua conta.',
        code: 'not_found',
        httpStatus: 404,
      );
    }

    final existingSubs =
        submissionsByReqId[processRequirementId] ??
        const <DocumentSubmissionRecord>[];
    for (final s in existingSubs) {
      if (s.idempotencyKey == idempotencyKey) {
        return SubmitPdfOutcome(
          submission: s,
          idempotentReplay: true,
          requirementStatus: RequirementStatus.underReview,
          currentVersion: s.version,
          currentSubmissionId: s.id,
        );
      }
    }

    if (targetReq.status != RequirementStatus.notSubmitted &&
        targetReq.status != RequirementStatus.correctionRequested) {
      throw const DocumentFailure(
        'Este requisito não aceita novo envio no status atual.',
        code: 'requirement_status_conflict',
        httpStatus: 409,
        isConflict: true,
      );
    }

    final nextVersion = targetReq.currentVersion + 1;
    final subId = 'sub-${targetReq.id}-v$nextVersion';
    final path =
        'processes/${targetProc.id}/requirements/${targetReq.id}/submissions/$subId.pdf';

    final newSub = DocumentSubmissionRecord(
      id: subId,
      processId: targetProc.id,
      processRequirementId: targetReq.id,
      submittedBy: user.id,
      version: nextVersion,
      storageBucket: kPrivateDocumentsBucket,
      storagePath: path,
      originalFilename: file.basename,
      mimeType: 'application/pdf',
      sizeBytes: file.sizeBytes,
      sha256Checksum: 'a1b2c3d4' * 8,
      idempotencyKey: idempotencyKey,
      status: SubmissionStatus.underReview,
      submittedAt: DateTime.utc(2026, 11, 20, 14, nextVersion).toLocal(),
      createdAt: DateTime.utc(2026, 11, 20, 14, nextVersion).toLocal(),
    );

    // Preserva versões antigas intactas
    submissionsByReqId[targetReq.id] = <DocumentSubmissionRecord>[
      newSub,
      ...existingSubs,
    ];
    storageObjects[path] = Uint8List.fromList(file.bytes);

    final updatedReq = ProcessRequirementItem(
      id: targetReq.id,
      processId: targetReq.processId,
      templateItemId: targetReq.templateItemId,
      code: targetReq.code,
      title: targetReq.title,
      description: targetReq.description,
      acceptanceCriteria: targetReq.acceptanceCriteria,
      isRequired: targetReq.isRequired,
      displayOrder: targetReq.displayOrder,
      status: RequirementStatus.underReview,
      currentSubmissionId: newSub.id,
      currentVersion: nextVersion,
      createdAt: targetReq.createdAt,
      updatedAt: DateTime.now(),
    );

    final list = requirementsByProcessId[targetProc.id]!;
    final idx = list.indexWhere((r) => r.id == updatedReq.id);
    list[idx] = updatedReq;
    _refreshProcessSummary(targetProc.id);

    final evtId = 'evt-${++_eventCounter}';
    timelineByProcessId[targetProc.id] = <ProcessAuditTimelineEvent>[
      ProcessAuditTimelineEvent(
        eventId: evtId,
        processId: targetProc.id,
        eventType: AuditEventType.documentSubmitted,
        rawEventType: 'document_submitted',
        actorId: user.id,
        actorRole: 'student',
        actorDisplayName: user.fullName ?? 'Estudante',
        targetUserId: user.id,
        entityTable: 'document_submissions',
        entityId: newSub.id,
        processRequirementId: updatedReq.id,
        requirementCode: updatedReq.code,
        requirementTitle: updatedReq.title,
        submissionId: newSub.id,
        submissionVersion: nextVersion,
        processStatus: processesById[targetProc.id]!.status,
        institutionId: targetProc.institutionId,
        courseId: targetProc.courseId,
        courseModalityId: targetProc.courseModalityId,
        occurredAt: newSub.submittedAt,
        metadata: <String, dynamic>{
          'process_requirement_id': updatedReq.id,
          'version': nextVersion,
          'is_resubmission': nextVersion > 1,
          'size_bytes': newSub.sizeBytes,
        },
      ),
      ...(timelineByProcessId[targetProc.id] ?? const []),
    ];

    return SubmitPdfOutcome(
      submission: newSub,
      idempotentReplay: false,
      requirementStatus: RequirementStatus.underReview,
      currentVersion: nextVersion,
      currentSubmissionId: newSub.id,
    );
  }

  @override
  Future<DocumentSubmissionRecord?> findSubmissionByIdempotencyKey({
    required String processRequirementId,
    required String idempotencyKey,
  }) async {
    final subs = submissionsByReqId[processRequirementId] ?? const [];
    for (final s in subs) {
      if (s.idempotencyKey == idempotencyKey) return s;
    }
    return null;
  }

  @override
  Future<List<DocumentSubmissionRecord>> fetchRequirementSubmissions({
    required String processRequirementId,
  }) async {
    final user = activeUserProvider();
    if (user == null) {
      throw const PostgrestException(message: 'JWT expired', code: 'PGRST301');
    }

    InternshipProcessSummary? proc;
    for (final entry in requirementsByProcessId.entries) {
      if (entry.value.any((r) => r.id == processRequirementId)) {
        proc = processesById[entry.key];
        break;
      }
    }
    if (proc == null || !_canAccessProcess(user, proc)) {
      return const <DocumentSubmissionRecord>[];
    }

    final list = List<DocumentSubmissionRecord>.from(
      submissionsByReqId[processRequirementId] ??
          const <DocumentSubmissionRecord>[],
    )..sort((a, b) => b.version.compareTo(a.version));
    return list;
  }

  @override
  Future<List<DocumentReviewRecord>> fetchRequirementReviews({
    required String processRequirementId,
  }) async {
    final user = activeUserProvider();
    if (user == null) {
      throw const PostgrestException(message: 'JWT expired', code: 'PGRST301');
    }

    InternshipProcessSummary? proc;
    for (final entry in requirementsByProcessId.entries) {
      if (entry.value.any((r) => r.id == processRequirementId)) {
        proc = processesById[entry.key];
        break;
      }
    }
    if (proc == null || !_canAccessProcess(user, proc)) {
      return const <DocumentReviewRecord>[];
    }

    return List<DocumentReviewRecord>.from(
      reviewsByReqId[processRequirementId] ?? const <DocumentReviewRecord>[],
    );
  }

  @override
  Future<Uint8List> downloadSubmissionBytes({
    required String submissionId,
  }) async {
    downloadCalls++;
    downloadRequests.add(submissionId);

    if (pendingDownload != null) {
      return pendingDownload!.future;
    }
    if (nextDownloadError != null) {
      final err = nextDownloadError!;
      nextDownloadError = null;
      throw err;
    }

    final user = activeUserProvider();
    if (user == null) {
      throw const FunctionException(
        status: 401,
        details: <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'invalid_or_expired_session',
            'message': 'Sessão ausente, inválida ou expirada.',
          },
        },
      );
    }

    if (submissionId.trim().isEmpty ||
        submissionId.contains('..') ||
        submissionId.startsWith('/') ||
        submissionId.contains('/object/public/') ||
        submissionId.contains('/object/sign/')) {
      throw const FunctionException(
        status: 400,
        details: <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'invalid_submission_id',
            'message': 'Identificador submission_id inválido.',
          },
        },
      );
    }

    if (!user.active) {
      throw const FunctionException(
        status: 403,
        details: <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'forbidden_inactive_profile',
            'message': 'Perfil ausente ou inativo.',
          },
        },
      );
    }

    DocumentSubmissionRecord? matchedSub;
    for (final subs in submissionsByReqId.values) {
      for (final s in subs) {
        if (s.id == submissionId) {
          matchedSub = s;
          break;
        }
      }
    }
    if (matchedSub == null) {
      throw const FunctionException(
        status: 404,
        details: <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'submission_not_found',
            'message':
                'Submissão documental não encontrada ou acesso indisponível.',
          },
        },
      );
    }

    final proc = processesById[matchedSub.processId];
    if (proc == null || !_canAccessProcess(user, proc)) {
      throw const FunctionException(
        status: 404,
        details: <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'submission_not_found',
            'message':
                'Submissão documental não encontrada ou acesso indisponível.',
          },
        },
      );
    }

    final bytes = storageObjects[matchedSub.storagePath];
    if (bytes == null) {
      throw const FunctionException(
        status: 404,
        details: <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'submission_not_found',
            'message':
                'Submissão documental não encontrada ou acesso indisponível.',
          },
        },
      );
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<PaginatedResult<ReviewerQueueItem>> fetchReviewerQueue({
    ReviewerQueueQuery query = const ReviewerQueueQuery(),
  }) async {
    fetchQueueCalls++;
    if (pendingFetchQueue != null) {
      return pendingFetchQueue!.future;
    }
    if (nextFetchQueueError != null) {
      final err = nextFetchQueueError!;
      nextFetchQueueError = null;
      throw err;
    }

    final user = activeUserProvider();
    if (user == null) {
      throw const PostgrestException(message: 'JWT expired', code: 'PGRST301');
    }

    final allItems = <ReviewerQueueItem>[];
    for (final proc in processesById.values) {
      if (proc.status == ProcessStatus.cancelled) continue;
      if (!_isAssignedReviewer(user, proc)) continue;

      final reqs = requirementsByProcessId[proc.id] ?? const [];
      for (final req in reqs) {
        if (req.status != RequirementStatus.underReview ||
            req.currentSubmissionId == null) {
          continue;
        }
        final subs = submissionsByReqId[req.id] ?? const [];
        DocumentSubmissionRecord? currentSub;
        for (final s in subs) {
          if (s.id == req.currentSubmissionId &&
              s.version == req.currentVersion &&
              s.status == SubmissionStatus.underReview) {
            currentSub = s;
            break;
          }
        }
        if (currentSub == null) continue;

        final existingReviews = reviewsByReqId[req.id] ?? const [];
        if (existingReviews.any((r) => r.submissionId == currentSub!.id)) {
          continue;
        }

        allItems.add(
          ReviewerQueueItem(
            submissionId: currentSub.id,
            processRequirementId: req.id,
            processId: proc.id,
            studentId: proc.ownerId,
            studentName: proc.ownerId == _studentA.id
                ? _studentA.fullName!
                : 'Estudante',
            institutionId: proc.institutionId,
            institutionCode: proc.institutionCode,
            institutionName: proc.institutionName,
            courseId: proc.courseId,
            courseCode: proc.courseCode,
            courseName: proc.courseName,
            courseModalityId: proc.courseModalityId,
            modalityCode: proc.modalityCode,
            modalityName: proc.modalityName,
            processStatus: proc.status,
            processOpenedAt: proc.openedAt,
            templateVersion: proc.templateVersion,
            requirementCode: req.code,
            requirementTitle: req.title,
            requirementDisplayOrder: req.displayOrder,
            isRequired: req.isRequired,
            requirementStatus: req.status,
            currentVersion: req.currentVersion,
            isResubmission: currentSub.version > 1,
            submissionVersion: currentSub.version,
            submissionStatus: currentSub.status,
            originalFilename: currentSub.originalFilename,
            sizeBytes: currentSub.sizeBytes,
            sha256Checksum: currentSub.sha256Checksum,
            storageBucket: currentSub.storageBucket,
            storagePath: currentSub.storagePath,
            submittedAt: currentSub.submittedAt,
            isDemo: proc.isDemo,
          ),
        );
      }
    }

    var filtered = allItems.where((item) {
      if (query.onlyRequired != null && item.isRequired != query.onlyRequired) {
        return false;
      }
      if (query.onlyResubmissions != null &&
          item.isResubmission != query.onlyResubmissions) {
        return false;
      }
      if (query.processId != null &&
          query.processId!.trim().isNotEmpty &&
          item.processId != query.processId!.trim()) {
        return false;
      }
      if (query.requirementCode != null &&
          query.requirementCode!.trim().isNotEmpty &&
          item.requirementCode != query.requirementCode!.trim()) {
        return false;
      }
      final term = SupabaseReviewRepository.sanitizeSearchTerm(
        query.searchQuery,
      ).toLowerCase();
      if (term.isNotEmpty) {
        final matches =
            item.studentName.toLowerCase().contains(term) ||
            item.requirementTitle.toLowerCase().contains(term) ||
            item.requirementCode.toLowerCase().contains(term) ||
            (item.courseName?.toLowerCase().contains(term) ?? false);
        if (!matches) return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      final cmpTime = a.submittedAt.compareTo(b.submittedAt);
      final cmp = cmpTime != 0
          ? cmpTime
          : a.submissionId.compareTo(b.submissionId);
      return query.oldestFirst ? cmp : -cmp;
    });

    final total = filtered.length;
    final start = query.page * query.pageSize;
    final pageItems = start >= total
        ? const <ReviewerQueueItem>[]
        : filtered.skip(start).take(query.pageSize).toList(growable: false);

    return PaginatedResult<ReviewerQueueItem>(
      items: pageItems,
      totalCount: total,
      page: query.page,
      pageSize: query.pageSize,
    );
  }

  @override
  Future<ReviewDecisionOutcome> reviewSubmission({
    required String submissionId,
    required ReviewDecision decision,
    String? reason,
    String? idempotencyKey,
  }) async {
    reviewRpcCalls++;
    reviewIdempotencyKeys.add(idempotencyKey);

    if (pendingReviewRpc != null) {
      return pendingReviewRpc!.future;
    }
    if (nextReviewRpcError != null) {
      final err = nextReviewRpcError!;
      nextReviewRpcError = null;
      throw err;
    }

    final user = activeUserProvider();
    if (user == null) {
      throw const PostgrestException(
        message: '[ERR:unauthorized_session] Sessão autenticada obrigatória.',
        code: '42501',
      );
    }
    if (!user.active || user.role != UserRole.reviewer) {
      throw const PostgrestException(
        message: '[ERR:forbidden_role] Apenas revisor ativo pode decidir submissões.',
        code: '42501',
      );
    }

    final cleanReason = ReviewDecisionValidation.cleanReason(reason);
    if (decision == ReviewDecision.correctionRequested && cleanReason.isEmpty) {
      throw const PostgrestException(
        message: '[ERR:missing_correction_reason] Justificativa obrigatória ao solicitar correção.',
        code: '22023',
      );
    }
    if (cleanReason.length > kMaxReviewReasonLength) {
      throw const PostgrestException(
        message: '[ERR:reason_too_long] Justificativa excede 2000 caracteres.',
        code: '22023',
      );
    }

    DocumentSubmissionRecord? targetSub;
    ProcessRequirementItem? targetReq;
    InternshipProcessSummary? targetProc;

    for (final entry in submissionsByReqId.entries) {
      for (final s in entry.value) {
        if (s.id == submissionId) {
          targetSub = s;
          targetProc = processesById[s.processId];
          final reqs = requirementsByProcessId[s.processId] ?? const [];
          for (final r in reqs) {
            if (r.id == entry.key) {
              targetReq = r;
              break;
            }
          }
          break;
        }
      }
    }

    if (targetSub == null || targetReq == null || targetProc == null) {
      throw const PostgrestException(
        message: '[ERR:submission_not_found] Submissão não encontrada.',
        code: 'P0002',
      );
    }

    if (!_isAssignedReviewer(user, targetProc)) {
      throw const PostgrestException(
        message: '[ERR:forbidden_scope] Revisor não possui atribuição ativa para este processo.',
        code: '42501',
      );
    }

    if (targetProc.status == ProcessStatus.cancelled) {
      throw const PostgrestException(
        message: '[ERR:process_cancelled] Processo cancelado.',
        code: '42501',
      );
    }

    // Idempotent replay check
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      final compositeKey = '${user.id}|$idempotencyKey';
      final existingIdem = reviewsByIdempotencyKey[compositeKey];
      if (existingIdem != null) {
        if (existingIdem.submissionId != targetSub.id ||
            existingIdem.decision != decision ||
            (existingIdem.reason ?? '') != cleanReason) {
          throw const PostgrestException(
            message: '[ERR:idempotency_mismatch] Chave de idempotência associada a outra decisão.',
            code: '23505',
          );
        }
        return ReviewDecisionOutcome(
          ok: true,
          idempotentReplay: true,
          review: existingIdem,
          submission: targetSub,
          requirement: targetReq,
          process: processesById[targetProc.id]!,
          progress: processesById[targetProc.id]!.progress,
        );
      }
    }

    final existingReviews = reviewsByReqId[targetReq.id] ?? const [];
    if (existingReviews.any((r) => r.submissionId == targetSub!.id)) {
      throw const PostgrestException(
        message:
            '[ERR:submission_already_reviewed] Esta versão já recebeu decisão.',
        code: '23505',
      );
    }

    if (targetReq.currentSubmissionId != targetSub.id ||
        targetReq.currentVersion != targetSub.version) {
      throw const PostgrestException(
        message: '[ERR:obsolete_submission_version] Apenas a versão vigente pode ser revisada.',
        code: '23505',
      );
    }

    if (targetReq.status != RequirementStatus.underReview ||
        targetSub.status != SubmissionStatus.underReview) {
      throw const PostgrestException(
        message:
            '[ERR:requirement_status_conflict] Requisito não está em análise.',
        code: '23505',
      );
    }

    final reviewRecord = DocumentReviewRecord(
      id: 'rev-${targetSub.id}',
      processId: targetProc.id,
      processRequirementId: targetReq.id,
      submissionId: targetSub.id,
      reviewerId: user.id,
      decision: decision,
      reason: cleanReason.isEmpty ? null : cleanReason,
      reviewedAt: DateTime.utc(2026, 11, 20, 15, 30).toLocal(),
    );

    reviewsByReqId[targetReq.id] = <DocumentReviewRecord>[
      reviewRecord,
      ...existingReviews,
    ];
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      reviewsByIdempotencyKey['${user.id}|$idempotencyKey'] = reviewRecord;
    }

    final updatedSub = DocumentSubmissionRecord(
      id: targetSub.id,
      processId: targetSub.processId,
      processRequirementId: targetSub.processRequirementId,
      submittedBy: targetSub.submittedBy,
      version: targetSub.version,
      storageBucket: targetSub.storageBucket,
      storagePath: targetSub.storagePath,
      originalFilename: targetSub.originalFilename,
      mimeType: targetSub.mimeType,
      sizeBytes: targetSub.sizeBytes,
      sha256Checksum: targetSub.sha256Checksum,
      idempotencyKey: targetSub.idempotencyKey,
      status: decision == ReviewDecision.approved
          ? SubmissionStatus.approved
          : SubmissionStatus.correctionRequested,
      submittedAt: targetSub.submittedAt,
      createdAt: targetSub.createdAt,
    );

    final subList = submissionsByReqId[targetReq.id]!;
    final subIdx = subList.indexWhere((s) => s.id == updatedSub.id);
    subList[subIdx] = updatedSub;

    final updatedReq = ProcessRequirementItem(
      id: targetReq.id,
      processId: targetReq.processId,
      templateItemId: targetReq.templateItemId,
      code: targetReq.code,
      title: targetReq.title,
      description: targetReq.description,
      acceptanceCriteria: targetReq.acceptanceCriteria,
      isRequired: targetReq.isRequired,
      displayOrder: targetReq.displayOrder,
      status: decision == ReviewDecision.approved
          ? RequirementStatus.approved
          : RequirementStatus.correctionRequested,
      currentSubmissionId: targetReq.currentSubmissionId,
      currentVersion: targetReq.currentVersion,
      createdAt: targetReq.createdAt,
      updatedAt: DateTime.now(),
    );

    final reqList = requirementsByProcessId[targetProc.id]!;
    final reqIdx = reqList.indexWhere((r) => r.id == updatedReq.id);
    reqList[reqIdx] = updatedReq;

    final requiredReqs = reqList.where((r) => r.isRequired).toList();
    final allRequiredApproved =
        requiredReqs.isNotEmpty &&
        requiredReqs.every((r) => r.status == RequirementStatus.approved);
    final nextProcessStatus = allRequiredApproved
        ? ProcessStatus.documentallyComplete
        : targetProc.status;

    _refreshProcessSummary(targetProc.id, newStatus: nextProcessStatus);
    final updatedProcess = processesById[targetProc.id]!;

    final reviewEvent = ProcessAuditTimelineEvent(
      eventId: 'evt-${++_eventCounter}',
      processId: targetProc.id,
      eventType: decision == ReviewDecision.approved
          ? AuditEventType.documentApproved
          : AuditEventType.documentCorrectionRequested,
      rawEventType: decision == ReviewDecision.approved
          ? 'document_approved'
          : 'document_correction_requested',
      actorId: user.id,
      actorRole: 'reviewer',
      actorDisplayName: user.fullName ?? 'Revisor',
      targetUserId: targetProc.ownerId,
      entityTable: 'document_reviews',
      entityId: reviewRecord.id,
      processRequirementId: updatedReq.id,
      requirementCode: updatedReq.code,
      requirementTitle: updatedReq.title,
      submissionId: updatedSub.id,
      submissionVersion: updatedSub.version,
      decision: decision,
      reason: reviewRecord.reason,
      processStatus: updatedProcess.status,
      institutionId: targetProc.institutionId,
      courseId: targetProc.courseId,
      courseModalityId: targetProc.courseModalityId,
      occurredAt: reviewRecord.reviewedAt,
      metadata: <String, dynamic>{
        'review_id': reviewRecord.id,
        'submission_id': updatedSub.id,
        'version': updatedSub.version,
        'decision': decision.value,
        'reason': reviewRecord.reason,
        'not_official_internship_authorization': true,
      },
    );

    final nextTimeline = <ProcessAuditTimelineEvent>[
      reviewEvent,
      ...(timelineByProcessId[targetProc.id] ?? const []),
    ];

    if (allRequiredApproved &&
        targetProc.status != ProcessStatus.documentallyComplete) {
      nextTimeline.insert(
        0,
        ProcessAuditTimelineEvent(
          eventId: 'evt-${++_eventCounter}',
          processId: targetProc.id,
          eventType: AuditEventType.processDocumentallyCompleted,
          rawEventType: 'process_documentally_completed',
          actorId: user.id,
          actorRole: 'reviewer',
          actorDisplayName: user.fullName ?? 'Revisor',
          targetUserId: targetProc.ownerId,
          entityTable: 'internship_processes',
          entityId: targetProc.id,
          processStatus: ProcessStatus.documentallyComplete,
          institutionId: targetProc.institutionId,
          courseId: targetProc.courseId,
          courseModalityId: targetProc.courseModalityId,
          occurredAt: reviewRecord.reviewedAt.add(const Duration(seconds: 1)),
          metadata: <String, dynamic>{
            'triggered_by_review_id': reviewRecord.id,
            'required_total': requiredReqs.length,
            'required_approved': requiredReqs.length,
            'not_official_internship_authorization': true,
          },
        ),
      );
    }

    timelineByProcessId[targetProc.id] = nextTimeline;

    return ReviewDecisionOutcome(
      ok: true,
      idempotentReplay: false,
      review: reviewRecord,
      submission: updatedSub,
      requirement: updatedReq,
      process: updatedProcess,
      progress: updatedProcess.progress,
    );
  }

  @override
  Future<PaginatedResult<ProcessAuditTimelineEvent>> fetchProcessAuditTimeline({
    required String processId,
    int page = 0,
    int pageSize = kDefaultReviewPageSize,
    bool oldestFirst = false,
  }) async {
    fetchTimelineCalls++;
    if (pendingFetchTimeline != null) {
      return pendingFetchTimeline!.future;
    }
    if (nextTimelineError != null) {
      final err = nextTimelineError!;
      nextTimelineError = null;
      throw err;
    }

    final user = activeUserProvider();
    if (user == null) {
      throw const PostgrestException(message: 'JWT expired', code: 'PGRST301');
    }

    final proc = processesById[processId];
    if (proc == null || !_canAccessProcess(user, proc)) {
      return PaginatedResult<ProcessAuditTimelineEvent>(
        items: const <ProcessAuditTimelineEvent>[],
        totalCount: 0,
        page: page,
        pageSize: pageSize,
      );
    }

    final events = List<ProcessAuditTimelineEvent>.from(
      timelineByProcessId[processId] ?? const <ProcessAuditTimelineEvent>[],
    );
    events.sort((a, b) {
      final cmpTime = a.occurredAt.compareTo(b.occurredAt);
      final cmp = cmpTime != 0 ? cmpTime : a.eventId.compareTo(b.eventId);
      return oldestFirst ? cmp : -cmp;
    });

    final total = events.length;
    final start = page * pageSize;
    final pageItems = start >= total
        ? const <ProcessAuditTimelineEvent>[]
        : events.skip(start).take(pageSize).toList(growable: false);

    return PaginatedResult<ProcessAuditTimelineEvent>(
      items: pageItems,
      totalCount: total,
      page: page,
      pageSize: pageSize,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_installDefaultAndroidPdfChannelSimulator);

  group('Lote 4 (ESP-18 a ESP-22): Modelos e Mapeamento de Erros do Contrato', () {
    test('SupabaseReviewRepository.mapError mapeia todas as tags [ERR:...] e SQLSTATE sem vazar SQL, JWT ou paths', () {
      const fakeJwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI5OTkifQ.secret_sig';
      final cases = <(String code, String message, String expectedTag)>[
        (
          '42501',
          '[ERR:unauthorized_session] Sessão inválida token=$fakeJwt',
          'unauthorized_session',
        ),
        (
          '42501',
          '[ERR:forbidden_role] role=student SELECT * FROM profiles',
          'forbidden_role',
        ),
        (
          '42501',
          '[ERR:forbidden_scope] reviewer_assignments scope=123',
          'forbidden_scope',
        ),
        (
          '42501',
          '[ERR:process_cancelled] internship_processes cancelled',
          'process_cancelled',
        ),
        ('22023', '[ERR:invalid_input] p_submission_id null', 'invalid_input'),
        (
          '22023',
          '[ERR:invalid_decision] decision=invalid',
          'invalid_decision',
        ),
        (
          '22023',
          '[ERR:missing_correction_reason] reason is empty',
          'missing_correction_reason',
        ),
        ('22023', '[ERR:reason_too_long] length > 2000', 'reason_too_long'),
        (
          'P0002',
          '[ERR:submission_not_found] document_submissions not found',
          'submission_not_found',
        ),
        (
          '23505',
          '[ERR:submission_already_reviewed] uq_document_reviews',
          'submission_already_reviewed',
        ),
        (
          '23505',
          '[ERR:obsolete_submission_version] current_submission_id != sub',
          'obsolete_submission_version',
        ),
        (
          '23505',
          '[ERR:requirement_status_conflict] status != under_review',
          'requirement_status_conflict',
        ),
        (
          '23505',
          '[ERR:idempotency_mismatch] uq_document_reviews_reviewer_idempotency',
          'idempotency_mismatch',
        ),
      ];

      for (final c in cases) {
        final failure = SupabaseReviewRepository.mapError(
          PostgrestException(message: c.$2, code: c.$1),
        );
        expect(failure.code, c.$3);
        expect(failure.message.isNotEmpty, isTrue);
        expect(failure.message, isNot(contains('[ERR:')));
        expect(failure.message, isNot(contains(fakeJwt)));
        expect(failure.message, isNot(contains('SELECT *')));
        expect(failure.message, isNot(contains('uq_document_reviews')));
      }

      final storageRevoked = SupabaseReviewRepository.mapError(
        const StorageException(
          'new row violates row-level security policy for object /processes/1/secret.pdf',
          statusCode: '403',
        ),
      );
      expect(storageRevoked.isForbiddenScope, isTrue);
      expect(storageRevoked.isUnauthorized, isTrue);
      expect(storageRevoked.message, isNot(contains('secret.pdf')));

      final authExpired = SupabaseReviewRepository.mapError(
        const AuthException('JWT expired'),
      );
      expect(authExpired.isUnauthorized, isTrue);
      expect(authExpired.message, isNot(contains('JWT')));
    });

    test('VerifiedPdfPayload faz cópia defensiva e wipeBytes zera todos os bytes em memória sem corromper origem', () {
      final sourceBytes = _validPdfBytes('Original Buffer');
      final payload = VerifiedPdfPayload(
        submissionId: 'sub-1',
        submissionVersion: 1,
        processId: 'proc-1',
        processRequirementId: 'req-1',
        requirementCode: 'REQ_01',
        requirementTitle: 'Termo',
        studentName: 'Estudante A',
        originalFilename: 'termo.pdf',
        storageBucket: kPrivateDocumentsBucket,
        storagePath: 'processes/proc-1/requirements/req-1/submissions/1.pdf',
        bytes: sourceBytes,
        loadedAt: DateTime(2026, 11, 20),
      );

      expect(payload.hasValidPdfSignature, isTrue);
      expect(payload.isWiped, isFalse);
      expect(payload.headerSnippet, contains('%PDF-1.4'));

      payload.wipeBytes();

      expect(payload.isWiped, isTrue);
      expect(payload.bytes.every((b) => b == 0), isTrue);
      expect(payload.headerSnippet, isEmpty);
      // O buffer original do teste não foi corrompido
      expect(PdfPreliminaryValidation.hasPdfHeader(sourceBytes), isTrue);
    });
  });

  group('ESP-18: Fila paginada do revisor, filtros, loading/empty/error/retry e escopo', () {
    testWidgets(
      'Revisor passa por loading, erro com retry, paginação, filtros e revisor sem assignment vê fila vazia',
      (tester) async {
        UserProfile? currentUser = _assignedReviewerR1;
        final backend = _InMemoryLot4Backend(
          activeUserProvider: () => currentUser,
        );

        // Estudante A envia documento v1 para popular a fila do escopo
        currentUser = _studentA;
        await backend.submitRequirementPdf(
          processRequirementId: 'req-a-1',
          file: SelectedPdfFile(
            name: 'tce_aluno_a_v1.pdf',
            bytes: _validPdfBytes('TCE V1'),
          ),
          idempotencyKey: 'idem-seed-v1',
        );
        await backend.submitRequirementPdf(
          processRequirementId: 'req-a-2',
          file: SelectedPdfFile(
            name: 'anexo_opcional_v1.pdf',
            bytes: _validPdfBytes('OPC V1'),
          ),
          idempotencyKey: 'idem-seed-opt-v1',
        );

        currentUser = _assignedReviewerR1;
        final authGateway = _ReviewTestAuthGateway(
          currentProfile: _assignedReviewerR1,
        );
        final authController = AuthController(gateway: authGateway);
        final queueCompleter = Completer<PaginatedResult<ReviewerQueueItem>>();
        backend.pendingFetchQueue = queueCompleter;

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: backend,
            documentRepository: backend,
            reviewRepository: backend,
          ),
        );
        await tester.pump();

        // 1) Loading state
        expect(find.text('Carregando fila de revisão...'), findsOneWidget);

        // 2) Erro inicial e botão de retry
        queueCompleter.completeError(
          const ReviewFailure(
            'Falha de conexão com o servidor. Verifique sua rede e tente novamente.',
            code: 'network_error',
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('reviewer_queue_error_box')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('reviewer_queue_retry_button')),
          findsOneWidget,
        );

        // 3) Retry carrega os 2 itens vigentes em under_review dentro do escopo de R1
        backend.pendingFetchQueue = null;
        final retryBtn = find.byKey(const Key('reviewer_queue_retry_button'));
        await tester.ensureVisible(retryBtn);
        await tester.tap(retryBtn);
        await tester.pumpAndSettle();

        expect(
          find.text('Fila de documentos para revisão (2)'),
          findsOneWidget,
        );
        expect(
          find.text('Termo de Compromisso de Estágio (Fictício)'),
          findsWidgets,
        );
        expect(
          find.text('Documento Complementar Opcional (Fictício)'),
          findsOneWidget,
        );

        // 4) Filtro "Apenas obrigatórios" reduz fila para 1 item
        await tester.tap(
          find.byKey(const Key('reviewer_filter_required_only')),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Fila de documentos para revisão (1)'),
          findsOneWidget,
        );

        // 5) Limpar filtros restaura 2 itens
        await tester.tap(
          find.byKey(const Key('reviewer_clear_filters_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Fila de documentos para revisão (2)'),
          findsOneWidget,
        );

        // 6) Trocar para Revisor R2 (sem assignment ativo no escopo) -> vê 0 itens e estado vazio
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();

        currentUser = _unassignedReviewerR2;
        authGateway.nextSignInProfile = _unassignedReviewerR2;
        await authController.signIn(
          email: _unassignedReviewerR2.email,
          password: 'DemoPassword!123',
        );
        await tester.pumpAndSettle();

        expect(find.text('Revisor Sem Escopo R2'), findsOneWidget);
        expect(
          find.text('Fila de documentos para revisão (0)'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('reviewer_queue_empty_state')),
          findsOneWidget,
        );
        expect(
          find.text(
            'Nenhum documento pendente de revisão no seu escopo atribuído',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('ESP-19 e ESP-20: PDF autenticado, proteção de memória, validações, confirmação, duplo clique, retries e conflitos', () {
    testWidgets(
      'Visualização de PDF autenticado, revogação de escopo 403, justificativa obrigatória para correção, bloqueio de duplo clique e limpeza de bytes em logout',
      (tester) async {
        UserProfile? currentUser = _studentA;
        final backend = _InMemoryLot4Backend(
          activeUserProvider: () => currentUser,
        );
        final picker = _FakePdfPicker();

        final outcomeV1 = await backend.submitRequirementPdf(
          processRequirementId: 'req-a-1',
          file: SelectedPdfFile(
            name: 'tce_privado_v1.pdf',
            bytes: _validPdfBytes('Conteudo Confidencial V1'),
          ),
          idempotencyKey: 'idem-esp19-v1',
        );

        currentUser = _assignedReviewerR1;
        final authGateway = _ReviewTestAuthGateway(
          currentProfile: _assignedReviewerR1,
        );
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 960));
        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: backend,
            documentRepository: backend,
            reviewRepository: backend,
            pdfPickerGateway: picker,
          ),
        );
        await tester.pumpAndSettle();

        // Metadados obrigatórios precedem a decisão (RN3 ESP-19)
        expect(
          find.byKey(const Key('inspected_version_badge')),
          findsOneWidget,
        );
        expect(find.text('Versão vigente em análise: v1'), findsOneWidget);
        expect(
          find.text('ID da submissão: ${outcomeV1.submission.id}'),
          findsOneWidget,
        );
        expect(find.text('Estudante: Estudante A Fictício'), findsOneWidget);

        // Carregar PDF pelo Storage autenticado
        final loadPdfBtn = find.byKey(const Key('reviewer_load_pdf_button'));
        await tester.ensureVisible(loadPdfBtn);
        await tester.tap(loadPdfBtn);
        await tester.pumpAndSettle();

        expect(backend.downloadCalls, 1);
        expect(backend.downloadRequests, <String>[outcomeV1.submission.id]);
        expect(
          find.byKey(const Key('reviewer_pdf_viewer_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('pdf_viewer_raster_image_p1')),
          findsOneWidget,
        );

        // Salvar/abrir PDF localmente via PdfPickerGateway
        final savePdfBtn = find.byKey(const Key('reviewer_save_pdf_button'));
        await tester.ensureVisible(savePdfBtn);
        await tester.tap(savePdfBtn);
        await tester.pumpAndSettle();
        expect(picker.saveCalls, 1);
        expect(picker.lastSavedFilename, 'tce_privado_v1.pdf');

        // Selecionar "Solicitar correção" com justificativa vazia -> bloqueia e exibe erro
        final selectCorrectionChip = find.byKey(
          const Key('reviewer_select_correction_button'),
        );
        await tester.ensureVisible(selectCorrectionChip);
        await tester.tap(selectCorrectionChip);
        await tester.pumpAndSettle();

        final prepareBtn = find.byKey(
          const Key('reviewer_prepare_decision_button'),
        );
        await tester.ensureVisible(prepareBtn);
        await tester.tap(prepareBtn);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('reviewer_decision_error_banner')),
          findsOneWidget,
        );
        expect(
          find.text(
            'Informe a justificativa obrigatória para solicitar correção.',
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('reviewer_confirm_decision_card')),
          findsNothing,
        );
        expect(backend.reviewRpcCalls, 0);

        // Preencher justificativa válida e abrir card de confirmação
        final reasonField = find.byKey(const Key('reviewer_reason_field'));
        await tester.ensureVisible(reasonField);
        await tester.enterText(
          reasonField,
          'Assinatura do supervisor ausente na página 2.',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(prepareBtn);
        await tester.pumpAndSettle();
        await tester.tap(prepareBtn);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('reviewer_confirm_decision_card')),
          findsOneWidget,
        );
        expect(
          find.textContaining('não equivale a autorização oficial de estágio'),
          findsWidgets,
        );

        // Testar bloqueio de duplo clique durante chamada RPC pendente
        final rpcCompleter = Completer<ReviewDecisionOutcome>();
        backend.pendingReviewRpc = rpcCompleter;

        final confirmSubmitBtn = find.byKey(
          const Key('reviewer_confirm_submit_button'),
        );
        await tester.ensureVisible(confirmSubmitBtn);
        await tester.tap(confirmSubmitBtn);
        await tester.pump();
        await tester.tap(confirmSubmitBtn, warnIfMissed: false);
        await tester.pump();

        expect(backend.reviewRpcCalls, 1);
        expect(find.text('Registrando decisão...'), findsOneWidget);

        // Concluir RPC
        backend.pendingReviewRpc = null;
        final realOutcome = await backend.reviewSubmission(
          submissionId: outcomeV1.submission.id,
          decision: ReviewDecision.correctionRequested,
          reason: 'Assinatura do supervisor ausente na página 2.',
          idempotencyKey: backend.reviewIdempotencyKeys.first,
        );
        rpcCompleter.complete(realOutcome);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('reviewer_feedback_banner')),
          findsOneWidget,
        );
        expect(find.textContaining('correção solicitada'), findsWidgets);
        // Item saiu da fila e PDF carregado foi descartado da memória
        expect(find.byKey(const Key('reviewer_pdf_viewer_card')), findsNothing);
        expect(
          find.text('Fila de documentos para revisão (0)'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    test('Retry idempotente preserva idempotency_key em falha de rede, conflito 409 recarrega estado, revogação 403 limpa escopo e logout/dispose zeram bytes de PDF', () async {
      UserProfile? currentUser = _studentA;
      final backend = _InMemoryLot4Backend(
        activeUserProvider: () => currentUser,
      );
      final subV1 = await backend.submitRequirementPdf(
        processRequirementId: 'req-a-1',
        file: SelectedPdfFile(
          name: 'tce_retry.pdf',
          bytes: _validPdfBytes('PDF Retry Memory Test'),
        ),
        idempotencyKey: 'idem-sub-retry',
      );

      currentUser = _assignedReviewerR1;
      final controller = ReviewerController(
        repository: backend,
        pickerGateway: _FakePdfPicker(),
      );
      await controller.loadQueue();
      expect(controller.queueItems.length, 1);
      expect(controller.selectedItem?.submissionId, subV1.submission.id);

      // 1) Carregar PDF e guardar referência ao payload para verificar wipeBytes
      final loadedOk = await controller.loadAuthenticatedPdfForSelected();
      expect(loadedOk, isTrue);
      final pdfPayloadRef = controller.loadedPdf!;
      expect(pdfPayloadRef.isWiped, isFalse);

      // 2) Falha de timeout na 1ª tentativa de decisão -> preserva mesma idempotency_key e motivo
      controller.selectDecision(ReviewDecision.correctionRequested);
      controller.updateReason('Corrigir CNPJ da concedente.');
      expect(controller.prepareDecisionConfirmation(), isTrue);

      backend.nextReviewRpcError = TimeoutException('timeout');
      final attempt1 = await controller.submitConfirmedDecision();
      expect(attempt1, isFalse);
      expect(controller.hasAmbiguousDecisionRetryPending, isTrue);
      final firstKey = controller.pendingDecisionIdempotencyKey;
      expect(firstKey, isNotNull);
      expect(controller.reasonText, 'Corrigir CNPJ da concedente.');

      // 3) Retry usa exatamente a mesma idempotency_key e conclui com sucesso
      final attempt2 = await controller.submitConfirmedDecision();
      expect(attempt2, isTrue);
      expect(backend.reviewIdempotencyKeys.sublist(0, 2), <String?>[
        firstKey,
        firstKey,
      ]);
      // O PDF da submissão decidida foi zerado da memória após a decisão
      expect(pdfPayloadRef.isWiped, isTrue);
      expect(pdfPayloadRef.bytes.every((b) => b == 0), isTrue);
      expect(controller.loadedPdf, isNull);

      // 4) Testar conflito de versão obsoleta ([ERR:obsolete_submission_version]) e revogação de escopo
      currentUser = _studentA;
      final subV2 = await backend.submitRequirementPdf(
        processRequirementId: 'req-a-1',
        file: SelectedPdfFile(
          name: 'tce_v2.pdf',
          bytes: _validPdfBytes('PDF V2'),
        ),
        idempotencyKey: 'idem-sub-v2',
      );

      currentUser = _assignedReviewerR1;
      await controller.loadQueue();
      expect(controller.selectedItem?.submissionId, subV2.submission.id);
      expect(controller.selectedItem?.submissionVersion, 2);

      await controller.loadAuthenticatedPdfForSelected();
      final v2PayloadRef = controller.loadedPdf!;
      expect(v2PayloadRef.isWiped, isFalse);

      // Simular conflito de versão obsoleta retornado pelo backend
      backend.nextReviewRpcError = const PostgrestException(
        message: '[ERR:obsolete_submission_version] Apenas a versão vigente pode ser revisada.',
        code: '23505',
      );
      controller.selectDecision(ReviewDecision.approved);
      controller.prepareDecisionConfirmation();
      final conflictResult = await controller.submitConfirmedDecision();
      expect(conflictResult, isFalse);
      expect(v2PayloadRef.isWiped, isTrue);
      expect(
        controller.feedbackMessage,
        contains('apenas a versão vigente pode ser revisada'),
      );

      // 5) Revogação de assignment durante tentativa de visualizar PDF
      await controller.loadAuthenticatedPdfForSelected();
      final activePdfBeforeRevoke = controller.loadedPdf!;
      backend.assignedScopeKeysForR1.clear(); // Revoga assignment de R1
      final downloadAfterRevoke = await controller
          .loadAuthenticatedPdfForSelected();
      expect(downloadAfterRevoke, isFalse);
      expect(activePdfBeforeRevoke.isWiped, isTrue);
      expect(controller.loadedPdf, isNull);
      expect(controller.pdfErrorMessage, contains('atribuição revogada'));

      // 6) Logout / clearPrivateState + dispose com requisição pendente não notifica após dispose
      backend.assignedScopeKeysForR1.add('inst-1|course-1|mod-1');
      await controller.loadQueue();
      await controller.loadAuthenticatedPdfForSelected();
      final pdfBeforeLogout = controller.loadedPdf!;

      final lateQueueCompleter =
          Completer<PaginatedResult<ReviewerQueueItem>>();
      backend.pendingFetchQueue = lateQueueCompleter;
      final pendingQueueFuture = controller.loadQueue();

      var disposed = false;
      var postDisposeNotifications = 0;
      controller.addListener(() {
        if (disposed) postDisposeNotifications++;
      });

      controller.clearPrivateState();
      expect(pdfBeforeLogout.isWiped, isTrue);
      expect(pdfBeforeLogout.bytes.every((b) => b == 0), isTrue);
      expect(controller.loadedPdf, isNull);
      expect(controller.queueItems, isEmpty);

      disposed = true;
      controller.dispose();

      lateQueueCompleter.complete(
        const PaginatedResult<ReviewerQueueItem>(
          items: <ReviewerQueueItem>[],
          totalCount: 0,
          page: 0,
          pageSize: 20,
        ),
      );
      await pendingQueueFuture;
      expect(postDisposeNotifications, 0);
    });
  });

  group('ESP-21 e ESP-22: Ciclo ponta a ponta (Aluno envia v1 -> Revisor solicita correção -> Aluno vê motivo e reenvia v2 -> Revisor aprova -> Progresso e Timeline)', () {
    testWidgets(
      'Fluxo completo multiusuário com preservação de v1, reentrada de v2 na fila, progresso 100% sem "estágio autorizado", timeline imutável e isolamento cross-user',
      (tester) async {
        UserProfile? currentUser = _studentA;
        final backend = _InMemoryLot4Backend(
          activeUserProvider: () => currentUser,
        );
        final picker = _FakePdfPicker();
        final authGateway = _ReviewTestAuthGateway(currentProfile: _studentA);
        final authController = AuthController(gateway: authGateway);

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 960));
        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: backend,
            documentRepository: backend,
            reviewRepository: backend,
            pdfPickerGateway: picker,
          ),
        );
        await tester.pumpAndSettle();

        // 1) Estudante A abre detalhe do processo e envia PDF v1 para TCE_OBRIG_01
        await tester.tap(find.byKey(const Key('open_process_detail_proc-a-1')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('process_audit_timeline_section')),
          findsOneWidget,
        );
        expect(find.text('Processo aberto e checklist gerado'), findsOneWidget);

        picker.nextPickedFile = SelectedPdfFile(
          name: 'tce_versao_1.pdf',
          bytes: _validPdfBytes('TCE Versao 1'),
        );
        final pickV1Btn = find.byKey(const Key('pick_pdf_button_TCE_OBRIG_01'));
        await tester.ensureVisible(pickV1Btn);
        await tester.tap(pickV1Btn);
        await tester.pumpAndSettle();

        final submitV1Btn = find.byKey(
          const Key('submit_pdf_button_TCE_OBRIG_01'),
        );
        await tester.ensureVisible(submitV1Btn);
        await tester.tap(submitV1Btn);
        await tester.pumpAndSettle();

        expect(find.text('Versão da submissão: v1'), findsOneWidget);
        expect(find.text('Submissão de PDF enviada (v1)'), findsOneWidget);

        // 2) Cross-user: Estudante B entra e não vê nenhum processo, PDF ou evento de A
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();

        currentUser = _studentB;
        authGateway.nextSignInProfile = _studentB;
        await authController.signIn(
          email: _studentB.email,
          password: 'DemoPassword!123',
        );
        await tester.pumpAndSettle();

        expect(find.text('Estudante B Fictício'), findsOneWidget);
        expect(find.byKey(const Key('processes_empty_state')), findsOneWidget);
        expect(find.text('tce_versao_1.pdf'), findsNothing);
        await expectLater(
          backend.downloadSubmissionBytes(submissionId: 'sub-req-a-1-v1'),
          throwsA(isA<FunctionException>()),
        );

        // 3) Revisor R1 entra, vê v1 na fila, visualiza PDF e solicita correção com motivo
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();

        currentUser = _assignedReviewerR1;
        authGateway.nextSignInProfile = _assignedReviewerR1;
        await authController.signIn(
          email: _assignedReviewerR1.email,
          password: 'DemoPassword!123',
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Fila de documentos para revisão (1)'),
          findsOneWidget,
        );
        expect(find.text('Versão vigente em análise: v1'), findsOneWidget);

        final selectCorr = find.byKey(
          const Key('reviewer_select_correction_button'),
        );
        await tester.ensureVisible(selectCorr);
        await tester.tap(selectCorr);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('reviewer_reason_field')),
          'Incluir carimbo e assinatura da empresa na página 3.',
        );
        await tester.pump();

        final prepareCorrBtn = find.byKey(
          const Key('reviewer_prepare_decision_button'),
        );
        await tester.ensureVisible(prepareCorrBtn);
        await tester.tap(prepareCorrBtn);
        await tester.pumpAndSettle();

        final confirmCorrBtn = find.byKey(
          const Key('reviewer_confirm_submit_button'),
        );
        await tester.ensureVisible(confirmCorrBtn);
        await tester.tap(confirmCorrBtn);
        await tester.pumpAndSettle();

        expect(
          find.text('Fila de documentos para revisão (0)'),
          findsOneWidget,
        );
        expect(
          find.text('Revisão registrada: correção solicitada'),
          findsOneWidget,
        );

        // 4) Estudante A entra, lê o motivo da correção de v1 e reenvia novo PDF v2
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();

        currentUser = _studentA;
        authGateway.nextSignInProfile = _studentA;
        await authController.signIn(
          email: _studentA.email,
          password: 'DemoPassword!123',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('open_process_detail_proc-a-1')));
        await tester.pumpAndSettle();

        expect(find.text('Correção solicitada: 1'), findsOneWidget);
        expect(
          find.byKey(const Key('correction_requested_notice_TCE_OBRIG_01')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('review_reason_TCE_OBRIG_01_v1')),
          findsOneWidget,
        );
        expect(
          find.text(
            'Observação da revisão: Incluir carimbo e assinatura da empresa na página 3.',
          ),
          findsOneWidget,
        );

        // Reenviar PDF v2
        picker.nextPickedFile = SelectedPdfFile(
          name: 'tce_corrigido_versao_2.pdf',
          bytes: _validPdfBytes('TCE Versao 2 Corrigida'),
        );
        final pickV2Btn = find.byKey(const Key('pick_pdf_button_TCE_OBRIG_01'));
        await tester.ensureVisible(pickV2Btn);
        await tester.tap(pickV2Btn);
        await tester.pumpAndSettle();

        final submitV2Btn = find.byKey(
          const Key('submit_pdf_button_TCE_OBRIG_01'),
        );
        await tester.ensureVisible(submitV2Btn);
        await tester.tap(submitV2Btn);
        await tester.pumpAndSettle();

        // Versão v2 é vigente em análise; versão v1 antiga permanece preservada com sua justificativa!
        expect(find.text('Versão da submissão: v2'), findsOneWidget);
        expect(
          find.byKey(const Key('current_version_badge_TCE_OBRIG_01_v2')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('historical_version_badge_TCE_OBRIG_01_v1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('review_reason_TCE_OBRIG_01_v1')),
          findsOneWidget,
        );
        expect(find.text('Reenvio de PDF após correção (v2)'), findsOneWidget);

        // 5) Revisor R1 entra novamente, vê v2 na fila com badge "Reenvio após correção" e aprova v2
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();

        currentUser = _assignedReviewerR1;
        authGateway.nextSignInProfile = _assignedReviewerR1;
        await authController.signIn(
          email: _assignedReviewerR1.email,
          password: 'DemoPassword!123',
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Fila de documentos para revisão (1)'),
          findsOneWidget,
        );
        expect(find.text('Versão vigente em análise: v2'), findsOneWidget);
        expect(
          find.byKey(const Key('resubmission_badge_sub-req-a-1-v2')),
          findsOneWidget,
        );
        // Histórico do requisito para o revisor mostra v2 vigente e v1 histórica preservada
        expect(
          find.byKey(const Key('reviewer_history_version_v2')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('reviewer_history_version_v1')),
          findsOneWidget,
        );

        final prepareApproveBtn = find.byKey(
          const Key('reviewer_prepare_decision_button'),
        );
        await tester.ensureVisible(prepareApproveBtn);
        await tester.tap(prepareApproveBtn);
        await tester.pumpAndSettle();

        final confirmApproveBtn = find.byKey(
          const Key('reviewer_confirm_submit_button'),
        );
        await tester.ensureVisible(confirmApproveBtn);
        await tester.tap(confirmApproveBtn);
        await tester.pumpAndSettle();

        expect(
          find.text('Fila de documentos para revisão (0)'),
          findsOneWidget,
        );
        expect(
          find.text('Checklist concluído sem pendências documentais'),
          findsOneWidget,
        );

        // 6) Estudante A verifica progresso 100% ("Sem pendências documentais") e ausência total de "estágio autorizado"
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();

        currentUser = _studentA;
        authGateway.nextSignInProfile = _studentA;
        await authController.signIn(
          email: _studentA.email,
          password: 'DemoPassword!123',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('open_process_detail_proc-a-1')));
        await tester.pumpAndSettle();

        expect(find.text('Sem pendências documentais'), findsWidgets);
        expect(
          find.text('1 de 1 obrigatórios aprovados (100%)'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'A conclusão documental não representa autorização oficial de estágio',
          ),
          findsWidgets,
        );
        expect(
          find.textContaining('estágio autorizado', findRichText: true),
          findsNothing,
        );
        expect(
          find.textContaining('Estágio autorizado', findRichText: true),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Layout compacto Android (320x640 e 360x780) no painel do revisor renderiza fila, metadados, PDF, formulário e timeline sem overflow',
      (tester) async {
        UserProfile? currentUser = _studentA;
        final backend = _InMemoryLot4Backend(
          activeUserProvider: () => currentUser,
        );
        await backend.submitRequirementPdf(
          processRequirementId: 'req-a-1',
          file: SelectedPdfFile(
            name: 'termo_de_compromisso_de_estagio_supervisionado_nome_extenso_v1.pdf',
            bytes: _validPdfBytes('Compact Mobile Reviewer Test'),
          ),
          idempotencyKey: 'idem-compact-rev-1',
        );

        currentUser = _assignedReviewerR1;
        final authGateway = _ReviewTestAuthGateway(
          currentProfile: _assignedReviewerR1,
        );
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        for (final size in const <Size>[Size(320, 640), Size(360, 780)]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(
            EstagioSemPendenciaApp(
              key: ValueKey('rev_compact_${size.width}'),
              authController: authController,
              processRepository: backend,
              documentRepository: backend,
              reviewRepository: backend,
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.text('Perfil Revisor (Escopo Protegido)'),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('process_audit_timeline_section')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      },
    );

    test('ProcessTimelineController pagina, alterna ordenação, trata erro com retry e descarta respostas tardias após logout/dispose', () async {
      UserProfile? currentUser = _studentA;
      final backend = _InMemoryLot4Backend(
        activeUserProvider: () => currentUser,
      );
      await backend.submitRequirementPdf(
        processRequirementId: 'req-a-1',
        file: SelectedPdfFile(name: 'tce_v1.pdf', bytes: _validPdfBytes('v1')),
        idempotencyKey: 'idem-tl-1',
      );
      currentUser = _assignedReviewerR1;
      await backend.reviewSubmission(
        submissionId: 'sub-req-a-1-v1',
        decision: ReviewDecision.correctionRequested,
        reason: 'Motivo timeline 1',
        idempotencyKey: 'idem-tl-rev-1',
      );

      final timelineCtrl = ProcessTimelineController(
        repository: backend,
        pageSize: 2,
      );

      await timelineCtrl.loadTimeline('proc-a-1');
      expect(timelineCtrl.status, ReviewLoadStatus.loaded);
      expect(timelineCtrl.totalCount, 3);
      expect(timelineCtrl.totalPages, 2);
      expect(timelineCtrl.events.length, 2);
      expect(timelineCtrl.hasNextPage, isTrue);

      await timelineCtrl.nextPage();
      expect(timelineCtrl.currentPage, 1);
      expect(timelineCtrl.events.length, 1);
      expect(timelineCtrl.hasPreviousPage, isTrue);

      await timelineCtrl.previousPage();
      expect(timelineCtrl.currentPage, 0);

      await timelineCtrl.toggleSortOrder();
      expect(timelineCtrl.oldestFirst, isTrue);
      expect(
        timelineCtrl.events.first.eventType,
        AuditEventType.processCreated,
      );

      // Erro e recuperação via refresh
      backend.nextTimelineError = const PostgrestException(
        message: 'transient timeline error',
      );
      await timelineCtrl.refresh();
      expect(timelineCtrl.status, ReviewLoadStatus.error);
      expect(timelineCtrl.errorMessage, isNotNull);

      await timelineCtrl.refresh();
      expect(timelineCtrl.status, ReviewLoadStatus.loaded);

      // Resposta tardia pós-clearPrivateState / dispose não muta estado nem notifica
      final pendingTl = Completer<PaginatedResult<ProcessAuditTimelineEvent>>();
      backend.pendingFetchTimeline = pendingTl;
      final future = timelineCtrl.refresh();

      var disposed = false;
      var postDisposeCalls = 0;
      timelineCtrl.addListener(() {
        if (disposed) postDisposeCalls++;
      });

      timelineCtrl.clearPrivateState();
      expect(timelineCtrl.events, isEmpty);
      disposed = true;
      timelineCtrl.dispose();

      pendingTl.complete(
        const PaginatedResult<ProcessAuditTimelineEvent>(
          items: <ProcessAuditTimelineEvent>[],
          totalCount: 0,
          page: 0,
          pageSize: 2,
        ),
      );
      await future;
      expect(postDisposeCalls, 0);
    });
  });

  group('R0-01 (ESP-19): Visualizador real de páginas PDF (multi-página, Android PdfRenderer, Web blob URL + revogação, fallback funcional, PDF inválido e limpeza)', () {
    testWidgets(
      'Renderiza documento PDF multi-página real, navega entre páginas 1..3, aplica zoom, abre leitor expandido e fecha automaticamente ao trocar documento ou fazer logout',
      (tester) async {
        UserProfile? currentUser = _studentA;
        final backend = _InMemoryLot4Backend(
          activeUserProvider: () => currentUser,
        );

        final doc1Bytes = _multiPagePdfBytes(<String>[
          'TCE Pagina 1 - Identificacao do Estagiario A',
          'TCE Pagina 2 - Plano de Atividades Semestral',
          'TCE Pagina 3 - Assinaturas e Carimbo da Concedente',
        ]);
        final doc2Bytes = _multiPagePdfBytes(<String>[
          'Plano Opcional Pagina Unica - Conteudo Distinto Doc 2',
        ]);

        await backend.submitRequirementPdf(
          processRequirementId: 'req-a-1',
          file: SelectedPdfFile(name: 'tce_3_paginas.pdf', bytes: doc1Bytes),
          idempotencyKey: 'idem-r001-doc1',
        );
        final sub2 = await backend.submitRequirementPdf(
          processRequirementId: 'req-a-2',
          file: SelectedPdfFile(name: 'anexo_1_pagina.pdf', bytes: doc2Bytes),
          idempotencyKey: 'idem-r001-doc2',
        );

        currentUser = _assignedReviewerR1;
        final authGateway = _ReviewTestAuthGateway(
          currentProfile: _assignedReviewerR1,
        );
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 960));
        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: backend,
            documentRepository: backend,
            reviewRepository: backend,
          ),
        );
        await tester.pumpAndSettle();

        // 1) Clicar em Visualizar PDF autenticado renderiza a Página 1 de 3 com bitmap real
        final loadPdfBtn = find.byKey(const Key('reviewer_load_pdf_button'));
        await tester.ensureVisible(loadPdfBtn);
        await tester.tap(loadPdfBtn);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('reviewer_pdf_viewer_card')),
          findsOneWidget,
        );
        expect(find.text('Página 1 de 3'), findsOneWidget);
        expect(
          find.byKey(const Key('pdf_viewer_page_canvas_p1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('pdf_viewer_raster_image_p1')),
          findsOneWidget,
        );
        final imgP1 = tester.widget<Image>(
          find.byKey(const Key('pdf_viewer_raster_image_p1')),
        );
        expect((imgP1.image as MemoryImage).bytes, _distinctPagePngBytes(1));

        // 2) Navegar para a Página 2 de 3
        final nextPageBtn = find.byKey(
          const Key('pdf_viewer_next_page_button'),
        );
        await tester.ensureVisible(nextPageBtn);
        await tester.tap(nextPageBtn);
        await tester.pumpAndSettle();

        expect(find.text('Página 2 de 3'), findsOneWidget);
        expect(
          find.byKey(const Key('pdf_viewer_page_canvas_p2')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('pdf_viewer_raster_image_p2')),
          findsOneWidget,
        );
        final imgP2 = tester.widget<Image>(
          find.byKey(const Key('pdf_viewer_raster_image_p2')),
        );
        expect((imgP2.image as MemoryImage).bytes, _distinctPagePngBytes(2));

        // 3) Selecionar diretamente a Página 3 via chip
        final page3Chip = find.byKey(const Key('pdf_viewer_page_chip_3'));
        await tester.ensureVisible(page3Chip);
        await tester.tap(page3Chip);
        await tester.pumpAndSettle();

        expect(find.text('Página 3 de 3'), findsOneWidget);
        expect(
          find.byKey(const Key('pdf_viewer_page_canvas_p3')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('pdf_viewer_raster_image_p3')),
          findsOneWidget,
        );
        final imgP3 = tester.widget<Image>(
          find.byKey(const Key('pdf_viewer_raster_image_p3')),
        );
        expect((imgP3.image as MemoryImage).bytes, _distinctPagePngBytes(3));

        // 4) Voltar para a Página 2 e testar controles de zoom
        final prevPageBtn = find.byKey(
          const Key('pdf_viewer_prev_page_button'),
        );
        await tester.ensureVisible(prevPageBtn);
        await tester.tap(prevPageBtn);
        await tester.pumpAndSettle();
        expect(find.text('Página 2 de 3'), findsOneWidget);

        final zoomInBtn = find.byKey(const Key('pdf_viewer_zoom_in_button'));
        await tester.ensureVisible(zoomInBtn);
        await tester.tap(zoomInBtn);
        await tester.pumpAndSettle();
        expect(find.text('125%'), findsOneWidget);

        final zoomResetBtn = find.byKey(
          const Key('pdf_viewer_zoom_reset_button'),
        );
        await tester.ensureVisible(zoomResetBtn);
        await tester.tap(zoomResetBtn);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const Key('pdf_viewer_zoom_label')))
              .data,
          '100%',
        );

        // 5) Fallback funcional: abrir leitor expandido em tela cheia e verificar página real
        final openFallbackBtn = find.byKey(
          const Key('reviewer_open_external_pdf_button'),
        );
        await tester.ensureVisible(openFallbackBtn);
        await tester.tap(openFallbackBtn);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('pdf_fullscreen_viewer_dialog')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('pdf_document_viewer_fullscreen')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('close_fullscreen_pdf_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('pdf_fullscreen_viewer_dialog')),
          findsNothing,
        );

        // 6) Trocar para o 2º documento na fila limpa imediatamente o documento anterior e renderiza o novo
        final selectDoc2 = find.byKey(
          Key('select_queue_submission_${sub2.submission.id}'),
        );
        await tester.ensureVisible(selectDoc2);
        await tester.tap(selectDoc2);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('reviewer_pdf_viewer_card')), findsNothing);
        expect(
          find.byKey(const Key('pdf_viewer_raster_image_p2')),
          findsNothing,
        );

        await tester.ensureVisible(loadPdfBtn);
        await tester.tap(loadPdfBtn);
        await tester.pumpAndSettle();

        expect(find.text('Página 1 de 1'), findsOneWidget);
        expect(
          find.byKey(const Key('pdf_viewer_raster_image_p1')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Android PdfRenderer MethodChannel renderiza bitmaps PNG reais por página (Image.memory), limpa cache temporário e rejeita PDF corrompido',
      (tester) async {
        const channel = MethodChannel('estagio_sem_pendencia/pdf_renderer');
        var renderChannelCalls = 0;
        var clearChannelCalls = 0;
        var shouldFailNativeRender = false;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'renderPdfDocument') {
                renderChannelCalls++;
                if (shouldFailNativeRender) {
                  throw PlatformException(
                    code: 'CORRUPTED_PDF',
                    message: 'Não foi possível renderizar as páginas do documento PDF.',
                  );
                }
                return <String, dynamic>{
                  'pageCount': 2,
                  'pages': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'pageNumber': 1,
                      'widthPt': 595,
                      'heightPt': 842,
                      'bitmapWidth': 595,
                      'bitmapHeight': 842,
                      'pngBytes': _distinctPagePngBytes(1),
                    },
                    <String, dynamic>{
                      'pageNumber': 2,
                      'widthPt': 595,
                      'heightPt': 842,
                      'bitmapWidth': 595,
                      'bitmapHeight': 842,
                      'pngBytes': _distinctPagePngBytes(2),
                    },
                  ],
                };
              }
              if (call.method == 'clearTemporaryPdfs') {
                clearChannelCalls++;
                return true;
              }
              return null;
            });

        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          await tester.binding.setSurfaceSize(null);
        });

        UserProfile? currentUser = _studentA;
        final backend = _InMemoryLot4Backend(
          activeUserProvider: () => currentUser,
        );
        await backend.submitRequirementPdf(
          processRequirementId: 'req-a-1',
          file: SelectedPdfFile(
            name: 'tce_android_raster.pdf',
            bytes: _multiPagePdfBytes(<String>[
              'Pagina 1 Android',
              'Pagina 2 Android',
            ]),
          ),
          idempotencyKey: 'idem-android-1',
        );

        currentUser = _assignedReviewerR1;
        final authGateway = _ReviewTestAuthGateway(
          currentProfile: _assignedReviewerR1,
        );
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 960));
        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: backend,
            documentRepository: backend,
            reviewRepository: backend,
            pdfRendererGateway: PlatformPdfRendererGateway(
              channel: channel,
              useAndroidNativeChannel: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final loadPdfBtn = find.byKey(const Key('reviewer_load_pdf_button'));
        await tester.ensureVisible(loadPdfBtn);
        await tester.tap(loadPdfBtn);
        await tester.pumpAndSettle();

        expect(renderChannelCalls, 1);
        expect(find.text('Página 1 de 2'), findsOneWidget);
        expect(
          find.byKey(const Key('pdf_viewer_raster_image_p1')),
          findsOneWidget,
        );

        // Avançar para página 2 rasterizada
        await tester.tap(find.byKey(const Key('pdf_viewer_next_page_button')));
        await tester.pumpAndSettle();
        expect(find.text('Página 2 de 2'), findsOneWidget);
        expect(
          find.byKey(const Key('pdf_viewer_raster_image_p2')),
          findsOneWidget,
        );

        // Descartar PDF limpa memória e chama clearTemporaryPdfs no canal Android
        final clearBtn = find.byKey(const Key('reviewer_clear_pdf_button'));
        await tester.ensureVisible(clearBtn);
        await tester.tap(clearBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('reviewer_pdf_viewer_card')), findsNothing);
        expect(clearChannelCalls, greaterThanOrEqualTo(1));

        // Simular falha de renderização nativa em PDF corrompido
        shouldFailNativeRender = true;
        await tester.ensureVisible(loadPdfBtn);
        await tester.tap(loadPdfBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('reviewer_pdf_viewer_card')), findsNothing);
        expect(
          find.byKey(const Key('reviewer_pdf_error_banner')),
          findsOneWidget,
        );
        expect(
          find.textContaining('Não foi possível renderizar as páginas'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    test('Web PdfWebBridge cria blob URL temporária por versão, não inventa contagem de páginas via regex, abre fallback em nova aba e revoga URL em troca de documento, logout e dispose', () async {
      UserProfile? currentUser = _studentA;
      final backend = _InMemoryLot4Backend(
        activeUserProvider: () => currentUser,
      );
      final sub1 = await backend.submitRequirementPdf(
        processRequirementId: 'req-a-1',
        file: SelectedPdfFile(
          name: 'web_doc1.pdf',
          bytes: _multiPagePdfBytes(<String>['Web P1', 'Web P2']),
        ),
        idempotencyKey: 'idem-web-1',
      );
      final sub2 = await backend.submitRequirementPdf(
        processRequirementId: 'req-a-2',
        file: SelectedPdfFile(
          name: 'web_doc2.pdf',
          bytes: _multiPagePdfBytes(<String>['Web Doc2 P1']),
        ),
        idempotencyKey: 'idem-web-2',
      );

      currentUser = _assignedReviewerR1;
      final spyWebBridge = _SpyPdfWebBridge();
      final renderer = PlatformPdfRendererGateway(webBridge: spyWebBridge);
      final controller = ReviewerController(
        repository: backend,
        pickerGateway: _FakePdfPicker(),
        pdfRendererGateway: renderer,
      );

      await controller.loadQueue();
      expect(controller.selectedItem?.submissionId, sub1.submission.id);

      final ok1 = await controller.loadAuthenticatedPdfForSelected();
      expect(ok1, isTrue);
      expect(spyWebBridge.createdHandles.length, 1);
      expect(controller.loadedPdf?.renderedDocument?.isWebBrowserMode, isTrue);
      expect(
        controller.loadedPdf?.renderedDocument?.hasValidatedPageCount,
        isFalse,
      );
      expect(controller.loadedPdf?.renderedDocument?.pageCount, 0);

      final handle1 = spyWebBridge.createdHandles.first;
      expect(handle1.isRevoked, isFalse);
      expect(handle1.submissionId, sub1.submission.id);
      expect(handle1.submissionVersion, 1);
      expect(handle1.currentPage, 1);

      // Solicitar salto de página na sessão Web atualiza fragmento #page=N do viewer nativo
      controller.goToPdfPage(2);
      expect(controller.currentPdfPage, 2);
      expect(handle1.currentPage, 2);

      // Fallback de abertura em nova aba do navegador
      final openedTab = controller.openPdfInBrowserOrFallback();
      expect(openedTab, isTrue);
      expect(handle1.openTabCalls, 1);

      // Trocar para o 2º documento revoga imediatamente a blob URL do 1º documento
      final secondQueueItem = controller.queueItems.firstWhere(
        (i) => i.submissionId == sub2.submission.id,
      );
      controller.selectQueueItem(secondQueueItem);
      expect(handle1.isRevoked, isTrue);
      expect(spyWebBridge.revokedUrls, contains(handle1.objectUrl));

      // Carregar 2º documento cria nova blob URL
      final ok2 = await controller.loadAuthenticatedPdfForSelected();
      expect(ok2, isTrue);
      final handle2 = spyWebBridge.createdHandles.last;
      expect(handle2.isRevoked, isFalse);
      expect(handle2.submissionId, sub2.submission.id);

      // Logout (clearPrivateState) e dispose revogam a 2ª blob URL e limpam tudo
      controller.clearPrivateState();
      expect(handle2.isRevoked, isTrue);
      expect(spyWebBridge.revokedUrls, contains(handle2.objectUrl));
      controller.dispose();
    });

    test('Rejeita PDF truncado/corrompido ou sem páginas via renderizador e descarta resposta assíncrona tardia após troca de documento ou logout', () async {
      final gateway = PlatformPdfRendererGateway(useAndroidNativeChannel: true);

      // 1) PDF truncado sem %%EOF
      final truncatedBytes = Uint8List.fromList(
        '%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n'.codeUnits,
      );
      await expectLater(
        () => gateway.renderDocument(
          submissionId: 'sub-trunc',
          submissionVersion: 1,
          documentTitle: 'Truncado',
          bytes: truncatedBytes,
        ),
        throwsA(
          isA<ReviewFailure>().having((e) => e.code, 'code', 'corrupted_pdf'),
        ),
      );

      // 2) PDF estruturalmente sem páginas (/Type /Pages /Kids [] /Count 0)
      final zeroPagesBytes = Uint8List.fromList(
        '%PDF-1.4\n1 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n%%EOF\n'
            .codeUnits,
      );
      await expectLater(
        () => gateway.renderDocument(
          submissionId: 'sub-zero',
          submissionVersion: 1,
          documentTitle: 'Sem Páginas',
          bytes: zeroPagesBytes,
        ),
        throwsA(
          isA<ReviewFailure>().having((e) => e.code, 'code', 'empty_pdf_pages'),
        ),
      );

      // 3) Resposta assíncrona tardia de download após troca de documento não exibe documento antigo
      UserProfile? currentUser = _studentA;
      final backend = _InMemoryLot4Backend(
        activeUserProvider: () => currentUser,
      );
      final sub1 = await backend.submitRequirementPdf(
        processRequirementId: 'req-a-1',
        file: SelectedPdfFile(
          name: 'doc_lento_1.pdf',
          bytes: _multiPagePdfBytes(<String>['Conteudo Antigo Doc 1']),
        ),
        idempotencyKey: 'idem-late-1',
      );
      final sub2 = await backend.submitRequirementPdf(
        processRequirementId: 'req-a-2',
        file: SelectedPdfFile(
          name: 'doc_rapido_2.pdf',
          bytes: _multiPagePdfBytes(<String>['Conteudo Novo Doc 2']),
        ),
        idempotencyKey: 'idem-late-2',
      );

      currentUser = _assignedReviewerR1;
      final spyWebBridge = _SpyPdfWebBridge();
      final controller = ReviewerController(
        repository: backend,
        pickerGateway: _FakePdfPicker(),
        pdfRendererGateway: PlatformPdfRendererGateway(webBridge: spyWebBridge),
      );
      addTearDown(controller.dispose);

      await controller.loadQueue();
      expect(controller.selectedItem?.submissionId, sub1.submission.id);

      final slowDownload1 = Completer<Uint8List>();
      backend.pendingDownload = slowDownload1;
      final load1Future = controller.loadAuthenticatedPdfForSelected();
      expect(controller.isLoadingPdf, isTrue);

      // Revisor troca para sub2 antes do download de sub1 concluir
      final item2 = controller.queueItems.firstWhere(
        (i) => i.submissionId == sub2.submission.id,
      );
      controller.selectQueueItem(item2);
      expect(controller.isLoadingPdf, isFalse);

      // Download de sub1 termina tardiamente: deve ser descartado e zerado sem abrir no visualizador
      final lateBuffer1 = _multiPagePdfBytes(<String>['Conteudo Antigo Doc 1']);
      slowDownload1.complete(lateBuffer1);
      final load1Result = await load1Future;
      expect(load1Result, isFalse);
      expect(controller.loadedPdf, isNull);
      expect(lateBuffer1.every((b) => b == 0), isTrue);
    });
  });

  group('GATE B4-FE-02 (C4-FE-01, C4-FE-02, C4-FE-03): Testes de Regressão Obrigatórios (Fase D — Casos 1 a 7)', () {
    test('CASO 1 — PDF estruturalmente válido de 1 página (xref com offsets exatos) é aceito e renderizado no Android e na Web', () async {
      final valid1PagePdf = _buildRealXrefPdfBytes(
        pages: const <_PdfPageSpec>[
          _PdfPageSpec(
            text: 'Termo de Compromisso de Estagio - Pagina Unica Valida',
          ),
        ],
      );

      // Verifica que o PDF gerado possui tabela xref real e startxref
      final asciiText = ascii.decode(valid1PagePdf, allowInvalid: true);
      expect(asciiText, contains('\nxref\n0 6\n0000000000 65535 f \n'));
      expect(asciiText, contains('\nstartxref\n'));

      // 1A) Android MethodChannel
      final androidGateway = PlatformPdfRendererGateway(
        useAndroidNativeChannel: true,
      );
      final androidDoc = await androidGateway.renderDocument(
        submissionId: 'sub-caso1-android',
        submissionVersion: 1,
        documentTitle: 'TCE Válido 1 Página',
        bytes: valid1PagePdf,
      );
      expect(androidDoc.isViewable, isTrue);
      expect(androidDoc.hasValidatedPageCount, isTrue);
      expect(androidDoc.pageCount, 1);
      expect(androidDoc.pages.single.hasRasterImage, isTrue);
      expect(androidDoc.pages.single.rasterPngBytes, _distinctPagePngBytes(1));

      // 1B) Web PdfWebBridge
      final spyWebBridge = _SpyPdfWebBridge();
      final webGateway = PlatformPdfRendererGateway(webBridge: spyWebBridge);
      final webDoc = await webGateway.renderDocument(
        submissionId: 'sub-caso1-web',
        submissionVersion: 1,
        documentTitle: 'TCE Válido 1 Página Web',
        bytes: valid1PagePdf,
      );
      expect(webDoc.isViewable, isTrue);
      expect(webDoc.isWebBrowserMode, isTrue);
      expect(webDoc.hasValidatedPageCount, isFalse);
      expect(spyWebBridge.createdHandles.length, 1);
      expect(spyWebBridge.createdHandles.single.isRevoked, isFalse);
    });

    testWidgets(
      'CASO 2 (Regressão exata C4-FE-01) — PDF válido de 1 página contendo o texto literal "Documento ficticio com texto literal /Count 0" chega ao MethodChannel Android e ao PdfWebBridge sem falso positivo empty_pdf_pages',
      (tester) async {
        final controlPdf = _buildRealXrefPdfBytes(
          pages: const <_PdfPageSpec>[
            _PdfPageSpec(
              text: 'Documento de controle de uma pagina sem token especial',
            ),
          ],
        );
        final countZeroLiteralPdf = _buildRealXrefPdfBytes(
          pages: const <_PdfPageSpec>[
            _PdfPageSpec(text: 'Documento ficticio com texto literal /Count 0'),
          ],
        );

        const channel = MethodChannel('estagio_sem_pendencia/pdf_renderer');
        final receivedChannelBuffers = <Uint8List>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'renderPdfDocument') {
                final args = call.arguments as Map<dynamic, dynamic>;
                final bytes = args['bytes'] as Uint8List;
                receivedChannelBuffers.add(Uint8List.fromList(bytes));
                return <String, dynamic>{
                  'pageCount': 1,
                  'pages': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'pageNumber': 1,
                      'widthPt': 595,
                      'heightPt': 842,
                      'bitmapWidth': 595,
                      'bitmapHeight': 842,
                      'pngBytes': _distinctPagePngBytes(1),
                    },
                  ],
                };
              }
              if (call.method == 'clearTemporaryPdfs') {
                return true;
              }
              return null;
            });

        final androidGateway = PlatformPdfRendererGateway(
          channel: channel,
          useAndroidNativeChannel: true,
        );

        // 1) Ambos os documentos chegam ao MethodChannel Android sem rejeição prévia
        final renderedControl = await androidGateway.renderDocument(
          submissionId: 'sub-c4fe01-control',
          submissionVersion: 1,
          documentTitle: 'Controle C4-FE-01',
          bytes: controlPdf,
        );
        final renderedCountZeroLiteral = await androidGateway.renderDocument(
          submissionId: 'sub-c4fe01-literal-count0',
          submissionVersion: 1,
          documentTitle: 'Literal /Count 0 C4-FE-01',
          bytes: countZeroLiteralPdf,
        );

        expect(receivedChannelBuffers.length, 2);
        expect(renderedControl.pageCount, 1);
        expect(renderedCountZeroLiteral.pageCount, 1);
        expect(renderedCountZeroLiteral.isViewable, isTrue);

        // 2) Ambos chegam igualmente ao PdfWebBridge na Web
        final spyWebBridge = _SpyPdfWebBridge();
        final webGateway = PlatformPdfRendererGateway(webBridge: spyWebBridge);
        final webDocLiteral = await webGateway.renderDocument(
          submissionId: 'sub-c4fe01-web-literal',
          submissionVersion: 1,
          documentTitle: 'Literal /Count 0 Web C4-FE-01',
          bytes: countZeroLiteralPdf,
        );
        expect(webDocLiteral.isViewable, isTrue);
        expect(spyWebBridge.createdHandles.length, 1);

        // 3) Montagem do widget PdfDocumentViewer com o documento "/Count 0"
        var currentPage = 1;
        var zoom = 1.0;
        final payloadCountZero = VerifiedPdfPayload(
          submissionId: renderedCountZeroLiteral.submissionId,
          submissionVersion: renderedCountZeroLiteral.submissionVersion,
          processId: 'proc-c4fe01',
          processRequirementId: 'req-c4fe01',
          requirementCode: 'TCE_OBRIG_01',
          requirementTitle: 'Termo de Compromisso com /Count 0 literal',
          studentName: 'Estudante A Fictício',
          originalFilename: 'tce_literal_count0_v1.pdf',
          storageBucket: kPrivateDocumentsBucket,
          storagePath: 'students/student-a/processes/proc-c4fe01/v1.pdf',
          bytes: countZeroLiteralPdf,
          loadedAt: DateTime(2026, 11, 23, 12, 0),
          renderedDocument: renderedCountZeroLiteral,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PdfDocumentViewer(
                payload: payloadCountZero,
                currentPage: currentPage,
                zoomScale: zoom,
                onPreviousPage: null,
                onNextPage: null,
                onSelectPage: (p) => currentPage = p,
                onZoomIn: () => zoom += 0.25,
                onZoomOut: () => zoom -= 0.25,
                onResetZoom: () => zoom = 1.0,
                onOpenFallbackViewer: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Página 1 de 1'), findsOneWidget);
        expect(
          find.byKey(const Key('pdf_viewer_raster_image_p1')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'CASO 3 — PDF estruturalmente válido de 3 páginas distintas (xref exato) preserva ordem e bitmaps distintos por página',
      (tester) async {
        final valid3PagePdf = _buildRealXrefPdfBytes(
          pages: const <_PdfPageSpec>[
            _PdfPageSpec(text: 'Folha 1 - Identificacao Academica'),
            _PdfPageSpec(text: 'Folha 2 - Cronograma de Atividades'),
            _PdfPageSpec(text: 'Folha 3 - Assinaturas Finais'),
          ],
        );

        final gateway = PlatformPdfRendererGateway(
          useAndroidNativeChannel: true,
        );
        final doc = await gateway.renderDocument(
          submissionId: 'sub-caso3-3pages',
          submissionVersion: 2,
          documentTitle: 'TCE 3 Páginas',
          bytes: valid3PagePdf,
        );

        expect(doc.pageCount, 3);
        expect(doc.pages[0].rasterPngBytes, _distinctPagePngBytes(1));
        expect(doc.pages[1].rasterPngBytes, _distinctPagePngBytes(2));
        expect(doc.pages[2].rasterPngBytes, _distinctPagePngBytes(3));
        expect(
          doc.pages[0].rasterPngBytes,
          isNot(equals(doc.pages[1].rasterPngBytes)),
        );
        expect(
          doc.pages[1].rasterPngBytes,
          isNot(equals(doc.pages[2].rasterPngBytes)),
        );

        final payload3Pages = VerifiedPdfPayload(
          submissionId: doc.submissionId,
          submissionVersion: doc.submissionVersion,
          processId: 'proc-caso3',
          processRequirementId: 'req-caso3',
          requirementCode: 'TCE_OBRIG_01',
          requirementTitle: 'TCE 3 Páginas Distintas',
          studentName: 'Estudante A Fictício',
          originalFilename: 'tce_3_paginas_v2.pdf',
          storageBucket: kPrivateDocumentsBucket,
          storagePath: 'students/student-a/processes/proc-caso3/v2.pdf',
          bytes: valid3PagePdf,
          loadedAt: DateTime(2026, 11, 23, 12, 5),
          renderedDocument: doc,
        );

        var activePage = 1;
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) {
              return MaterialApp(
                home: Scaffold(
                  body: PdfDocumentViewer(
                    payload: payload3Pages,
                    currentPage: activePage,
                    zoomScale: 1.0,
                    onPreviousPage: activePage > 1
                        ? () => setState(() => activePage--)
                        : null,
                    onNextPage: activePage < doc.pageCount
                        ? () => setState(() => activePage++)
                        : null,
                    onSelectPage: (p) => setState(() => activePage = p),
                    onZoomIn: () {},
                    onZoomOut: () {},
                    onResetZoom: () {},
                    onOpenFallbackViewer: () {},
                  ),
                ),
              );
            },
          ),
        );
        await tester.pumpAndSettle();

        for (var p = 1; p <= 3; p++) {
          if (p > 1) {
            await tester.tap(find.byKey(Key('pdf_viewer_page_chip_$p')));
            await tester.pumpAndSettle();
          }
          expect(find.text('Página $p de 3'), findsOneWidget);
          final imgFinder = find.byKey(Key('pdf_viewer_raster_image_p$p'));
          expect(imgFinder, findsOneWidget);
          final imgWidget = tester.widget<Image>(imgFinder);
          expect(
            (imgWidget.image as MemoryImage).bytes,
            _distinctPagePngBytes(p),
          );
        }
      },
    );

    test('CASO 4 — PDF com stream comprimido (/Filter /FlateDecode) e PDF digitalizado somente imagem (/Subtype /Image sem texto extraível Tj/TJ) nunca são rejeitados', () async {
      // 4A) Stream comprimido com zlib/FlateDecode (sem Tj/TJ legível em texto plano)
      final flateCompressedPdf = _buildRealXrefPdfBytes(
        pages: const <_PdfPageSpec>[
          _PdfPageSpec(
            text:
                'Conteudo comprimido com FlateDecode e token /Count 0 interno',
            flateCompress: true,
          ),
        ],
      );

      // 4B) Documento digitalizado apenas com XObject de imagem (/Subtype /Image), zero operadores BT/ET/Tj/TJ
      final scannedImageOnlyPdf = _buildRealXrefPdfBytes(
        pages: const <_PdfPageSpec>[
          _PdfPageSpec(text: '', scannedImageOnly: true),
        ],
      );
      final scannedAscii = ascii.decode(
        scannedImageOnlyPdf,
        allowInvalid: true,
      );
      expect(scannedAscii, isNot(contains(' Tj')));
      expect(scannedAscii, isNot(contains(' TJ')));
      expect(scannedAscii, contains('/Subtype /Image'));

      final androidGateway = PlatformPdfRendererGateway(
        useAndroidNativeChannel: true,
      );
      final spyWebBridge = _SpyPdfWebBridge();
      final webGateway = PlatformPdfRendererGateway(webBridge: spyWebBridge);

      final androidFlate = await androidGateway.renderDocument(
        submissionId: 'sub-caso4-flate',
        submissionVersion: 1,
        documentTitle: 'FlateDecode PDF',
        bytes: flateCompressedPdf,
      );
      expect(androidFlate.isViewable, isTrue);
      expect(androidFlate.pageCount, 1);

      final androidScanned = await androidGateway.renderDocument(
        submissionId: 'sub-caso4-scanned',
        submissionVersion: 1,
        documentTitle: 'Scanned Image PDF',
        bytes: scannedImageOnlyPdf,
      );
      expect(androidScanned.isViewable, isTrue);
      expect(androidScanned.pageCount, 1);

      final webFlate = await webGateway.renderDocument(
        submissionId: 'sub-caso4-web-flate',
        submissionVersion: 1,
        documentTitle: 'FlateDecode Web PDF',
        bytes: flateCompressedPdf,
      );
      final webScanned = await webGateway.renderDocument(
        submissionId: 'sub-caso4-web-scanned',
        submissionVersion: 1,
        documentTitle: 'Scanned Web PDF',
        bytes: scannedImageOnlyPdf,
      );
      expect(webFlate.isViewable, isTrue);
      expect(webScanned.isViewable, isTrue);
      expect(spyWebBridge.createdHandles.length, 2);
    });

    testWidgets(
      'CASO 5 — PDF corrompido ou truncado apresenta erro amigável do renderizador na interface sem abrir visualizador nem vazar stack trace',
      (tester) async {
        UserProfile? currentUser = _studentA;
        final backend = _InMemoryLot4Backend(
          activeUserProvider: () => currentUser,
        );

        final validInitial = _buildRealXrefPdfBytes(
          pages: const <_PdfPageSpec>[_PdfPageSpec(text: 'Upload inicial')],
        );
        final sub = await backend.submitRequirementPdf(
          processRequirementId: 'req-a-1',
          file: SelectedPdfFile(
            name: 'corrompido_em_storage.pdf',
            bytes: validInitial,
          ),
          idempotencyKey: 'idem-caso5-corrupt',
        );

        // Simular que os bytes baixados do storage estão truncados/corrompidos
        backend.storageObjects[sub.submission.storagePath] = Uint8List.fromList(
          '%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Broken '.codeUnits,
        );

        currentUser = _assignedReviewerR1;
        final authGateway = _ReviewTestAuthGateway(
          currentProfile: _assignedReviewerR1,
        );
        final authController = AuthController(gateway: authGateway);
        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 960));
        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: backend,
            documentRepository: backend,
            reviewRepository: backend,
          ),
        );
        await tester.pumpAndSettle();

        final loadPdfBtn = find.byKey(const Key('reviewer_load_pdf_button'));
        await tester.ensureVisible(loadPdfBtn);
        await tester.tap(loadPdfBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('reviewer_pdf_viewer_card')), findsNothing);
        expect(
          find.byKey(const Key('reviewer_pdf_error_banner')),
          findsOneWidget,
        );
        expect(
          find.textContaining('Não foi possível renderizar as páginas'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    test('CASO 6 — Troca de documento, logout e conclusão assíncrona tardia de renderização zeram buffers em memória, revogam recursos e nunca exibem documento antigo', () async {
      UserProfile? currentUser = _studentA;
      final backend = _InMemoryLot4Backend(
        activeUserProvider: () => currentUser,
      );
      final sub1 = await backend.submitRequirementPdf(
        processRequirementId: 'req-a-1',
        file: SelectedPdfFile(
          name: 'doc_antigo_v1.pdf',
          bytes: _buildRealXrefPdfBytes(
            pages: const <_PdfPageSpec>[
              _PdfPageSpec(text: 'Documento Antigo Sub 1'),
            ],
          ),
        ),
        idempotencyKey: 'idem-caso6-sub1',
      );
      final sub2 = await backend.submitRequirementPdf(
        processRequirementId: 'req-a-2',
        file: SelectedPdfFile(
          name: 'doc_novo_v1.pdf',
          bytes: _buildRealXrefPdfBytes(
            pages: const <_PdfPageSpec>[
              _PdfPageSpec(text: 'Documento Novo Sub 2'),
            ],
          ),
        ),
        idempotencyKey: 'idem-caso6-sub2',
      );

      const channel = MethodChannel('estagio_sem_pendencia/pdf_renderer');
      final pendingNativeRender = Completer<Map<String, dynamic>>();
      var interceptNextRender = false;
      var clearTempCalls = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'renderPdfDocument') {
              if (interceptNextRender) {
                interceptNextRender = false;
                return pendingNativeRender.future;
              }
              return <String, dynamic>{
                'pageCount': 1,
                'pages': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'pageNumber': 1,
                    'widthPt': 595,
                    'heightPt': 842,
                    'bitmapWidth': 595,
                    'bitmapHeight': 842,
                    'pngBytes': _distinctPagePngBytes(1),
                  },
                ],
              };
            }
            if (call.method == 'clearTemporaryPdfs') {
              clearTempCalls++;
              return true;
            }
            return null;
          });

      currentUser = _assignedReviewerR1;
      final controller = ReviewerController(
        repository: backend,
        pickerGateway: _FakePdfPicker(),
        pdfRendererGateway: PlatformPdfRendererGateway(
          channel: channel,
          useAndroidNativeChannel: true,
        ),
      );
      addTearDown(controller.dispose);

      await controller.loadQueue();
      expect(controller.selectedItem?.submissionId, sub1.submission.id);

      // 1) Carregar sub1 normalmente e confirmar que bytes e bitmap estão ativos
      final ok1 = await controller.loadAuthenticatedPdfForSelected();
      expect(ok1, isTrue);
      final loadedSub1 = controller.loadedPdf!;
      final renderedSub1 = loadedSub1.renderedDocument!;
      final rasterSub1 = renderedSub1.pages.single.rasterPngBytes!;
      expect(loadedSub1.bytes.any((b) => b != 0), isTrue);
      expect(rasterSub1.any((b) => b != 0), isTrue);

      // 2) Trocar para sub2 zera imediatamente os bytes do PDF e o bitmap PNG de sub1
      final item2 = controller.queueItems.firstWhere(
        (i) => i.submissionId == sub2.submission.id,
      );
      controller.selectQueueItem(item2);
      expect(controller.loadedPdf, isNull);
      expect(loadedSub1.bytes.every((b) => b == 0), isTrue);
      expect(rasterSub1.every((b) => b == 0), isTrue);
      expect(renderedSub1.isWiped, isTrue);
      expect(renderedSub1.pages.single.isWiped, isTrue);

      // 3) Iniciar renderização assíncrona lenta de sub2 e fazer logout (clearPrivateState) antes de concluir
      interceptNextRender = true;
      final slowRenderFuture = controller.loadAuthenticatedPdfForSelected();
      await Future<void>.delayed(Duration.zero);

      final clearCallsBeforeLateFinish = clearTempCalls;
      controller.clearPrivateState();
      expect(controller.loadedPdf, isNull);

      pendingNativeRender.complete(<String, dynamic>{
        'pageCount': 1,
        'pages': <Map<String, dynamic>>[
          <String, dynamic>{
            'pageNumber': 1,
            'widthPt': 595,
            'heightPt': 842,
            'bitmapWidth': 595,
            'bitmapHeight': 842,
            'pngBytes': _distinctPagePngBytes(2),
          },
        ],
      });

      final slowResult = await slowRenderFuture;
      expect(slowResult, isFalse);
      expect(controller.loadedPdf, isNull);
      expect(clearTempCalls, greaterThan(clearCallsBeforeLateFinish));
    });

    test('CASO 7 (Regressão C4-FE-03) — Páginas PDF com dimensões superiores a maxDimension (ex.: 2400x3600 e 3200x1600) são reduzidas proporcionalmente para <= 1280px sem upscale em páginas menores', () async {
      // 1) Verificação algorítmica direta da fórmula scale = min(1.0, maxDimension / maiorDimensao)
      final portraitOversized =
          PdfBitmapScaleCalculator.computeTargetDimensions(
            widthPt: 2400,
            heightPt: 3600,
            maxDimension: 1280,
          );
      expect(portraitOversized.width, 853);
      expect(portraitOversized.height, 1280);
      expect(
        portraitOversized.width,
        lessThanOrEqualTo(kDefaultMaxPdfBitmapDimension),
      );
      expect(
        portraitOversized.height,
        lessThanOrEqualTo(kDefaultMaxPdfBitmapDimension),
      );

      final landscapeOversized =
          PdfBitmapScaleCalculator.computeTargetDimensions(
            widthPt: 3200,
            heightPt: 1600,
            maxDimension: 1280,
          );
      expect(landscapeOversized.width, 1280);
      expect(landscapeOversized.height, 640);

      // Página A4 padrão (595 x 842) < 1280 NÃO sofre upscale artificial (scale = 1.0)
      final standardA4 = PdfBitmapScaleCalculator.computeTargetDimensions(
        widthPt: 595,
        heightPt: 842,
        maxDimension: 1280,
      );
      expect(standardA4.width, 595);
      expect(standardA4.height, 842);

      // 2) Verificação fim-a-fim pelo PlatformPdfRendererGateway com PDF de 3 páginas (2400x3600, 3200x1600, 595x842)
      final multiSizePdf = _buildRealXrefPdfBytes(
        pages: const <_PdfPageSpec>[
          _PdfPageSpec(
            text: 'Poster Vertical Gigante 2400x3600',
            widthPt: 2400,
            heightPt: 3600,
          ),
          _PdfPageSpec(
            text: 'Planta Horizontal Gigante 3200x1600',
            widthPt: 3200,
            heightPt: 1600,
          ),
          _PdfPageSpec(
            text: 'Folha A4 Padrao 595x842',
            widthPt: 595,
            heightPt: 842,
          ),
        ],
      );

      final gateway = PlatformPdfRendererGateway(useAndroidNativeChannel: true);
      final doc = await gateway.renderDocument(
        submissionId: 'sub-caso7-oversized',
        submissionVersion: 1,
        documentTitle: 'Multi-Size PDF',
        bytes: multiSizePdf,
      );

      expect(doc.pageCount, 3);

      // Página 1: 2400x3600 pt -> bitmap 853x1280 px (<= 1280)
      expect(doc.pages[0].widthPoints, 2400);
      expect(doc.pages[0].heightPoints, 3600);
      expect(doc.pages[0].bitmapWidth, 853);
      expect(doc.pages[0].bitmapHeight, 1280);
      expect(doc.pages[0].bitmapWidth, lessThanOrEqualTo(1280));
      expect(doc.pages[0].bitmapHeight, lessThanOrEqualTo(1280));

      // Página 2: 3200x1600 pt -> bitmap 1280x640 px (<= 1280)
      expect(doc.pages[1].widthPoints, 3200);
      expect(doc.pages[1].heightPoints, 1600);
      expect(doc.pages[1].bitmapWidth, 1280);
      expect(doc.pages[1].bitmapHeight, 640);
      expect(doc.pages[1].bitmapWidth, lessThanOrEqualTo(1280));
      expect(doc.pages[1].bitmapHeight, lessThanOrEqualTo(1280));

      // Página 3: 595x842 pt -> bitmap 595x842 px (sem upscale)
      expect(doc.pages[2].widthPoints, 595);
      expect(doc.pages[2].heightPoints, 842);
      expect(doc.pages[2].bitmapWidth, 595);
      expect(doc.pages[2].bitmapHeight, 842);
    });

    testWidgets(
      'Modo Web (PdfRenderMode.webBrowser) não exibe paginação fictícia nem botões Anterior/Próxima de regex na barra do PdfDocumentViewer',
      (tester) async {
        final validPdf = _buildRealXrefPdfBytes(
          pages: const <_PdfPageSpec>[
            _PdfPageSpec(
              text: 'Documento Web com /Count 0 literal no conteudo',
            ),
          ],
        );
        final spyWebBridge = _SpyPdfWebBridge();
        final webGateway = PlatformPdfRendererGateway(webBridge: spyWebBridge);
        final webDoc = await webGateway.renderDocument(
          submissionId: 'sub-web-no-fake-pagination',
          submissionVersion: 1,
          documentTitle: 'Web Sem Paginação Fictícia',
          bytes: validPdf,
        );

        expect(webDoc.isWebBrowserMode, isTrue);
        expect(webDoc.hasValidatedPageCount, isFalse);

        final payloadWeb = VerifiedPdfPayload(
          submissionId: webDoc.submissionId,
          submissionVersion: webDoc.submissionVersion,
          processId: 'proc-web',
          processRequirementId: 'req-web',
          requirementCode: 'TCE_OBRIG_01',
          requirementTitle: 'Web Sem Paginação Fictícia',
          studentName: 'Estudante A Fictício',
          originalFilename: 'web_doc_v1.pdf',
          storageBucket: kPrivateDocumentsBucket,
          storagePath: 'students/student-a/processes/proc-web/v1.pdf',
          bytes: validPdf,
          loadedAt: DateTime(2026, 11, 23, 12, 10),
          renderedDocument: webDoc,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PdfDocumentViewer(
                payload: payloadWeb,
                currentPage: 1,
                zoomScale: 1.0,
                onPreviousPage: null,
                onNextPage: null,
                onSelectPage: (_) {},
                onZoomIn: () {},
                onZoomOut: () {},
                onResetZoom: () {},
                onOpenFallbackViewer: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('pdf_viewer_web_mode_label')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('pdf_viewer_page_indicator')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('pdf_viewer_prev_page_button')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('pdf_viewer_next_page_button')),
          findsNothing,
        );
        expect(find.byKey(const Key('pdf_viewer_page_chip_1')), findsNothing);
      },
    );

    test('GATE E3-FE-GATEWAY — SupabaseDocumentRepository e SupabaseReviewRepository usam POST autenticado em /functions/v1/download-submission-pdf com submission_id, preservam bytes binários sem UTF-8/JSON decode e nunca acessam Storage direto, public ou sign', () async {
      // PDF binário real com cabeçalho binário (>128: 0xE2, 0xE3, 0xCF, 0xD3) e stream FlateDecode comprimido
      // que lançaria FormatException se o SDK tentasse utf8.decode(bodyBytes).
      final binaryFlatePdfBytes = _buildRealXrefPdfBytes(
        pages: const <_PdfPageSpec>[
          _PdfPageSpec(
            text: 'PDF Binario FlateDecode Gateway Server-Side',
            flateCompress: true,
          ),
        ],
      );
      expect(
        () => utf8.decode(binaryFlatePdfBytes),
        throwsA(isA<FormatException>()),
      );

      final recordedRequests = <_CapturedGatewayHttpRequest>[];
      final recordingHttp = _RecordingGatewayHttpClient(
        handler: (request, bodyBytes) {
          recordedRequests.add(
            _CapturedGatewayHttpRequest(
              method: request.method,
              uri: request.url,
              headers: Map<String, String>.from(request.headers),
              bodyBytes: bodyBytes,
            ),
          );
          return _GatewayMockResponse(
            statusCode: 200,
            bytes: binaryFlatePdfBytes,
            headers: const <String, String>{
              'content-type': 'application/pdf',
              'cache-control': 'private, no-store, no-cache, must-revalidate',
              'x-content-type-options': 'nosniff',
            },
          );
        },
      );

      const cloudUrl = 'https://godjomzqnnyehqkxnemj.supabase.co';
      const publishableKey = 'sb_publishable_clSN89bOeqmdp5tcfZgUJA_hkEq-374';
      const fakeUserJwt =
          'eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhNTAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDEifQ.sig';

      final client = SupabaseClient(
        cloudUrl,
        publishableKey,
        httpClient: recordingHttp,
      );
      client.functions.setAuth(fakeUserJwt);
      addTearDown(() async {
        await client.dispose();
        recordingHttp.close();
      });

      final docRepo = SupabaseDocumentRepository(client);
      final reviewRepo = SupabaseReviewRepository(client);
      const subId1 = 'a1111111-2222-4333-8444-555555555551';
      const subId2 = 'B2222222-3333-4444-8555-666666666662';

      final dl1 = await docRepo.downloadSubmissionBytes(submissionId: subId1);
      final dl2 = await reviewRepo.downloadSubmissionBytes(
        submissionId: subId2,
      );

      expect(dl1, equals(binaryFlatePdfBytes));
      expect(dl2, equals(binaryFlatePdfBytes));
      expect(recordedRequests.length, 2);

      final expectedIds = <String>[subId1, subId2.toLowerCase()];
      for (var i = 0; i < recordedRequests.length; i++) {
        final req = recordedRequests[i];
        expect(req.method, 'POST');
        expect(
          req.uri.toString(),
          '$cloudUrl/functions/v1/download-submission-pdf',
        );
        expect(req.uri.path, '/functions/v1/download-submission-pdf');
        expect(req.uri.path, isNot(contains('/storage/v1/')));
        expect(req.uri.path, isNot(contains('/object/public/')));
        expect(req.uri.path, isNot(contains('/object/sign/')));
        expect(req.uri.queryParameters, isEmpty);

        final lowerHeaders = <String, String>{
          for (final entry in req.headers.entries)
            entry.key.toLowerCase(): entry.value,
        };
        expect(lowerHeaders['apikey'], publishableKey);
        expect(lowerHeaders['authorization'], 'Bearer $fakeUserJwt');
        expect(lowerHeaders['content-type'], 'application/json');
        expect(
          lowerHeaders['cache-control'],
          'no-store, no-cache, must-revalidate',
        );

        final parsedBody =
            jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
        expect(parsedBody.keys.toList(), const <String>['submission_id']);
        expect(parsedBody['submission_id'], expectedIds[i]);
        expect(parsedBody.containsKey('bucket'), isFalse);
        expect(parsedBody.containsKey('storage_bucket'), isFalse);
        expect(parsedBody.containsKey('storage_path'), isFalse);
      }
    });

    test('GATE E3-FE-GATEWAY — Mapeamento de erros 401 (sessão expirada/logout), 403 (perfil inativo/autorização), 404 (sem oracle/revogado), 413 (limite 5 MiB) e rejeição local de submission_id inválido sem fallback ao Storage', () async {
      var nextStatus = 401;
      var nextBody = <String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': 'invalid_or_expired_session',
          'message': 'Sessão ausente, inválida ou expirada.',
        },
      };
      var httpCallCount = 0;

      final recordingHttp = _RecordingGatewayHttpClient(
        handler: (request, bodyBytes) {
          httpCallCount++;
          return _GatewayMockResponse(
            statusCode: nextStatus,
            bytes: Uint8List.fromList(utf8.encode(jsonEncode(nextBody))),
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        },
      );

      final client = SupabaseClient(
        'https://godjomzqnnyehqkxnemj.supabase.co',
        'sb_publishable_clSN89bOeqmdp5tcfZgUJA_hkEq-374',
        httpClient: recordingHttp,
      );
      addTearDown(() async {
        await client.dispose();
        recordingHttp.close();
      });

      final docRepo = SupabaseDocumentRepository(client);
      final reviewRepo = SupabaseReviewRepository(client);
      const validSubId = 'c3333333-4444-4555-8666-777777777773';

      // 1) Validação local rejeita ID vazio, não-UUID, path de Storage ou URL sem efetuar chamada de rede
      for (final badId in const <String>[
        '',
        '   ',
        'nao-e-uuid',
        'processes/proc-1/requirements/req-1/submissions/sub-1.pdf',
        '../secret.pdf',
        'https://godjomzqnnyehqkxnemj.supabase.co/storage/v1/object/public/internship-documents/a.pdf',
      ]) {
        await expectLater(
          () => docRepo.downloadSubmissionBytes(submissionId: badId),
          throwsA(
            isA<DocumentFailure>()
                .having((e) => e.httpStatus, 'httpStatus', 400)
                .having((e) => e.code, 'code', 'invalid_submission_id'),
          ),
        );
        await expectLater(
          () => reviewRepo.downloadSubmissionBytes(submissionId: badId),
          throwsA(
            isA<ReviewFailure>()
                .having((e) => e.httpStatus, 'httpStatus', 400)
                .having((e) => e.code, 'code', 'invalid_submission_id')
                .having(
                  (e) => e.isValidationError,
                  'isValidationError',
                  isTrue,
                ),
          ),
        );
      }
      expect(httpCallCount, 0);

      // 2) HTTP 401 — Sessão expirada ou revogada após logout global
      await expectLater(
        () => docRepo.downloadSubmissionBytes(submissionId: validSubId),
        throwsA(
          isA<DocumentFailure>()
              .having((e) => e.httpStatus, 'httpStatus', 401)
              .having((e) => e.code, 'code', 'invalid_or_expired_session')
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
      await expectLater(
        () => reviewRepo.downloadSubmissionBytes(submissionId: validSubId),
        throwsA(
          isA<ReviewFailure>()
              .having((e) => e.httpStatus, 'httpStatus', 401)
              .having((e) => e.code, 'code', 'invalid_or_expired_session')
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );

      // 3) HTTP 403 — Perfil inativo / acesso proibido
      nextStatus = 403;
      nextBody = <String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': 'forbidden_inactive_profile',
          'message': 'Perfil ausente ou inativo.',
        },
      };
      await expectLater(
        () => docRepo.downloadSubmissionBytes(submissionId: validSubId),
        throwsA(
          isA<DocumentFailure>()
              .having((e) => e.httpStatus, 'httpStatus', 403)
              .having((e) => e.code, 'code', 'forbidden_inactive_profile')
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
      await expectLater(
        () => reviewRepo.downloadSubmissionBytes(submissionId: validSubId),
        throwsA(
          isA<ReviewFailure>()
              .having((e) => e.httpStatus, 'httpStatus', 403)
              .having((e) => e.code, 'code', 'forbidden_inactive_profile')
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)
              .having((e) => e.isForbiddenScope, 'isForbiddenScope', isTrue)
              .having((e) => e.shouldReloadQueue, 'shouldReloadQueue', isTrue),
        ),
      );

      // 4) HTTP 404 — Submissão alheia, revisor revogado/fora do escopo ou inexistente (sem oracle)
      nextStatus = 404;
      nextBody = <String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': 'submission_not_found',
          'message':
              'Submissão documental não encontrada ou acesso indisponível.',
        },
      };
      await expectLater(
        () => docRepo.downloadSubmissionBytes(submissionId: validSubId),
        throwsA(
          isA<DocumentFailure>()
              .having((e) => e.httpStatus, 'httpStatus', 404)
              .having((e) => e.code, 'code', 'submission_not_found'),
        ),
      );
      await expectLater(
        () => reviewRepo.downloadSubmissionBytes(submissionId: validSubId),
        throwsA(
          isA<ReviewFailure>()
              .having((e) => e.httpStatus, 'httpStatus', 404)
              .having((e) => e.code, 'code', 'submission_not_found')
              .having((e) => e.isNotFound, 'isNotFound', isTrue)
              .having((e) => e.isForbiddenScope, 'isForbiddenScope', isTrue)
              .having((e) => e.shouldReloadQueue, 'shouldReloadQueue', isTrue),
        ),
      );

      // 5) HTTP 413 — Limite de 5 MiB excedido
      nextStatus = 413;
      nextBody = <String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': 'file_too_large',
          'message': 'Documento excede o limite máximo de tamanho.',
        },
      };
      await expectLater(
        () => docRepo.downloadSubmissionBytes(submissionId: validSubId),
        throwsA(
          isA<DocumentFailure>()
              .having((e) => e.httpStatus, 'httpStatus', 413)
              .having((e) => e.code, 'code', 'file_too_large'),
        ),
      );
      await expectLater(
        () => reviewRepo.downloadSubmissionBytes(submissionId: validSubId),
        throwsA(
          isA<ReviewFailure>()
              .having((e) => e.httpStatus, 'httpStatus', 413)
              .having((e) => e.code, 'code', 'file_too_large'),
        ),
      );
    });

    test('GATE E3-GATEWAY-FIX-FE — Reprodução exata do ChunkProbe (8 blocos de 1 MiB) para estudante e revisor: interrompe e cancela no 6º bloco sem acumular bytes acima de 5 MiB', () async {
      const submissionId = '10000000-0000-4000-8000-000000000001';
      for (final reviewer in const <bool>[false, true]) {
        final transport = _SolEightMiBChunkProbeClient();
        GatewayDownloadStreamMetrics? capturedMetrics;
        final client = SupabaseClient(
          'http://127.0.0.1:54321',
          'local-audit-key',
          httpClient: transport,
        );
        addTearDown(() async {
          await client.dispose();
          transport.close();
        });

        Object? caught;
        try {
          if (reviewer) {
            await SupabaseReviewRepository(
              client,
              debugOnDownloadMetrics: (m) => capturedMetrics = m,
            ).downloadSubmissionBytes(submissionId: submissionId);
          } else {
            await SupabaseDocumentRepository(
              client,
              debugOnDownloadMetrics: (m) => capturedMetrics = m,
            ).downloadSubmissionBytes(submissionId: submissionId);
          }
        } catch (error) {
          caught = error;
        }

        expect(caught, isNotNull);
        if (reviewer) {
          expect(
            caught,
            isA<ReviewFailure>()
                .having((e) => e.code, 'code', 'file_too_large')
                .having((e) => e.httpStatus, 'httpStatus', 413),
          );
        } else {
          expect(
            caught,
            isA<DocumentFailure>()
                .having((e) => e.code, 'code', 'file_too_large')
                .having((e) => e.httpStatus, 'httpStatus', 413),
          );
        }

        expect(
          transport.chunks,
          lessThan(8),
          reason: 'Rejeitar no primeiro bloco que excede 5 MiB e cancelar o restante',
        );
        expect(transport.chunks, 6);
        expect(transport.generatorCancelled, isTrue);

        expect(capturedMetrics, isNotNull);
        expect(capturedMetrics!.chunksConsumed, 6);
        expect(capturedMetrics!.maxBytesAccumulated, kMaxPdfSizeBytes);
        expect(capturedMetrics!.retainedBytesAfterCancel, 0);
        expect(capturedMetrics!.subscriptionCancelled, isTrue);
        expect(capturedMetrics!.rejectedByContentLength, isFalse);
      }
    });

    test('GATE E3-GATEWAY-FIX-FE — Matriz completa de leitura limitada (abaixo, exato 5 MiB, Content-Length > 5 MiB/ausente/inconsistente, stream > 5 MiB + cancelamento, vazio, binário não-UTF8, erro de rede e timeout) em ambos os repositórios', () async {
      const submissionId = '20000000-0000-4000-8000-000000000002';

      for (final reviewer in const <bool>[false, true]) {
        Future<Uint8List> runDownload(
          http.BaseClient transport, {
          Duration timeout = const Duration(seconds: 5),
          void Function(GatewayDownloadStreamMetrics)? onMetrics,
        }) async {
          final client = SupabaseClient(
            'http://127.0.0.1:54321',
            'local-audit-key',
            httpClient: transport,
          );
          try {
            if (reviewer) {
              return await SupabaseReviewRepository(
                client,
                downloadTimeout: timeout,
                debugOnDownloadMetrics: onMetrics,
              ).downloadSubmissionBytes(submissionId: submissionId);
            }
            return await SupabaseDocumentRepository(
              client,
              downloadTimeout: timeout,
              debugOnDownloadMetrics: onMetrics,
            ).downloadSubmissionBytes(submissionId: submissionId);
          } finally {
            await client.dispose();
            transport.close();
          }
        }

        void expectFileTooLargeError(Object? error) {
          expect(error, isNotNull);
          if (reviewer) {
            expect(
              error,
              isA<ReviewFailure>()
                  .having((e) => e.code, 'code', 'file_too_large')
                  .having((e) => e.httpStatus, 'httpStatus', 413),
            );
          } else {
            expect(
              error,
              isA<DocumentFailure>()
                  .having((e) => e.code, 'code', 'file_too_large')
                  .having((e) => e.httpStatus, 'httpStatus', 413),
            );
          }
        }

        // 1) PDF válido abaixo do limite + binário não-UTF8 + Content-Length ausente
        final smallBinaryPdf = Uint8List.fromList(<int>[
          ...ascii.encode('%PDF-1.4\n%'),
          0xE2,
          0xE3,
          0xCF,
          0xD3,
          ...ascii.encode('\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n'),
        ]);
        expect(
          () => utf8.decode(smallBinaryPdf),
          throwsA(isA<FormatException>()),
        );
        GatewayDownloadStreamMetrics? belowMetrics;
        final belowTransport = _ConfigurableStreamProbeClient(
          chunks: <Uint8List>[
            smallBinaryPdf.sublist(0, 12),
            smallBinaryPdf.sublist(12),
          ],
          headers: const <String, String>{'content-type': 'application/pdf'},
        );
        final belowResult = await runDownload(
          belowTransport,
          onMetrics: (m) => belowMetrics = m,
        );
        expect(belowResult, equals(smallBinaryPdf));
        expect(belowTransport.chunksEmitted, 2);
        expect(belowMetrics!.chunksConsumed, 2);
        expect(belowMetrics!.maxBytesAccumulated, smallBinaryPdf.length);
        expect(belowMetrics!.subscriptionCancelled, isFalse);

        // 2) PDF válido exatamente no limite (5.242.880 bytes = 5 x 1 MiB)
        final fiveChunksExact = List<Uint8List>.generate(5, (index) {
          final chunk = Uint8List(1024 * 1024);
          if (index == 0) {
            chunk.setAll(0, ascii.encode('%PDF-1.4\n'));
          }
          if (index == 4) {
            final tail = ascii.encode('\n%%EOF\n');
            chunk.setAll(chunk.length - tail.length, tail);
          }
          return chunk;
        });
        GatewayDownloadStreamMetrics? exactMetrics;
        final exactTransport = _ConfigurableStreamProbeClient(
          chunks: fiveChunksExact,
          contentLength: kMaxPdfSizeBytes,
          headers: <String, String>{
            'content-type': 'application/pdf',
            'content-length': '$kMaxPdfSizeBytes',
          },
        );
        final exactResult = await runDownload(
          exactTransport,
          onMetrics: (m) => exactMetrics = m,
        );
        expect(exactResult.lengthInBytes, kMaxPdfSizeBytes);
        expect(exactTransport.chunksEmitted, 5);
        expect(exactMetrics!.chunksConsumed, 5);
        expect(exactMetrics!.maxBytesAccumulated, kMaxPdfSizeBytes);
        expect(exactMetrics!.subscriptionCancelled, isFalse);

        // 3) Content-Length acima do limite (5.242.881 bytes): rejeita ANTES de acumular corpo (0 blocos consumidos)
        GatewayDownloadStreamMetrics? overHeaderMetrics;
        final overHeaderTransport = _ConfigurableStreamProbeClient(
          chunks: fiveChunksExact,
          contentLength: kMaxPdfSizeBytes + 1,
          headers: <String, String>{
            'content-type': 'application/pdf',
            'content-length': '${kMaxPdfSizeBytes + 1}',
          },
        );
        Object? overHeaderErr;
        try {
          await runDownload(
            overHeaderTransport,
            onMetrics: (m) => overHeaderMetrics = m,
          );
        } catch (e) {
          overHeaderErr = e;
        }
        expectFileTooLargeError(overHeaderErr);
        expect(overHeaderTransport.chunksEmitted, 0);
        expect(overHeaderTransport.subscriptionCancelled, isTrue);
        expect(overHeaderTransport.abortSignaled, isTrue);
        expect(overHeaderMetrics!.chunksConsumed, 0);
        expect(overHeaderMetrics!.maxBytesAccumulated, 0);
        expect(overHeaderMetrics!.retainedBytesAfterCancel, 0);
        expect(overHeaderMetrics!.subscriptionCancelled, isTrue);
        expect(overHeaderMetrics!.rejectedByContentLength, isTrue);

        // 4) Content-Length inconsistente (declara 1024 bytes, mas stream envia 5 MiB + 1 byte + 2 blocos extras)
        final inconsistentChunks = <Uint8List>[
          ...fiveChunksExact,
          Uint8List.fromList(const <int>[0x41]), // +1 byte => 5.242.881
          Uint8List(1024 * 1024), // bloco 7 que nunca deve ser emitido
          Uint8List(1024 * 1024), // bloco 8 que nunca deve ser emitido
        ];
        GatewayDownloadStreamMetrics? inconsistentMetrics;
        final inconsistentTransport = _ConfigurableStreamProbeClient(
          chunks: inconsistentChunks,
          contentLength: 1024,
          headers: const <String, String>{
            'content-type': 'application/pdf',
            'content-length': '1024',
          },
        );
        Object? inconsistentErr;
        try {
          await runDownload(
            inconsistentTransport,
            onMetrics: (m) => inconsistentMetrics = m,
          );
        } catch (e) {
          inconsistentErr = e;
        }
        expectFileTooLargeError(inconsistentErr);
        expect(inconsistentTransport.chunksEmitted, 6);
        expect(inconsistentTransport.subscriptionCancelled, isTrue);
        expect(inconsistentMetrics!.chunksConsumed, 6);
        expect(inconsistentMetrics!.maxBytesAccumulated, kMaxPdfSizeBytes);
        expect(inconsistentMetrics!.retainedBytesAfterCancel, 0);
        expect(inconsistentMetrics!.subscriptionCancelled, isTrue);

        // 5) Resposta vazia (0 bytes)
        final emptyTransport = _ConfigurableStreamProbeClient(
          chunks: const <Uint8List>[],
          headers: const <String, String>{'content-type': 'application/pdf'},
        );
        Object? emptyErr;
        try {
          await runDownload(emptyTransport);
        } catch (e) {
          emptyErr = e;
        }
        expect(emptyErr, isNotNull);
        expect((emptyErr as dynamic).code, 'empty_downloaded_file');

        // 6) Erro de rede no meio do stream (após 1 bloco válido)
        GatewayDownloadStreamMetrics? netErrMetrics;
        final netErrTransport = _ConfigurableStreamProbeClient(
          chunks: <Uint8List>[smallBinaryPdf],
          errorAfterChunks: http.ClientException(
            'Conexão perdida durante stream',
          ),
          headers: const <String, String>{'content-type': 'application/pdf'},
        );
        Object? netErr;
        try {
          await runDownload(
            netErrTransport,
            onMetrics: (m) => netErrMetrics = m,
          );
        } catch (e) {
          netErr = e;
        }
        expect(netErr, isNotNull);
        expect((netErr as dynamic).code, 'network_error');
        expect((netErr as dynamic).isAmbiguousNetworkOrTimeout, isTrue);
        expect(netErrMetrics!.retainedBytesAfterCancel, 0);

        // 7) Timeout durante leitura do stream (emite 1 bloco e trava -> cancela assinatura e limpa buffer)
        GatewayDownloadStreamMetrics? timeoutMetrics;
        final timeoutTransport = _ConfigurableStreamProbeClient(
          chunks: <Uint8List>[smallBinaryPdf],
          hangBeforeClose: true,
          headers: const <String, String>{'content-type': 'application/pdf'},
        );
        Object? timeoutErr;
        try {
          await runDownload(
            timeoutTransport,
            timeout: const Duration(milliseconds: 60),
            onMetrics: (m) => timeoutMetrics = m,
          );
        } catch (e) {
          timeoutErr = e;
        }
        expect(timeoutErr, isNotNull);
        expect((timeoutErr as dynamic).code, 'timeout');
        expect((timeoutErr as dynamic).isAmbiguousNetworkOrTimeout, isTrue);
        expect(timeoutTransport.subscriptionCancelled, isTrue);
        expect(timeoutMetrics!.subscriptionCancelled, isTrue);
        expect(timeoutMetrics!.retainedBytesAfterCancel, 0);

        // 8) Rejeições HTTP preservam o status mesmo quando o corpo é excessivo.
        const errorLimit = 64 * 1024;
        for (final errorHasLength in const [true, false]) {
          final status = errorHasLength ? 403 : 404;
          final errorTransport = _ConfigurableStreamProbeClient(
            chunks: <Uint8List>[
              Uint8List(errorLimit),
              Uint8List(1),
              Uint8List(1),
            ],
            headers: const <String, String>{'content-type': 'application/json'},
            contentLength: errorHasLength ? errorLimit + 2 : null,
            statusCode: status,
          );
          try {
            await runDownload(errorTransport);
            fail('Expected HTTP failure');
          } on DocumentFailure catch (error) {
            expect(error.httpStatus, status);
          } on ReviewFailure catch (error) {
            expect(error.httpStatus, status);
            expect(error.shouldReloadQueue, isTrue);
          }
          expect(errorTransport.chunksEmitted, errorHasLength ? 0 : 2);
          expect(errorTransport.subscriptionCancelled, isTrue);
          expect(errorTransport.abortSignaled, isTrue);
        }
      }
    });
  });
}

class _CapturedGatewayHttpRequest {
  const _CapturedGatewayHttpRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.bodyBytes,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
}

class _GatewayMockResponse {
  const _GatewayMockResponse({
    required this.statusCode,
    required this.bytes,
    required this.headers,
  });

  final int statusCode;
  final Uint8List bytes;
  final Map<String, String> headers;
}

class _RecordingGatewayHttpClient extends http.BaseClient {
  _RecordingGatewayHttpClient({required this.handler});

  final _GatewayMockResponse Function(
    http.BaseRequest request,
    Uint8List bodyBytes,
  )
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    final mock = handler(request, bodyBytes);
    return http.StreamedResponse(
      Stream<List<int>>.value(mock.bytes),
      mock.statusCode,
      headers: mock.headers,
    );
  }
}

class _SolEightMiBChunkProbeClient extends http.BaseClient {
  int chunks = 0;
  bool generatorCancelled = false;

  Stream<List<int>> chunksOfOneMiB() async* {
    try {
      for (var i = 0; i < 8; i++) {
        final bytes = Uint8List(1024 * 1024);
        if (i == 0) {
          bytes.setAll(0, '%PDF-1.4'.codeUnits);
        }
        chunks++;
        yield bytes;
      }
    } finally {
      if (chunks < 8) {
        generatorCancelled = true;
      }
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.url.path, '/functions/v1/download-submission-pdf');
    return http.StreamedResponse(
      chunksOfOneMiB(),
      200,
      headers: const <String, String>{'content-type': 'application/pdf'},
    );
  }
}

class _ConfigurableStreamProbeClient extends http.BaseClient {
  _ConfigurableStreamProbeClient({
    required this.chunks,
    required this.headers,
    this.statusCode = 200,
    this.contentLength,
    this.errorAfterChunks,
    this.hangBeforeClose = false,
  });

  final List<Uint8List> chunks;
  final Map<String, String> headers;
  final int statusCode;
  final int? contentLength;
  final Object? errorAfterChunks;
  final bool hangBeforeClose;

  int chunksEmitted = 0;
  bool subscriptionCancelled = false;
  bool abortSignaled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.AbortableRequest) {
      unawaited(
        request.abortTrigger?.then<void>((_) {
          abortSignaled = true;
        }),
      );
    }
    late final StreamController<List<int>> controller;
    var active = true;

    controller = StreamController<List<int>>(
      onListen: () async {
        for (final chunk in chunks) {
          await Future<void>.delayed(Duration.zero);
          if (!active || controller.isClosed) {
            return;
          }
          chunksEmitted++;
          controller.add(chunk);
        }
        await Future<void>.delayed(Duration.zero);
        if (!active || controller.isClosed) {
          return;
        }
        if (errorAfterChunks != null) {
          controller.addError(errorAfterChunks!);
          await controller.close();
          return;
        }
        if (hangBeforeClose) {
          return;
        }
        await controller.close();
      },
      onCancel: () {
        active = false;
        subscriptionCancelled = true;
      },
    );

    return http.StreamedResponse(
      controller.stream,
      statusCode,
      contentLength: contentLength,
      headers: headers,
    );
  }
}
