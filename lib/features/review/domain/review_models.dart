import 'dart:typed_data';

import '../../processes/domain/document_models.dart';
import '../../processes/domain/process_models.dart';
import '../data/pdf_document_renderer.dart';

const int kDefaultReviewPageSize = 20;
const int kMaxReviewReasonLength = 2000;

class ReviewerQueueQuery {
  const ReviewerQueueQuery({
    this.page = 0,
    this.pageSize = kDefaultReviewPageSize,
    this.searchQuery = '',
    this.onlyRequired,
    this.onlyResubmissions,
    this.institutionId,
    this.courseId,
    this.courseModalityId,
    this.processId,
    this.requirementCode,
    this.oldestFirst = true,
  });

  final int page;
  final int pageSize;
  final String searchQuery;
  final bool? onlyRequired;
  final bool? onlyResubmissions;
  final String? institutionId;
  final String? courseId;
  final String? courseModalityId;
  final String? processId;
  final String? requirementCode;
  final bool oldestFirst;

  bool get hasActiveFilters =>
      searchQuery.trim().isNotEmpty ||
      onlyRequired != null ||
      onlyResubmissions != null ||
      (institutionId != null && institutionId!.trim().isNotEmpty) ||
      (courseId != null && courseId!.trim().isNotEmpty) ||
      (courseModalityId != null && courseModalityId!.trim().isNotEmpty) ||
      (processId != null && processId!.trim().isNotEmpty) ||
      (requirementCode != null && requirementCode!.trim().isNotEmpty);

  ReviewerQueueQuery copyWith({
    int? page,
    int? pageSize,
    String? searchQuery,
    bool? Function()? onlyRequired,
    bool? Function()? onlyResubmissions,
    String? Function()? institutionId,
    String? Function()? courseId,
    String? Function()? courseModalityId,
    String? Function()? processId,
    String? Function()? requirementCode,
    bool? oldestFirst,
  }) {
    return ReviewerQueueQuery(
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      searchQuery: searchQuery ?? this.searchQuery,
      onlyRequired: onlyRequired != null ? onlyRequired() : this.onlyRequired,
      onlyResubmissions: onlyResubmissions != null
          ? onlyResubmissions()
          : this.onlyResubmissions,
      institutionId: institutionId != null
          ? institutionId()
          : this.institutionId,
      courseId: courseId != null ? courseId() : this.courseId,
      courseModalityId: courseModalityId != null
          ? courseModalityId()
          : this.courseModalityId,
      processId: processId != null ? processId() : this.processId,
      requirementCode: requirementCode != null
          ? requirementCode()
          : this.requirementCode,
      oldestFirst: oldestFirst ?? this.oldestFirst,
    );
  }
}

class PaginatedResult<T> {
  const PaginatedResult({
    required this.items,
    required this.totalCount,
    required this.page,
    required this.pageSize,
  });

  final List<T> items;
  final int totalCount;
  final int page;
  final int pageSize;

  int get totalPages {
    if (totalCount <= 0 || pageSize <= 0) {
      return 1;
    }
    return (totalCount + pageSize - 1) ~/ pageSize;
  }

  bool get hasPreviousPage => page > 0;

  bool get hasNextPage => (page + 1) * pageSize < totalCount;

  int get rangeStart =>
      (totalCount <= 0 || items.isEmpty) ? 0 : (page * pageSize) + 1;

  int get rangeEnd =>
      (totalCount <= 0 || items.isEmpty) ? 0 : (page * pageSize) + items.length;
}

class ReviewerQueueItem {
  const ReviewerQueueItem({
    required this.submissionId,
    required this.processRequirementId,
    required this.processId,
    required this.studentId,
    required this.studentName,
    required this.institutionId,
    required this.courseId,
    required this.courseModalityId,
    required this.processStatus,
    required this.processOpenedAt,
    required this.templateVersion,
    required this.requirementCode,
    required this.requirementTitle,
    required this.requirementDisplayOrder,
    required this.isRequired,
    required this.requirementStatus,
    required this.currentVersion,
    required this.isResubmission,
    required this.submissionVersion,
    required this.submissionStatus,
    required this.sizeBytes,
    required this.storageBucket,
    required this.storagePath,
    required this.submittedAt,
    required this.isDemo,
    this.institutionCode,
    this.institutionName,
    this.courseCode,
    this.courseName,
    this.modalityCode,
    this.modalityName,
    this.originalFilename,
    this.sha256Checksum,
  });

  factory ReviewerQueueItem.fromMap(Map<String, dynamic> map) {
    final version = _parseInt(
      map['submission_version'],
      fallback: _parseInt(map['current_version'], fallback: 1),
    );
    final rawStudentName = (map['student_name'] as String?)?.trim();
    return ReviewerQueueItem(
      submissionId: (map['submission_id'] as String?) ?? '',
      processRequirementId: (map['process_requirement_id'] as String?) ?? '',
      processId: (map['process_id'] as String?) ?? '',
      studentId: (map['student_id'] as String?) ?? '',
      studentName: (rawStudentName != null && rawStudentName.isNotEmpty)
          ? rawStudentName
          : 'Estudante',
      institutionId: (map['institution_id'] as String?) ?? '',
      institutionCode: map['institution_code'] as String?,
      institutionName: map['institution_name'] as String?,
      courseId: (map['course_id'] as String?) ?? '',
      courseCode: map['course_code'] as String?,
      courseName: map['course_name'] as String?,
      courseModalityId: (map['course_modality_id'] as String?) ?? '',
      modalityCode: map['modality_code'] as String?,
      modalityName: map['modality_name'] as String?,
      processStatus: ProcessStatus.fromDatabase(
        map['process_status'] as String?,
      ),
      processOpenedAt: _parseDateTime(map['process_opened_at']),
      templateVersion: _parseInt(map['template_version'], fallback: 1),
      requirementCode: (map['requirement_code'] as String?) ?? '',
      requirementTitle:
          (map['requirement_title'] as String?) ?? 'Requisito documental',
      requirementDisplayOrder: _parseInt(
        map['requirement_display_order'],
        fallback: 1,
      ),
      isRequired: (map['is_required'] as bool?) ?? true,
      requirementStatus: RequirementStatus.fromDatabase(
        (map['requirement_status'] as String?) ?? 'under_review',
      ),
      currentVersion: _parseInt(map['current_version'], fallback: version),
      isResubmission: (map['is_resubmission'] as bool?) ?? (version > 1),
      submissionVersion: version,
      submissionStatus: SubmissionStatus.fromDatabase(
        (map['submission_status'] as String?) ?? 'under_review',
      ),
      originalFilename: map['original_filename'] as String?,
      sizeBytes: _parseInt(map['size_bytes']),
      sha256Checksum: map['sha256_checksum'] as String?,
      storageBucket:
          (map['storage_bucket'] as String?) ?? kPrivateDocumentsBucket,
      storagePath: (map['storage_path'] as String?) ?? '',
      submittedAt: _parseDateTime(map['submitted_at']),
      isDemo: (map['is_demo'] as bool?) ?? true,
    );
  }

  final String submissionId;
  final String processRequirementId;
  final String processId;
  final String studentId;
  final String studentName;
  final String institutionId;
  final String? institutionCode;
  final String? institutionName;
  final String courseId;
  final String? courseCode;
  final String? courseName;
  final String courseModalityId;
  final String? modalityCode;
  final String? modalityName;
  final ProcessStatus processStatus;
  final DateTime processOpenedAt;
  final int templateVersion;
  final String requirementCode;
  final String requirementTitle;
  final int requirementDisplayOrder;
  final bool isRequired;
  final RequirementStatus requirementStatus;
  final int currentVersion;
  final bool isResubmission;
  final int submissionVersion;
  final SubmissionStatus submissionStatus;
  final String? originalFilename;
  final int sizeBytes;
  final String? sha256Checksum;
  final String storageBucket;
  final String storagePath;
  final DateTime submittedAt;
  final bool isDemo;

  String get displayFilename {
    final trimmed = originalFilename?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return extractSanitizedBasename(trimmed);
    }
    return 'documento_v$submissionVersion.pdf';
  }

  String get formattedSize => formatByteSize(sizeBytes);

  String get displayInstitutionName =>
      (institutionName != null && institutionName!.trim().isNotEmpty)
      ? institutionName!.trim()
      : 'Instituição vinculada ao escopo';

  String get displayCourseName =>
      (courseName != null && courseName!.trim().isNotEmpty)
      ? courseName!.trim()
      : 'Curso vinculado ao escopo';

  String get displayModalityName =>
      (modalityName != null && modalityName!.trim().isNotEmpty)
      ? modalityName!.trim()
      : 'Modalidade vinculada ao escopo';
}

class VerifiedPdfPayload {
  VerifiedPdfPayload({
    required this.submissionId,
    required this.submissionVersion,
    required this.processId,
    required this.processRequirementId,
    required this.requirementCode,
    required this.requirementTitle,
    required this.studentName,
    required this.originalFilename,
    required this.storageBucket,
    required this.storagePath,
    required Uint8List bytes,
    required this.loadedAt,
    this.renderedDocument,
  }) : _bytes = Uint8List.fromList(bytes),
       sizeBytes = bytes.lengthInBytes,
       hasValidPdfSignature = PdfPreliminaryValidation.hasPdfHeader(bytes);

  final String submissionId;
  final int submissionVersion;
  final String processId;
  final String processRequirementId;
  final String requirementCode;
  final String requirementTitle;
  final String studentName;
  final String originalFilename;
  final String storageBucket;
  final String storagePath;
  final Uint8List _bytes;
  final int sizeBytes;
  final DateTime loadedAt;
  final bool hasValidPdfSignature;
  final RenderedPdfDocument? renderedDocument;

  bool _isWiped = false;

  Uint8List get bytes => _bytes;
  bool get isWiped => _isWiped;
  int get pageCount => renderedDocument?.pageCount ?? 0;
  String get formattedSize => formatByteSize(sizeBytes);

  String get headerSnippet {
    if (_isWiped || _bytes.isEmpty) {
      return '';
    }
    final limit = _bytes.length < 160 ? _bytes.length : 160;
    final buffer = StringBuffer();
    for (var i = 0; i < limit; i++) {
      final byte = _bytes[i];
      if (byte >= 32 && byte <= 126) {
        buffer.writeCharCode(byte);
      } else if (byte == 10 || byte == 13) {
        buffer.write(' ');
      }
    }
    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Zera imediatamente todos os bytes do buffer em memória, páginas
  /// rasterizadas e sessões efêmeras de visualização em logout, troca de conta,
  /// troca de item ou dispose.
  void wipeBytes() {
    if (_bytes.isNotEmpty) {
      _bytes.fillRange(0, _bytes.length, 0);
    }
    renderedDocument?.wipe();
    _isWiped = true;
  }
}

abstract final class ReviewDecisionValidation {
  static String cleanReason(String? raw) {
    if (raw == null || raw.isEmpty) {
      return '';
    }
    return raw
        .replaceAll(RegExp(r'[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
        .trim();
  }

  static String? validate({
    required ReviewDecision? decision,
    required String? reason,
  }) {
    if (decision == null) {
      return 'Selecione uma decisão (aprovar ou solicitar correção).';
    }
    final cleaned = cleanReason(reason);
    if (decision == ReviewDecision.correctionRequested && cleaned.isEmpty) {
      return 'Informe a justificativa obrigatória para solicitar correção.';
    }
    if (cleaned.length > kMaxReviewReasonLength) {
      return 'A justificativa da revisão excede o limite de $kMaxReviewReasonLength caracteres.';
    }
    return null;
  }
}

class ReviewDecisionOutcome {
  const ReviewDecisionOutcome({
    required this.ok,
    required this.idempotentReplay,
    required this.review,
    required this.submission,
    required this.requirement,
    required this.process,
    this.progress,
  });

  factory ReviewDecisionOutcome.fromMap(Map<String, dynamic> map) {
    final reviewMap = _asMap(map['review']);
    final submissionMap = _asMap(map['submission']);
    final requirementMap = _asMap(map['requirement']);
    final processMap = _asMap(map['process']);
    final progressMap = _asMap(map['progress']);

    if (reviewMap == null ||
        submissionMap == null ||
        requirementMap == null ||
        processMap == null) {
      throw const ReviewFailure(
        'Resposta incompleta do servidor ao registrar a decisão de revisão.',
        code: 'incomplete_server_response',
      );
    }

    final progress = progressMap != null
        ? ProcessProgressSummary.fromMap(progressMap)
        : null;

    return ReviewDecisionOutcome(
      ok: (map['ok'] as bool?) ?? true,
      idempotentReplay: (map['idempotent_replay'] as bool?) ?? false,
      review: DocumentReviewRecord.fromMap(reviewMap),
      submission: DocumentSubmissionRecord.fromMap(submissionMap),
      requirement: ProcessRequirementItem.fromMap(requirementMap),
      process: InternshipProcessSummary.fromMap(processMap, progress: progress),
      progress: progress,
    );
  }

  final bool ok;
  final bool idempotentReplay;
  final DocumentReviewRecord review;
  final DocumentSubmissionRecord submission;
  final ProcessRequirementItem requirement;
  final InternshipProcessSummary process;
  final ProcessProgressSummary? progress;
}

enum AuditEventType {
  processCreated('process_created', 'Processo aberto e checklist gerado'),
  documentSubmitted(
    'document_submitted',
    'Submissão de PDF enviada para análise',
  ),
  documentCorrectionRequested(
    'document_correction_requested',
    'Revisão registrada: correção solicitada',
  ),
  documentApproved(
    'document_approved',
    'Revisão registrada: aprovado documentalmente',
  ),
  processDocumentallyCompleted(
    'process_documentally_completed',
    'Checklist concluído sem pendências documentais',
  ),
  other('other', 'Evento registrado no processo');

  const AuditEventType(this.value, this.label);

  final String value;
  final String label;

  static AuditEventType fromDatabase(String? raw) {
    return switch (raw) {
      'process_created' => AuditEventType.processCreated,
      'document_submitted' => AuditEventType.documentSubmitted,
      'document_correction_requested' =>
        AuditEventType.documentCorrectionRequested,
      'document_approved' => AuditEventType.documentApproved,
      'process_documentally_completed' =>
        AuditEventType.processDocumentallyCompleted,
      _ => AuditEventType.other,
    };
  }
}

class ProcessAuditTimelineEvent {
  const ProcessAuditTimelineEvent({
    required this.eventId,
    required this.processId,
    required this.eventType,
    required this.rawEventType,
    required this.actorRole,
    required this.actorDisplayName,
    required this.entityTable,
    required this.entityId,
    required this.processStatus,
    required this.institutionId,
    required this.courseId,
    required this.courseModalityId,
    required this.occurredAt,
    required this.metadata,
    this.actorId,
    this.targetUserId,
    this.processRequirementId,
    this.requirementCode,
    this.requirementTitle,
    this.submissionId,
    this.submissionVersion,
    this.decision,
    this.reason,
  });

  factory ProcessAuditTimelineEvent.fromMap(Map<String, dynamic> map) {
    final rawType = (map['event_type'] as String?) ?? 'other';
    final rawRole = (map['actor_role'] as String?) ?? 'system';
    final rawDisplayName = (map['actor_display_name'] as String?)?.trim();
    final fallbackName = switch (rawRole) {
      'reviewer' => 'Revisor',
      'student' => 'Estudante',
      _ => 'Sistema',
    };
    final rawDecision = (map['decision'] as String?)?.trim();
    final meta = _asMap(map['metadata']) ?? const <String, dynamic>{};

    return ProcessAuditTimelineEvent(
      eventId: (map['event_id'] as String?) ?? (map['id'] as String?) ?? '',
      processId: (map['process_id'] as String?) ?? '',
      eventType: AuditEventType.fromDatabase(rawType),
      rawEventType: rawType,
      actorId: map['actor_id'] as String?,
      actorRole: rawRole,
      actorDisplayName: (rawDisplayName != null && rawDisplayName.isNotEmpty)
          ? rawDisplayName
          : fallbackName,
      targetUserId: map['target_user_id'] as String?,
      entityTable: (map['entity_table'] as String?) ?? '',
      entityId: (map['entity_id'] as String?) ?? '',
      processRequirementId: map['process_requirement_id'] as String?,
      requirementCode: map['requirement_code'] as String?,
      requirementTitle: map['requirement_title'] as String?,
      submissionId: map['submission_id'] as String?,
      submissionVersion: map['submission_version'] == null
          ? null
          : _parseInt(map['submission_version']),
      decision: (rawDecision != null && rawDecision.isNotEmpty)
          ? ReviewDecision.fromDatabase(rawDecision)
          : null,
      reason: map['reason'] as String?,
      processStatus: ProcessStatus.fromDatabase(
        map['process_status'] as String?,
      ),
      institutionId: (map['institution_id'] as String?) ?? '',
      courseId: (map['course_id'] as String?) ?? '',
      courseModalityId: (map['course_modality_id'] as String?) ?? '',
      occurredAt: _parseDateTime(map['occurred_at']),
      metadata: meta,
    );
  }

  final String eventId;
  final String processId;
  final AuditEventType eventType;
  final String rawEventType;
  final String? actorId;
  final String actorRole;
  final String actorDisplayName;
  final String? targetUserId;
  final String entityTable;
  final String entityId;
  final String? processRequirementId;
  final String? requirementCode;
  final String? requirementTitle;
  final String? submissionId;
  final int? submissionVersion;
  final ReviewDecision? decision;
  final String? reason;
  final ProcessStatus processStatus;
  final String institutionId;
  final String courseId;
  final String courseModalityId;
  final DateTime occurredAt;
  final Map<String, dynamic> metadata;

  bool get isResubmission =>
      (metadata['is_resubmission'] == true) ||
      (eventType == AuditEventType.documentSubmitted &&
          (submissionVersion ?? 1) > 1);

  bool get isNotOfficialAuthorization =>
      (metadata['not_official_internship_authorization'] == true) ||
      eventType == AuditEventType.processDocumentallyCompleted;

  String get actorRoleLabel => switch (actorRole) {
    'reviewer' => 'Revisor',
    'student' => 'Estudante',
    _ => 'Sistema',
  };

  String get displayTitle {
    if (eventType == AuditEventType.documentSubmitted && isResubmission) {
      final ver = submissionVersion != null ? ' (v$submissionVersion)' : '';
      return 'Reenvio de PDF após correção$ver';
    }
    if (eventType == AuditEventType.documentSubmitted &&
        submissionVersion != null) {
      return 'Submissão de PDF enviada (v$submissionVersion)';
    }
    return eventType.label;
  }
}

class ReviewFailure implements Exception {
  const ReviewFailure(
    this.message, {
    this.code,
    this.httpStatus,
    this.isUnauthorized = false,
    this.isForbiddenRole = false,
    this.isForbiddenScope = false,
    this.isProcessCancelled = false,
    this.isValidationError = false,
    this.isNotFound = false,
    this.isConflict = false,
    this.isObsoleteVersion = false,
    this.isAlreadyReviewed = false,
    this.isIdempotencyMismatch = false,
    this.shouldReloadQueue = false,
    this.isAmbiguousNetworkOrTimeout = false,
  });

  final String message;
  final String? code;
  final int? httpStatus;
  final bool isUnauthorized;
  final bool isForbiddenRole;
  final bool isForbiddenScope;
  final bool isProcessCancelled;
  final bool isValidationError;
  final bool isNotFound;
  final bool isConflict;
  final bool isObsoleteVersion;
  final bool isAlreadyReviewed;
  final bool isIdempotencyMismatch;
  final bool shouldReloadQueue;
  final bool isAmbiguousNetworkOrTimeout;

  @override
  String toString() => message;
}

Map<String, dynamic>? _asMap(Object? raw) {
  if (raw is Map<String, dynamic>) {
    return raw;
  }
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

int _parseInt(Object? raw, {int fallback = 0}) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? fallback;
  return fallback;
}

DateTime _parseDateTime(Object? raw) {
  if (raw is DateTime) return raw.toLocal();
  if (raw is String && raw.trim().isNotEmpty) {
    return DateTime.tryParse(raw.trim())?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
