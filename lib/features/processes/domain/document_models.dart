import 'dart:math';
import 'dart:typed_data';

import 'process_models.dart';

const String kPrivateDocumentsBucket = 'internship-documents';
const int kMaxPdfSizeBytes = 5 * 1024 * 1024; // 5 MiB (5.242.880 bytes)

enum SubmissionStatus {
  underReview('under_review', 'Em análise'),
  correctionRequested('correction_requested', 'Correção solicitada'),
  approved('approved', 'Aprovado');

  const SubmissionStatus(this.value, this.label);

  final String value;
  final String label;

  static SubmissionStatus fromDatabase(String? raw) {
    return switch (raw) {
      'under_review' => SubmissionStatus.underReview,
      'correction_requested' => SubmissionStatus.correctionRequested,
      'approved' => SubmissionStatus.approved,
      // Fallback conservador: envio recém-criado nunca assume aprovado.
      _ => SubmissionStatus.underReview,
    };
  }
}

enum ReviewDecision {
  approved('approved', 'Aprovado'),
  correctionRequested('correction_requested', 'Correção solicitada');

  const ReviewDecision(this.value, this.label);

  final String value;
  final String label;

  static ReviewDecision fromDatabase(String? raw) {
    return switch (raw) {
      'approved' => ReviewDecision.approved,
      _ => ReviewDecision.correctionRequested,
    };
  }
}

class DocumentSubmissionRecord {
  const DocumentSubmissionRecord({
    required this.id,
    required this.processId,
    required this.processRequirementId,
    required this.submittedBy,
    required this.version,
    required this.storageBucket,
    required this.storagePath,
    required this.mimeType,
    required this.sizeBytes,
    required this.status,
    required this.submittedAt,
    required this.createdAt,
    this.originalFilename,
    this.sha256Checksum,
    this.idempotencyKey,
  });

  factory DocumentSubmissionRecord.fromMap(Map<String, dynamic> map) {
    return DocumentSubmissionRecord(
      id: map['id'] as String,
      processId: (map['process_id'] as String?) ?? '',
      processRequirementId: (map['process_requirement_id'] as String?) ?? '',
      submittedBy: (map['submitted_by'] as String?) ?? '',
      version: _parseInt(map['version'], fallback: 1),
      storageBucket:
          (map['storage_bucket'] as String?) ?? kPrivateDocumentsBucket,
      storagePath: (map['storage_path'] as String?) ?? '',
      originalFilename: map['original_filename'] as String?,
      mimeType: (map['mime_type'] as String?) ?? 'application/pdf',
      sizeBytes: _parseInt(map['size_bytes']),
      sha256Checksum: map['sha256_checksum'] as String?,
      idempotencyKey: map['idempotency_key'] as String?,
      status: SubmissionStatus.fromDatabase(map['status'] as String?),
      submittedAt: _parseDateTime(map['submitted_at']),
      createdAt: _parseDateTime(map['created_at']),
    );
  }

  final String id;
  final String processId;
  final String processRequirementId;
  final String submittedBy;
  final int version;
  final String storageBucket;
  final String storagePath;
  final String? originalFilename;
  final String mimeType;
  final int sizeBytes;
  final String? sha256Checksum;
  final String? idempotencyKey;
  final SubmissionStatus status;
  final DateTime submittedAt;
  final DateTime createdAt;

  String get displayFilename {
    final trimmed = originalFilename?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    return 'documento_v$version.pdf';
  }

  String get formattedSize => formatByteSize(sizeBytes);
}

class DocumentReviewRecord {
  const DocumentReviewRecord({
    required this.id,
    required this.processId,
    required this.processRequirementId,
    required this.submissionId,
    required this.reviewerId,
    required this.decision,
    required this.reviewedAt,
    this.reason,
  });

  factory DocumentReviewRecord.fromMap(Map<String, dynamic> map) {
    return DocumentReviewRecord(
      id: map['id'] as String,
      processId: (map['process_id'] as String?) ?? '',
      processRequirementId: (map['process_requirement_id'] as String?) ?? '',
      submissionId: (map['submission_id'] as String?) ?? '',
      reviewerId: (map['reviewer_id'] as String?) ?? '',
      decision: ReviewDecision.fromDatabase(map['decision'] as String?),
      reason: map['reason'] as String?,
      reviewedAt: _parseDateTime(map['reviewed_at']),
    );
  }

  final String id;
  final String processId;
  final String processRequirementId;
  final String submissionId;
  final String reviewerId;
  final ReviewDecision decision;
  final String? reason;
  final DateTime reviewedAt;
}

class SelectedPdfFile {
  SelectedPdfFile({required this.name, required this.bytes, int? sizeBytes})
    : sizeBytes = sizeBytes ?? bytes.lengthInBytes;

  final String name;
  final Uint8List bytes;
  final int sizeBytes;

  String get basename => extractSanitizedBasename(name);

  String get formattedSize => formatByteSize(sizeBytes);
}

abstract final class PdfPreliminaryValidation {
  static String? validate(
    SelectedPdfFile file, {
    int maxBytes = kMaxPdfSizeBytes,
  }) {
    final rawNormalized = file.name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    if (rawNormalized.contains('..')) {
      return 'Nome de arquivo inválido para envio.';
    }

    final basename = extractSanitizedBasename(rawNormalized);
    if (basename.isEmpty ||
        basename.length > 180 ||
        basename.startsWith('.') ||
        !basename.toLowerCase().endsWith('.pdf')) {
      return 'Selecione um arquivo com extensão .pdf.';
    }

    if (file.sizeBytes <= 0) {
      return 'O arquivo PDF selecionado está vazio.';
    }

    if (file.sizeBytes > maxBytes) {
      return 'O PDF selecionado excede o limite máximo de 5 MiB (${formatByteSize(maxBytes)}).';
    }

    if (file.bytes.isEmpty) {
      return 'O arquivo PDF selecionado está vazio.';
    }

    if (file.bytes.lengthInBytes > maxBytes) {
      return 'O PDF selecionado excede o limite máximo de 5 MiB (${formatByteSize(maxBytes)}).';
    }

    if (!hasPdfHeader(file.bytes)) {
      return 'O arquivo selecionado não possui assinatura válida de documento PDF (%PDF-).';
    }

    return null;
  }

  static bool hasPdfHeader(Uint8List bytes) {
    if (bytes.lengthInBytes < 5) {
      return false;
    }
    return bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46 && // F
        bytes[4] == 0x2D; // -
  }
}

class SubmitPdfOutcome {
  const SubmitPdfOutcome({
    required this.submission,
    required this.idempotentReplay,
    required this.requirementStatus,
    required this.currentVersion,
    required this.currentSubmissionId,
  });

  final DocumentSubmissionRecord submission;
  final bool idempotentReplay;
  final RequirementStatus requirementStatus;
  final int currentVersion;
  final String currentSubmissionId;
}

class DocumentFailure implements Exception {
  const DocumentFailure(
    this.message, {
    this.code,
    this.httpStatus,
    this.isUnauthorized = false,
    this.isAmbiguousNetworkOrTimeout = false,
    this.isConflict = false,
  });

  final String message;
  final String? code;
  final int? httpStatus;
  final bool isUnauthorized;
  final bool isAmbiguousNetworkOrTimeout;
  final bool isConflict;

  @override
  String toString() => message;
}

bool isCurrentSubmissionForRequirement(
  DocumentSubmissionRecord submission,
  ProcessRequirementItem requirement,
) {
  final currentId = requirement.currentSubmissionId;
  if (currentId != null && currentId.isNotEmpty) {
    return submission.id == currentId;
  }
  return requirement.currentVersion > 0 &&
      submission.version == requirement.currentVersion;
}

String extractSanitizedBasename(String rawFilename) {
  final cleaned = rawFilename.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (cleaned.isEmpty) {
    return '';
  }
  final segments = cleaned.split(RegExp(r'[\\/]'));
  return segments.last.trim();
}

String formatByteSize(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024.0;
    return '${kb.toStringAsFixed(kb >= 100 ? 0 : 1)} KB';
  }
  final mb = bytes / (1024.0 * 1024.0);
  return '${mb.toStringAsFixed(2)} MB';
}

final Random _secureRandom = _createRandom();

Random _createRandom() {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}

String generateUuidV4() {
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = _secureRandom.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  String hex(int byte) => byte.toRadixString(16).padLeft(2, '0');
  final b = bytes.map(hex).toList(growable: false);
  return '${b[0]}${b[1]}${b[2]}${b[3]}-'
      '${b[4]}${b[5]}-'
      '${b[6]}${b[7]}-'
      '${b[8]}${b[9]}-'
      '${b[10]}${b[11]}${b[12]}${b[13]}${b[14]}${b[15]}';
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
