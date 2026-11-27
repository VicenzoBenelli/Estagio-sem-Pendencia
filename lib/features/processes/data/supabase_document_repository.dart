import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart'
    as http
    show
        AbortableRequest,
        Client,
        ClientException,
        MediaType,
        MultipartFile,
        RequestAbortedException,
        StreamedResponse;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/document_models.dart';
import '../domain/document_repository.dart';
import '../domain/process_models.dart';

const int _kMaxGatewayErrorBodyBytes = 64 * 1024;

class GatewayDownloadStreamMetrics {
  const GatewayDownloadStreamMetrics({
    required this.chunksConsumed,
    required this.totalBytesReceived,
    required this.maxBytesAccumulated,
    required this.retainedBytesAfterCancel,
    required this.subscriptionCancelled,
    required this.rejectedByContentLength,
  });

  final int chunksConsumed;
  final int totalBytesReceived;
  final int maxBytesAccumulated;
  final int retainedBytesAfterCancel;
  final bool subscriptionCancelled;
  final bool rejectedByContentLength;
}

class SupabaseDocumentRepository implements DocumentRepository {
  const SupabaseDocumentRepository(
    this._client, {
    this.uploadTimeout = const Duration(seconds: 30),
    this.downloadTimeout = const Duration(seconds: 30),
    @visibleForTesting this.debugOnDownloadMetrics,
  });

  final SupabaseClient _client;
  final Duration uploadTimeout;
  final Duration downloadTimeout;
  @visibleForTesting
  final void Function(GatewayDownloadStreamMetrics metrics)?
  debugOnDownloadMetrics;

  static const String _submissionColumns =
      'id, process_id, process_requirement_id, submitted_by, version, '
      'storage_bucket, storage_path, original_filename, mime_type, '
      'size_bytes, sha256_checksum, idempotency_key, status, submitted_at, created_at';

  static const String _reviewColumns =
      'id, process_id, process_requirement_id, submission_id, reviewer_id, '
      'decision, reason, reviewed_at';

  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  @override
  Future<SubmitPdfOutcome> submitRequirementPdf({
    required String processRequirementId,
    required SelectedPdfFile file,
    required String idempotencyKey,
  }) async {
    final safeFilename = file.basename;
    if (safeFilename.isEmpty) {
      throw const DocumentFailure(
        'Nome de arquivo inválido para envio.',
        code: 'invalid_file_extension',
        httpStatus: 400,
      );
    }

    final abortCompleter = Completer<void>();

    try {
      final response = await _client.functions
          .invoke(
            'submit-requirement-pdf',
            body: <String, String>{
              'process_requirement_id': processRequirementId.trim(),
              'idempotency_key': idempotencyKey.trim(),
            },
            files: <http.MultipartFile>[
              http.MultipartFile.fromBytes(
                'file',
                file.bytes,
                filename: safeFilename,
                contentType: http.MediaType('application', 'pdf'),
              ),
            ],
            abortSignal: abortCompleter.future,
          )
          .timeout(
            uploadTimeout,
            onTimeout: () {
              if (!abortCompleter.isCompleted) {
                abortCompleter.complete();
              }
              throw TimeoutException(
                'Tempo limite excedido ao enviar o PDF.',
                uploadTimeout,
              );
            },
          );

      final data = _asStringKeyedMap(response.data);
      if (data == null || data['ok'] != true) {
        throw const DocumentFailure(
          'Resposta inesperada do servidor ao registrar o envio documental.',
          code: 'invalid_server_response',
        );
      }

      final submissionMap = _asStringKeyedMap(data['submission']);
      final requirementMap = _asStringKeyedMap(data['requirement']);
      if (submissionMap == null || requirementMap == null) {
        throw const DocumentFailure(
          'Resposta incompleta do servidor ao confirmar a submissão.',
          code: 'incomplete_server_response',
        );
      }

      final submission = DocumentSubmissionRecord.fromMap(submissionMap);
      final reqStatus = RequirementStatus.fromDatabase(
        requirementMap['status'] as String?,
      );
      final currentVersion = _parseInt(
        requirementMap['current_version'],
        fallback: submission.version,
      );
      final currentSubmissionId =
          (requirementMap['current_submission_id'] as String?) ?? submission.id;

      // Garantir que um upload confirmado pelo servidor reflita análise, nunca aprovação automática.
      if (reqStatus == RequirementStatus.approved ||
          submission.status == SubmissionStatus.approved) {
        throw const DocumentFailure(
          'Estado inconsistente retornado pelo servidor após o envio.',
          code: 'unexpected_status_after_upload',
        );
      }

      final idempotentReplay =
          response.status == 200 || (data['idempotent_replay'] == true);

      return SubmitPdfOutcome(
        submission: submission,
        idempotentReplay: idempotentReplay,
        requirementStatus: reqStatus,
        currentVersion: currentVersion,
        currentSubmissionId: currentSubmissionId,
      );
    } on DocumentFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  @override
  Future<DocumentSubmissionRecord?> findSubmissionByIdempotencyKey({
    required String processRequirementId,
    required String idempotencyKey,
  }) async {
    try {
      final row = await _client
          .from('document_submissions')
          .select(_submissionColumns)
          .eq('process_requirement_id', processRequirementId)
          .eq('idempotency_key', idempotencyKey)
          .maybeSingle();

      if (row == null) {
        return null;
      }
      return DocumentSubmissionRecord.fromMap(row);
    } on DocumentFailure {
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
          .eq('process_requirement_id', processRequirementId)
          .order('version', ascending: false);

      final items = rows
          .map(DocumentSubmissionRecord.fromMap)
          .toList(growable: false);
      items.sort((a, b) => b.version.compareTo(a.version));
      return items;
    } on DocumentFailure {
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
          .eq('process_requirement_id', processRequirementId)
          .order('reviewed_at', ascending: false);

      return rows.map(DocumentReviewRecord.fromMap).toList(growable: false);
    } on DocumentFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  static bool isValidUuid(String value) => _uuidRegex.hasMatch(value);

  @override
  Future<Uint8List> downloadSubmissionBytes({
    required String submissionId,
  }) async {
    try {
      return await downloadPrivateSubmissionPdfFromGateway(
        client: _client,
        submissionId: submissionId,
        timeout: downloadTimeout,
        debugOnDownloadMetrics: debugOnDownloadMetrics,
        onInvalidSubmissionId: () => const DocumentFailure(
          'Identificador de submissão inválido ou não autorizado.',
          code: 'invalid_submission_id',
          httpStatus: 400,
        ),
        onInvalidContentType: () => const DocumentFailure(
          'Resposta inesperada do servidor ao baixar o documento PDF.',
          code: 'invalid_pdf_content_type',
        ),
        onEmptyFile: () => const DocumentFailure(
          'O arquivo retornado pelo armazenamento privado está vazio.',
          code: 'empty_downloaded_file',
        ),
        onFileTooLarge: () => const DocumentFailure(
          'O arquivo PDF ultrapassa o limite máximo permitido de 5 MiB.',
          code: 'file_too_large',
          httpStatus: 413,
        ),
        onInvalidPdfSignature: () => const DocumentFailure(
          'Os bytes retornados não possuem assinatura válida de documento PDF (%PDF-).',
          code: 'invalid_pdf_signature',
        ),
      );
    } on DocumentFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  static DocumentFailure mapError(Object error) {
    if (error is DocumentFailure) {
      return error;
    }

    if (error is TimeoutException || error is http.RequestAbortedException) {
      return const DocumentFailure(
        'Tempo esgotado antes da confirmação do servidor. Verifique o histórico ou tente novamente sem gerar envio duplicado.',
        code: 'timeout',
        isAmbiguousNetworkOrTimeout: true,
      );
    }

    if (error is FunctionsFetchException) {
      return const DocumentFailure(
        'Falha de conexão com o servidor ao enviar o documento. Verifique sua rede e tente novamente.',
        code: 'network_error',
        isAmbiguousNetworkOrTimeout: true,
      );
    }

    if (error is FunctionException) {
      return _mapFunctionException(error);
    }

    if (error is StorageException) {
      final parsedStatus = int.tryParse(error.statusCode ?? '');
      if (parsedStatus == 401) {
        return const DocumentFailure(
          'Sua sessão expirou ou é inválida. Entre novamente.',
          code: '401',
          httpStatus: 401,
          isUnauthorized: true,
        );
      }
      if (parsedStatus == 403 || parsedStatus == 400 || parsedStatus == 404) {
        return DocumentFailure(
          'Documento indisponível ou sem permissão de acesso.',
          code: error.error ?? error.statusCode,
          httpStatus: parsedStatus,
          isUnauthorized: parsedStatus == 403,
        );
      }
      return DocumentFailure(
        'Não foi possível baixar o documento do armazenamento privado.',
        code: error.error ?? error.statusCode,
        httpStatus: parsedStatus,
      );
    }

    if (error is PostgrestException) {
      final code = (error.code ?? '').trim().toUpperCase();
      if (code == '42501' || code == 'PGRST301') {
        return const DocumentFailure(
          'Acesso não autorizado ou sessão expirada. Entre novamente.',
          code: '42501',
          httpStatus: 401,
          isUnauthorized: true,
        );
      }
      if (code == 'P0002') {
        return const DocumentFailure(
          'Submissão ou requisito não encontrado.',
          code: 'P0002',
          httpStatus: 404,
        );
      }
      return const DocumentFailure(
        'Não foi possível consultar o histórico documental no servidor.',
      );
    }

    if (error is AuthException) {
      return const DocumentFailure(
        'Sua sessão expirou ou é inválida. Entre novamente.',
        code: '401',
        httpStatus: 401,
        isUnauthorized: true,
      );
    }

    if (error is http.ClientException) {
      return const DocumentFailure(
        'Conexão interrompida ao comunicar com o servidor. Tente novamente.',
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
      return const DocumentFailure(
        'Falha de conexão com o servidor. Verifique sua rede e tente novamente.',
        code: 'network_error',
        isAmbiguousNetworkOrTimeout: true,
      );
    }

    return const DocumentFailure(
      'Não foi possível concluir a operação documental no momento. Tente novamente.',
    );
  }

  static DocumentFailure _mapFunctionException(FunctionException error) {
    final status = error.status;
    final detailsMap = _asStringKeyedMap(error.details);
    final errorObj = _asStringKeyedMap(detailsMap?['error']);
    final backendCode = errorObj?['code'] as String?;

    switch (status) {
      case 400:
        final msg = switch (backendCode) {
          'empty_file' => 'O arquivo PDF enviado está vazio.',
          'invalid_file_extension' =>
            'Nome de arquivo inválido; apenas documentos .pdf são aceitos.',
          'invalid_submission_id' =>
            'Identificador de submissão documental inválido.',
          'unsupported_destination_parameter' ||
          'unexpected_request_parameter' =>
            'Parâmetros de destino não são aceitos pelo servidor.',
          _ => 'Parâmetros ou arquivo inválidos para envio. Verifique o PDF selecionado.',
        };
        return DocumentFailure(msg, code: backendCode, httpStatus: 400);
      case 401:
        return DocumentFailure(
          'Sua sessão expirou ou é inválida. Entre novamente para acessar ou enviar documentos.',
          code: backendCode ?? 'unauthorized',
          httpStatus: 401,
          isUnauthorized: true,
        );
      case 403:
        final msg = switch (backendCode) {
          'process_cancelled' =>
            'Processo cancelado não aceita novas submissões.',
          'forbidden_role' =>
            'Apenas estudantes com perfil ativo podem enviar documentos.',
          'forbidden_inactive_profile' =>
            'Seu perfil está inativo ou sem permissão para acessar documentos.',
          _ => 'Você não tem permissão para acessar ou enviar arquivo neste requisito.',
        };
        return DocumentFailure(
          msg,
          code: backendCode ?? 'forbidden',
          httpStatus: 403,
          isUnauthorized: true,
        );
      case 404:
        final msg = switch (backendCode) {
          'submission_not_found' || 'storage_object_missing' =>
            'Submissão documental não encontrada ou acesso indisponível.',
          _ => 'Requisito não encontrado ou inacessível para sua conta.',
        };
        return DocumentFailure(
          msg,
          code: backendCode ?? 'not_found',
          httpStatus: 404,
        );
      case 405:
        return DocumentFailure(
          'Método HTTP não permitido para esta operação documental.',
          code: backendCode ?? 'method_not_allowed',
          httpStatus: 405,
        );
      case 409:
        final msg = switch (backendCode) {
          'idempotency_mismatch' => 'Esta tentativa já foi vinculada a outro arquivo. Selecione o PDF novamente para reenviar.',
          'submission_in_progress' => 'Um envio para este requisito já está em processamento. Aguarde e atualize o checklist.',
          _ => 'Este requisito já possui submissão em análise ou foi alterado. Atualize o checklist antes de tentar novamente.',
        };
        return DocumentFailure(
          msg,
          code: backendCode ?? 'conflict',
          httpStatus: 409,
          isConflict: true,
        );
      case 413:
        return DocumentFailure(
          'O arquivo PDF ultrapassa o limite máximo permitido de 5 MiB.',
          code: backendCode ?? 'file_too_large',
          httpStatus: 413,
        );
      case 415:
        return DocumentFailure(
          'Formato não suportado. Envie apenas arquivo com MIME application/pdf.',
          code: backendCode ?? 'unsupported_media_type',
          httpStatus: 415,
        );
      case 422:
        return DocumentFailure(
          'O arquivo não corresponde a um documento PDF válido ou está corrompido/truncado.',
          code: backendCode ?? 'invalid_pdf',
          httpStatus: 422,
        );
      case 502:
        final isGatewayAmbiguous = backendCode != 'storage_upload_failed';
        return DocumentFailure(
          isGatewayAmbiguous
              ? 'Instabilidade temporária na comunicação com o servidor. Você pode tentar novamente.'
              : 'Não foi possível gravar o PDF no armazenamento privado. Tente novamente.',
          code: backendCode ?? 'storage_upload_failed',
          httpStatus: 502,
          isAmbiguousNetworkOrTimeout: isGatewayAmbiguous,
        );
      case 504:
        return const DocumentFailure(
          'Tempo esgotado no servidor antes da resposta final. Verifique ou tente novamente.',
          code: 'gateway_timeout',
          httpStatus: 504,
          isAmbiguousNetworkOrTimeout: true,
        );
      default:
        return DocumentFailure(
          'Erro interno no servidor ao processar o documento. Tente novamente.',
          code: backendCode ?? 'server_error',
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

  static int _parseInt(Object? raw, {int fallback = 0}) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }
}

Future<Uint8List> downloadPrivateSubmissionPdfFromGateway({
  required SupabaseClient client,
  required String submissionId,
  required Duration timeout,
  required Exception Function() onInvalidSubmissionId,
  required Exception Function() onInvalidContentType,
  required Exception Function() onEmptyFile,
  required Exception Function() onFileTooLarge,
  required Exception Function() onInvalidPdfSignature,
  int maxBytes = kMaxPdfSizeBytes,
  void Function(GatewayDownloadStreamMetrics metrics)? debugOnDownloadMetrics,
}) async {
  final cleanSubmissionId = submissionId.trim();
  if (cleanSubmissionId.isEmpty ||
      !SupabaseDocumentRepository.isValidUuid(cleanSubmissionId)) {
    throw onInvalidSubmissionId();
  }

  final restUrl = client.rest.url.replaceAll(RegExp(r'/+$'), '');
  final baseUrl = restUrl.endsWith('/rest/v1')
      ? restUrl.substring(0, restUrl.length - '/rest/v1'.length)
      : restUrl;
  final uri = Uri.parse('$baseUrl/functions/v1/download-submission-pdf');

  final abortCompleter = Completer<void>();
  final request = http.AbortableRequest(
    'POST',
    uri,
    abortTrigger: abortCompleter.future,
  );
  final clientInfo =
      client.functions.headers['X-Client-Info'] ??
      client.functions.headers['x-client-info'];
  if (clientInfo != null && clientInfo.isNotEmpty) {
    request.headers['X-Client-Info'] = clientInfo;
  }
  final hasActiveSession =
      (client.auth.currentSession?.accessToken ?? '').isNotEmpty;
  if (!hasActiveSession) {
    final explicitAuth =
        client.functions.headers['Authorization'] ??
        client.functions.headers['authorization'] ??
        client.headers['Authorization'] ??
        client.headers['authorization'];
    if (explicitAuth != null && explicitAuth.isNotEmpty) {
      request.headers['Authorization'] = explicitAuth;
    }
  }
  request.headers['Content-Type'] = 'application/json';
  request.headers['Accept'] = 'application/pdf, application/json';
  request.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate';
  request.headers['Pragma'] = 'no-cache';
  request.bodyBytes = utf8.encode(
    jsonEncode(<String, String>{
      'submission_id': cleanSubmissionId.toLowerCase(),
    }),
  );

  final httpClient = client.rest.httpClient ?? http.Client();
  final streamedResponse = await httpClient
      .send(request)
      .timeout(
        timeout,
        onTimeout: () {
          _abortDownload(abortCompleter);
          throw TimeoutException(
            'Tempo limite excedido ao solicitar o download do PDF.',
            timeout,
          );
        },
      );

  final status = streamedResponse.statusCode;
  final declaredContentLength = _extractDeclaredContentLength(streamedResponse);
  if (status < 200 || status >= 300) {
    dynamic errorDetails;
    if (declaredContentLength != null &&
        declaredContentLength > _kMaxGatewayErrorBodyBytes) {
      await _cancelResponseStream(streamedResponse.stream, abortCompleter);
    } else {
      final errorBytes = await _readBoundedResponseStream(
        streamedResponse.stream,
        maxBytes: _kMaxGatewayErrorBodyBytes,
        timeout: timeout,
        abortCompleter: abortCompleter,
        onLimitExceeded: onFileTooLarge,
        allowTruncationOnLimit: true,
      );
      if (errorBytes.isNotEmpty) {
        final text = utf8.decode(errorBytes, allowMalformed: true);
        try {
          errorDetails = jsonDecode(text);
        } catch (_) {
          errorDetails = text;
        }
      }
    }
    throw FunctionException(
      status: status,
      details: errorDetails,
      reasonPhrase: streamedResponse.reasonPhrase,
    );
  }

  final contentType = _extractHeaderCaseInsensitive(
    streamedResponse.headers,
    'content-type',
  ).toLowerCase();
  if (contentType.contains('application/json')) {
    await _cancelResponseStream(streamedResponse.stream, abortCompleter);
    debugOnDownloadMetrics?.call(
      const GatewayDownloadStreamMetrics(
        chunksConsumed: 0,
        totalBytesReceived: 0,
        maxBytesAccumulated: 0,
        retainedBytesAfterCancel: 0,
        subscriptionCancelled: true,
        rejectedByContentLength: false,
      ),
    );
    throw onInvalidContentType();
  }

  if (declaredContentLength != null && declaredContentLength > maxBytes) {
    await _cancelResponseStream(streamedResponse.stream, abortCompleter);
    debugOnDownloadMetrics?.call(
      const GatewayDownloadStreamMetrics(
        chunksConsumed: 0,
        totalBytesReceived: 0,
        maxBytesAccumulated: 0,
        retainedBytesAfterCancel: 0,
        subscriptionCancelled: true,
        rejectedByContentLength: true,
      ),
    );
    throw onFileTooLarge();
  }

  final bytes = await _readBoundedResponseStream(
    streamedResponse.stream,
    maxBytes: maxBytes,
    timeout: timeout,
    abortCompleter: abortCompleter,
    onLimitExceeded: onFileTooLarge,
    onMetrics: debugOnDownloadMetrics,
  );

  if (bytes.isEmpty) {
    throw onEmptyFile();
  }

  if (!PdfPreliminaryValidation.hasPdfHeader(bytes)) {
    throw onInvalidPdfSignature();
  }

  return bytes;
}

String _extractHeaderCaseInsensitive(
  Map<String, String> headers,
  String targetKeyLower,
) {
  final direct = headers[targetKeyLower];
  if (direct != null) {
    return direct;
  }
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == targetKeyLower) {
      return entry.value;
    }
  }
  return '';
}

int? _extractDeclaredContentLength(http.StreamedResponse response) {
  int? headerLength;
  final rawHeader = _extractHeaderCaseInsensitive(
    response.headers,
    'content-length',
  ).trim();
  if (rawHeader.isNotEmpty) {
    final parsed = int.tryParse(rawHeader);
    if (parsed != null && parsed >= 0) {
      headerLength = parsed;
    }
  }
  final direct = response.contentLength;
  if (direct != null && direct >= 0) {
    if (headerLength != null && headerLength > direct) {
      return headerLength;
    }
    return direct;
  }
  return headerLength;
}

void _abortDownload(Completer<void> abortCompleter) {
  if (!abortCompleter.isCompleted) {
    abortCompleter.complete();
  }
}

Future<void> _cancelResponseStream(
  Stream<List<int>> stream,
  Completer<void> abortCompleter,
) async {
  try {
    final sub = stream.listen(
      (_) {},
      onError: (Object _) {},
      cancelOnError: true,
    );
    final cancellation = sub.cancel();
    _abortDownload(abortCompleter);
    await cancellation.timeout(
      const Duration(milliseconds: 50),
      onTimeout: () {},
    );
  } catch (_) {
    _abortDownload(abortCompleter);
  }
}

Future<Uint8List> _readBoundedResponseStream(
  Stream<List<int>> stream, {
  required int maxBytes,
  required Duration timeout,
  required Completer<void> abortCompleter,
  required Exception Function() onLimitExceeded,
  bool allowTruncationOnLimit = false,
  void Function(GatewayDownloadStreamMetrics metrics)? onMetrics,
}) async {
  final builder = BytesBuilder(copy: false);
  final completer = Completer<Uint8List>();
  StreamSubscription<List<int>>? subscription;
  var chunksConsumed = 0;
  var totalReceivedBytes = 0;
  var maxBytesAccumulated = 0;
  var subscriptionCancelled = false;
  var settled = false;
  var shouldCancelAfterListen = false;

  void emitMetrics() {
    onMetrics?.call(
      GatewayDownloadStreamMetrics(
        chunksConsumed: chunksConsumed,
        totalBytesReceived: totalReceivedBytes,
        maxBytesAccumulated: maxBytesAccumulated,
        retainedBytesAfterCancel: builder.length,
        subscriptionCancelled: subscriptionCancelled,
        rejectedByContentLength: false,
      ),
    );
  }

  Future<void> cancelSubscriptionIfActive() async {
    final sub = subscription;
    subscription = null;
    if (sub != null) {
      subscriptionCancelled = true;
      try {
        final cancellation = sub.cancel();
        _abortDownload(abortCompleter);
        await cancellation.timeout(
          const Duration(milliseconds: 50),
          onTimeout: () {},
        );
      } catch (_) {
        _abortDownload(abortCompleter);
      }
    }
  }

  Future<void> cancelAndFail(Object error, [StackTrace? stackTrace]) async {
    await cancelSubscriptionIfActive();
    emitMetrics();
    if (!completer.isCompleted) {
      if (stackTrace != null) {
        completer.completeError(error, stackTrace);
      } else {
        completer.completeError(error);
      }
    }
  }

  Future<void> cancelAndComplete(Uint8List bytes) async {
    await cancelSubscriptionIfActive();
    emitMetrics();
    if (!completer.isCompleted) {
      completer.complete(bytes);
    }
  }

  subscription = stream.listen(
    (List<int> chunk) {
      if (settled || chunk.isEmpty) {
        return;
      }
      chunksConsumed++;
      totalReceivedBytes += chunk.length;
      if (totalReceivedBytes > maxBytes) {
        settled = true;
        if (allowTruncationOnLimit) {
          final truncated = builder.takeBytes();
          if (subscription != null) {
            unawaited(cancelAndComplete(truncated));
          } else {
            subscriptionCancelled = true;
            shouldCancelAfterListen = true;
            emitMetrics();
            if (!completer.isCompleted) {
              completer.complete(truncated);
            }
          }
          return;
        }
        // Não acumula o bloco excedente e libera imediatamente os bytes anteriores.
        builder.clear();
        if (subscription != null) {
          unawaited(cancelAndFail(onLimitExceeded()));
        } else {
          subscriptionCancelled = true;
          shouldCancelAfterListen = true;
        }
        return;
      }
      builder.add(chunk);
      if (builder.length > maxBytesAccumulated) {
        maxBytesAccumulated = builder.length;
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (settled) {
        return;
      }
      settled = true;
      builder.clear();
      subscription = null;
      emitMetrics();
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    },
    onDone: () {
      if (settled) {
        return;
      }
      settled = true;
      subscription = null;
      final bytes = builder.takeBytes();
      emitMetrics();
      if (!completer.isCompleted) {
        completer.complete(bytes);
      }
    },
    cancelOnError: true,
  );

  if (shouldCancelAfterListen) {
    if (allowTruncationOnLimit) {
      await cancelSubscriptionIfActive();
    } else {
      await cancelAndFail(onLimitExceeded());
    }
  }

  try {
    return await completer.future.timeout(
      timeout,
      onTimeout: () async {
        settled = true;
        builder.clear();
        await cancelSubscriptionIfActive();
        _abortDownload(abortCompleter);
        emitMetrics();
        throw TimeoutException(
          'Tempo limite excedido durante a leitura do PDF.',
          timeout,
        );
      },
    );
  } finally {
    if (subscription != null) {
      await cancelSubscriptionIfActive();
    }
  }
}
