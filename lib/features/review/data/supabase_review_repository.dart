import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart'
    as http
    show ClientException, RequestAbortedException;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../processes/data/supabase_document_repository.dart'
    show GatewayDownloadStreamMetrics, downloadPrivateSubmissionPdfFromGateway;
import '../../processes/domain/document_models.dart';
import '../domain/review_models.dart';
import '../domain/review_repository.dart';

class SupabaseReviewRepository implements ReviewRepository {
  const SupabaseReviewRepository(
    this._client, {
    this.rpcTimeout = const Duration(seconds: 30),
    this.downloadTimeout = const Duration(seconds: 30),
    @visibleForTesting this.debugOnDownloadMetrics,
  });

  final SupabaseClient _client;
  final Duration rpcTimeout;
  final Duration downloadTimeout;
  @visibleForTesting
  final void Function(GatewayDownloadStreamMetrics metrics)?
  debugOnDownloadMetrics;

  static const String _queueSelectColumns =
      'submission_id, process_requirement_id, process_id, student_id, '
      'student_name, institution_id, institution_code, institution_name, '
      'course_id, course_code, course_name, course_modality_id, '
      'modality_code, modality_name, process_status, process_opened_at, '
      'template_version, requirement_code, requirement_title, '
      'requirement_display_order, is_required, requirement_status, '
      'current_version, is_resubmission, submission_version, '
      'submission_status, original_filename, size_bytes, sha256_checksum, '
      'storage_bucket, storage_path, submitted_at, is_demo';

  static const String _timelineSelectColumns =
      'event_id, process_id, event_type, actor_id, actor_role, '
      'actor_display_name, target_user_id, entity_table, entity_id, '
      'process_requirement_id, requirement_code, requirement_title, '
      'submission_id, submission_version, decision, reason, process_status, '
      'institution_id, course_id, course_modality_id, occurred_at, metadata';

  static const String _submissionColumns =
      'id, process_id, process_requirement_id, submitted_by, version, '
      'storage_bucket, storage_path, original_filename, mime_type, '
      'size_bytes, sha256_checksum, idempotency_key, status, submitted_at, created_at';

  static const String _reviewColumns =
      'id, process_id, process_requirement_id, submission_id, reviewer_id, '
      'decision, reason, reviewed_at';

  static final RegExp _errTagRegex = RegExp(r'\[ERR:([a-z0-9_]+)\]');

  @override
  Future<PaginatedResult<ReviewerQueueItem>> fetchReviewerQueue({
    ReviewerQueueQuery query = const ReviewerQueueQuery(),
  }) async {
    final safePage = query.page < 0 ? 0 : query.page;
    final safePageSize = query.pageSize.clamp(1, 100);
    final from = safePage * safePageSize;
    final to = from + safePageSize - 1;

    try {
      var filter = _client.from('reviewer_queue_v').select(_queueSelectColumns);

      if (query.institutionId != null &&
          query.institutionId!.trim().isNotEmpty) {
        filter = filter.eq('institution_id', query.institutionId!.trim());
      }
      if (query.courseId != null && query.courseId!.trim().isNotEmpty) {
        filter = filter.eq('course_id', query.courseId!.trim());
      }
      if (query.courseModalityId != null &&
          query.courseModalityId!.trim().isNotEmpty) {
        filter = filter.eq(
          'course_modality_id',
          query.courseModalityId!.trim(),
        );
      }
      if (query.processId != null && query.processId!.trim().isNotEmpty) {
        filter = filter.eq('process_id', query.processId!.trim());
      }
      if (query.requirementCode != null &&
          query.requirementCode!.trim().isNotEmpty) {
        filter = filter.eq('requirement_code', query.requirementCode!.trim());
      }
      if (query.onlyRequired != null) {
        filter = filter.eq('is_required', query.onlyRequired!);
      }
      if (query.onlyResubmissions != null) {
        filter = filter.eq('is_resubmission', query.onlyResubmissions!);
      }

      final sanitizedTerm = sanitizeSearchTerm(query.searchQuery);
      if (sanitizedTerm.isNotEmpty) {
        filter = filter.or(
          'student_name.ilike.*$sanitizedTerm*,'
          'requirement_title.ilike.*$sanitizedTerm*,'
          'requirement_code.ilike.*$sanitizedTerm*,'
          'course_name.ilike.*$sanitizedTerm*',
        );
      }

      final response = await filter
          .order('submitted_at', ascending: query.oldestFirst)
          .order('submission_id', ascending: query.oldestFirst)
          .range(from, to)
          .count(CountOption.exact);

      final items = response.data
          .map(ReviewerQueueItem.fromMap)
          .toList(growable: false);

      return PaginatedResult<ReviewerQueueItem>(
        items: items,
        totalCount: response.count,
        page: safePage,
        pageSize: safePageSize,
      );
    } on ReviewFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  @override
  Future<Uint8List> downloadSubmissionBytes({
    required String submissionId,
  }) async {
    try {
      // Canal exclusivo server-side (GATE E3-CACHE-FIX / E3-GATEWAY-FIX-FE):
      // POST /functions/v1/download-submission-pdf com leitura incremental limitada a 5 MiB.
      return await downloadPrivateSubmissionPdfFromGateway(
        client: _client,
        submissionId: submissionId,
        timeout: downloadTimeout,
        debugOnDownloadMetrics: debugOnDownloadMetrics,
        onInvalidSubmissionId: () => const ReviewFailure(
          'Identificador de submissão inválido ou canal de acesso não permitido.',
          code: 'invalid_submission_id',
          httpStatus: 400,
          isValidationError: true,
        ),
        onInvalidContentType: () => const ReviewFailure(
          'Resposta inesperada do servidor ao baixar o documento PDF.',
          code: 'invalid_pdf_content_type',
        ),
        onEmptyFile: () => const ReviewFailure(
          'O arquivo PDF retornado pelo armazenamento privado está vazio.',
          code: 'empty_downloaded_file',
        ),
        onFileTooLarge: () => const ReviewFailure(
          'O arquivo PDF ultrapassa o limite máximo permitido de 5 MiB.',
          code: 'file_too_large',
          httpStatus: 413,
        ),
        onInvalidPdfSignature: () => const ReviewFailure(
          'Os bytes retornados não possuem assinatura válida de documento PDF (%PDF-).',
          code: 'invalid_pdf_signature',
        ),
      );
    } on ReviewFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  @override
  Future<ReviewDecisionOutcome> reviewSubmission({
    required String submissionId,
    required ReviewDecision decision,
    String? reason,
    String? idempotencyKey,
  }) async {
    final cleanSubId = submissionId.trim();
    if (cleanSubId.isEmpty) {
      throw const ReviewFailure(
        'Selecione uma submissão válida antes de registrar a decisão.',
        code: 'invalid_input',
        httpStatus: 400,
        isValidationError: true,
      );
    }

    final validationError = ReviewDecisionValidation.validate(
      decision: decision,
      reason: reason,
    );
    if (validationError != null) {
      final cleaned = ReviewDecisionValidation.cleanReason(reason);
      throw ReviewFailure(
        validationError,
        code: cleaned.length > kMaxReviewReasonLength
            ? 'reason_too_long'
            : 'missing_correction_reason',
        httpStatus: 400,
        isValidationError: true,
      );
    }

    final cleanedReason = ReviewDecisionValidation.cleanReason(reason);
    final normalizedKey = idempotencyKey?.trim();

    try {
      final dynamic rpcResult = await _client
          .rpc(
            'review_submission',
            params: <String, dynamic>{
              'p_submission_id': cleanSubId,
              'p_decision': decision.value,
              'p_reason': cleanedReason.isEmpty ? null : cleanedReason,
              'p_idempotency_key':
                  (normalizedKey == null || normalizedKey.isEmpty)
                  ? null
                  : normalizedKey,
            },
          )
          .timeout(rpcTimeout);

      final resultMap = _asStringKeyedMap(rpcResult);
      if (resultMap == null || resultMap['ok'] != true) {
        throw const ReviewFailure(
          'Resposta inesperada do servidor ao registrar a decisão.',
          code: 'invalid_server_response',
        );
      }

      return ReviewDecisionOutcome.fromMap(resultMap);
    } on ReviewFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  @override
  Future<List<DocumentSubmissionRecord>> fetchRequirementSubmissions({
    required String processRequirementId,
  }) async {
    try {
      final rows = await _client
          .from('document_submissions')
          .select(_submissionColumns)
          .eq('process_requirement_id', processRequirementId.trim())
          .order('version', ascending: false);

      final items = rows
          .map(DocumentSubmissionRecord.fromMap)
          .toList(growable: false);
      items.sort((a, b) => b.version.compareTo(a.version));
      return items;
    } on ReviewFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  @override
  Future<List<DocumentReviewRecord>> fetchRequirementReviews({
    required String processRequirementId,
  }) async {
    try {
      final rows = await _client
          .from('document_reviews')
          .select(_reviewColumns)
          .eq('process_requirement_id', processRequirementId.trim())
          .order('reviewed_at', ascending: false);

      return rows.map(DocumentReviewRecord.fromMap).toList(growable: false);
    } on ReviewFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  @override
  Future<PaginatedResult<ProcessAuditTimelineEvent>> fetchProcessAuditTimeline({
    required String processId,
    int page = 0,
    int pageSize = kDefaultReviewPageSize,
    bool oldestFirst = false,
  }) async {
    final cleanProcessId = processId.trim();
    final safePage = page < 0 ? 0 : page;
    final safePageSize = pageSize.clamp(1, 100);
    final from = safePage * safePageSize;
    final to = from + safePageSize - 1;

    if (cleanProcessId.isEmpty) {
      return PaginatedResult<ProcessAuditTimelineEvent>(
        items: const <ProcessAuditTimelineEvent>[],
        totalCount: 0,
        page: safePage,
        pageSize: safePageSize,
      );
    }

    try {
      final response = await _client
          .from('process_audit_timeline_v')
          .select(_timelineSelectColumns)
          .eq('process_id', cleanProcessId)
          .order('occurred_at', ascending: oldestFirst)
          .order('event_id', ascending: oldestFirst)
          .range(from, to)
          .count(CountOption.exact);

      final events = response.data
          .map(ProcessAuditTimelineEvent.fromMap)
          .toList(growable: false);

      return PaginatedResult<ProcessAuditTimelineEvent>(
        items: events,
        totalCount: response.count,
        page: safePage,
        pageSize: safePageSize,
      );
    } on ReviewFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  static String sanitizeSearchTerm(String raw) {
    return raw
        .replaceAll(RegExp(r'[,()*%\\"\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static ReviewFailure mapError(Object error) {
    if (error is ReviewFailure) {
      return error;
    }

    if (error is TimeoutException || error is http.RequestAbortedException) {
      return const ReviewFailure(
        'Tempo limite esgotado antes da confirmação do servidor. Você pode tentar novamente com segurança sem duplicar a revisão.',
        code: 'timeout',
        isAmbiguousNetworkOrTimeout: true,
      );
    }

    if (error is FunctionsFetchException) {
      return const ReviewFailure(
        'Falha de conexão com o servidor ao baixar o documento PDF. Verifique sua rede e tente novamente.',
        code: 'network_error',
        isAmbiguousNetworkOrTimeout: true,
      );
    }

    if (error is FunctionException) {
      return _mapFunctionException(error);
    }

    if (error is PostgrestException) {
      return _mapPostgrestException(error);
    }

    if (error is StorageException) {
      return _mapStorageException(error);
    }

    if (error is AuthException) {
      return const ReviewFailure(
        'Sua sessão expirou ou é inválida. Entre novamente.',
        code: 'unauthorized_session',
        httpStatus: 401,
        isUnauthorized: true,
      );
    }

    if (error is http.ClientException) {
      return const ReviewFailure(
        'Conexão interrompida ao comunicar com o servidor. Você pode tentar novamente sem duplicar a operação.',
        code: 'network_error',
        isAmbiguousNetworkOrTimeout: true,
      );
    }

    final lower = error.toString().toLowerCase();
    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('network')) {
      return const ReviewFailure(
        'Falha de conexão com o servidor. Verifique sua rede e tente novamente.',
        code: 'network_error',
        isAmbiguousNetworkOrTimeout: true,
      );
    }

    return const ReviewFailure(
      'Não foi possível concluir a operação de revisão no momento. Tente novamente.',
      code: 'unexpected_error',
    );
  }

  static ReviewFailure _mapPostgrestException(PostgrestException error) {
    final sqlState = (error.code ?? '').trim().toUpperCase();
    final tagMatch = _errTagRegex.firstMatch(error.message);
    final errTag = tagMatch?.group(1);

    if (sqlState == 'PGRST301' || errTag == 'unauthorized_session') {
      return const ReviewFailure(
        'Sua sessão expirou ou é inválida. Entre novamente.',
        code: 'unauthorized_session',
        httpStatus: 401,
        isUnauthorized: true,
      );
    }

    switch (errTag) {
      case 'forbidden_role':
        return const ReviewFailure(
          'Operação permitida exclusivamente para perfil de revisor ativo.',
          code: 'forbidden_role',
          httpStatus: 403,
          isUnauthorized: true,
          isForbiddenRole: true,
        );
      case 'forbidden_scope':
        return const ReviewFailure(
          'Atribuição de escopo ausente ou revogada para este processo. A fila foi atualizada.',
          code: 'forbidden_scope',
          httpStatus: 403,
          isUnauthorized: true,
          isForbiddenScope: true,
          shouldReloadQueue: true,
        );
      case 'process_cancelled':
        return const ReviewFailure(
          'Este processo está cancelado e não permite decisão documental.',
          code: 'process_cancelled',
          httpStatus: 403,
          isProcessCancelled: true,
          shouldReloadQueue: true,
        );
      case 'invalid_input':
        return const ReviewFailure(
          'Selecione uma submissão documental válida antes de decidir.',
          code: 'invalid_input',
          httpStatus: 400,
          isValidationError: true,
        );
      case 'invalid_decision':
        return const ReviewFailure(
          'Decisão inválida: escolha entre aprovar ou solicitar correção.',
          code: 'invalid_decision',
          httpStatus: 400,
          isValidationError: true,
        );
      case 'missing_correction_reason':
        return const ReviewFailure(
          'Informe a justificativa obrigatória para solicitar correção.',
          code: 'missing_correction_reason',
          httpStatus: 400,
          isValidationError: true,
        );
      case 'reason_too_long':
        return const ReviewFailure(
          'A justificativa da revisão excede o limite de 2000 caracteres.',
          code: 'reason_too_long',
          httpStatus: 400,
          isValidationError: true,
        );
      case 'submission_not_found':
        return const ReviewFailure(
          'Submissão documental não encontrada ou não mais disponível na fila.',
          code: 'submission_not_found',
          httpStatus: 404,
          isNotFound: true,
          shouldReloadQueue: true,
        );
      case 'submission_already_reviewed':
        return const ReviewFailure(
          'Esta versão do documento já recebeu decisão de revisão. A fila foi atualizada.',
          code: 'submission_already_reviewed',
          httpStatus: 409,
          isConflict: true,
          isAlreadyReviewed: true,
          shouldReloadQueue: true,
        );
      case 'obsolete_submission_version':
        return const ReviewFailure(
          'Esta submissão está obsoleta: apenas a versão vigente pode ser revisada. A fila foi atualizada.',
          code: 'obsolete_submission_version',
          httpStatus: 409,
          isConflict: true,
          isObsoleteVersion: true,
          shouldReloadQueue: true,
        );
      case 'requirement_status_conflict':
        return const ReviewFailure(
          'O requisito ou submissão não está mais em análise. A fila foi atualizada.',
          code: 'requirement_status_conflict',
          httpStatus: 409,
          isConflict: true,
          shouldReloadQueue: true,
        );
      case 'idempotency_mismatch':
        return const ReviewFailure(
          'A chave de confirmação anterior pertence a outra tentativa. O estado foi atualizado para nova submissão.',
          code: 'idempotency_mismatch',
          httpStatus: 409,
          isConflict: true,
          isIdempotencyMismatch: true,
          shouldReloadQueue: true,
        );
    }

    switch (sqlState) {
      case '42501':
        return const ReviewFailure(
          'Acesso não autorizado ou atribuição de escopo revogada.',
          code: '42501',
          httpStatus: 403,
          isUnauthorized: true,
          isForbiddenScope: true,
        );
      case '22023':
        return const ReviewFailure(
          'Dados inválidos para registro da revisão. Verifique os campos informados.',
          code: '22023',
          httpStatus: 400,
          isValidationError: true,
        );
      case 'P0002':
        return const ReviewFailure(
          'Submissão documental não encontrada ou indisponível.',
          code: 'submission_not_found',
          httpStatus: 404,
          isNotFound: true,
          shouldReloadQueue: true,
        );
      case '23505':
        return const ReviewFailure(
          'Conflito de concorrência: esta versão já foi revisada ou alterada. A fila foi atualizada.',
          code: 'submission_already_reviewed',
          httpStatus: 409,
          isConflict: true,
          isAlreadyReviewed: true,
          shouldReloadQueue: true,
        );
      default:
        return const ReviewFailure(
          'Não foi possível processar a operação de revisão no servidor. Tente novamente.',
          code: 'server_error',
        );
    }
  }

  static ReviewFailure _mapStorageException(StorageException error) {
    final parsedStatus = int.tryParse(error.statusCode ?? '');
    if (parsedStatus == 401) {
      return const ReviewFailure(
        'Sua sessão expirou ou foi encerrada. Entre novamente para visualizar o PDF.',
        code: 'unauthorized_session',
        httpStatus: 401,
        isUnauthorized: true,
      );
    }
    if (parsedStatus == 403) {
      return const ReviewFailure(
        'Acesso ao PDF negado: escopo não atribuído ou atribuição revogada.',
        code: 'forbidden_scope',
        httpStatus: 403,
        isUnauthorized: true,
        isForbiddenScope: true,
        shouldReloadQueue: true,
      );
    }
    if (parsedStatus == 400 || parsedStatus == 404) {
      return ReviewFailure(
        'Arquivo PDF não encontrado ou indisponível no armazenamento privado.',
        code: 'pdf_not_found',
        httpStatus: parsedStatus ?? 404,
        isNotFound: true,
      );
    }
    return ReviewFailure(
      'Não foi possível baixar o PDF autenticado do armazenamento privado.',
      code: 'storage_download_failed',
      httpStatus: parsedStatus,
    );
  }

  static ReviewFailure _mapFunctionException(FunctionException error) {
    final status = error.status;
    final detailsMap = _asStringKeyedMap(error.details);
    final errorObj = _asStringKeyedMap(detailsMap?['error']);
    final backendCode = errorObj?['code'] as String?;

    switch (status) {
      case 400:
        return ReviewFailure(
          'Identificador de submissão ou parâmetro inválido para download do PDF.',
          code: backendCode ?? 'invalid_submission_id',
          httpStatus: 400,
          isValidationError: true,
        );
      case 401:
        return ReviewFailure(
          'Sua sessão expirou ou foi encerrada. Entre novamente para visualizar o PDF.',
          code: backendCode ?? 'unauthorized_session',
          httpStatus: 401,
          isUnauthorized: true,
        );
      case 403:
        return ReviewFailure(
          'Acesso ao PDF negado: perfil inativo, escopo não atribuído ou atribuição revogada.',
          code: backendCode ?? 'forbidden_scope',
          httpStatus: 403,
          isUnauthorized: true,
          isForbiddenScope: true,
          shouldReloadQueue: true,
        );
      case 404:
        return ReviewFailure(
          'Submissão documental não encontrada ou acesso negado (escopo não atribuído ou atribuição revogada).',
          code: backendCode ?? 'submission_not_found',
          httpStatus: 404,
          isNotFound: true,
          isForbiddenScope: true,
          shouldReloadQueue: true,
        );
      case 413:
        return ReviewFailure(
          'O documento PDF excede o limite máximo permitido de 5 MiB.',
          code: backendCode ?? 'file_too_large',
          httpStatus: 413,
        );
      case 502:
      case 504:
        return ReviewFailure(
          'Instabilidade temporária ao obter o PDF no servidor. Você pode tentar novamente.',
          code: backendCode ?? 'storage_fetch_failed',
          httpStatus: status,
          isAmbiguousNetworkOrTimeout: true,
        );
      default:
        return ReviewFailure(
          'Não foi possível baixar o PDF autenticado pelo gateway privado.',
          code: backendCode ?? 'download_authorization_error',
          httpStatus: status,
        );
    }
  }

  static Map<String, dynamic>? _asStringKeyedMap(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }
}
