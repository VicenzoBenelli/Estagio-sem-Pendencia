import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart'
    as http
    show MultipartFile, MediaType, RequestAbortedException, ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/document_models.dart';
import '../domain/document_repository.dart';
import '../domain/process_models.dart';

class SupabaseDocumentRepository implements DocumentRepository {
  const SupabaseDocumentRepository(
    this._client, {
    this.uploadTimeout = const Duration(seconds: 30),
    this.downloadTimeout = const Duration(seconds: 30),
  });

  final SupabaseClient _client;
  final Duration uploadTimeout;
  final Duration downloadTimeout;

  static const String _submissionColumns =
      'id, process_id, process_requirement_id, submitted_by, version, '
      'storage_bucket, storage_path, original_filename, mime_type, '
      'size_bytes, sha256_checksum, idempotency_key, status, submitted_at, created_at';

  static const String _reviewColumns =
      'id, process_id, process_requirement_id, submission_id, reviewer_id, '
      'decision, reason, reviewed_at';

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

  @override
  Future<Uint8List> downloadSubmissionBytes({
    required String storageBucket,
    required String storagePath,
  }) async {
    final normalizedBucket = storageBucket.trim();
    final normalizedPath = storagePath.trim();
    if (normalizedBucket != kPrivateDocumentsBucket ||
        normalizedPath.isEmpty ||
        normalizedPath.contains('..') ||
        normalizedPath.startsWith('/')) {
      throw const DocumentFailure(
        'Referência de documento inválida ou não autorizada.',
        code: 'invalid_storage_reference',
        httpStatus: 400,
      );
    }

    try {
      final bytes = await _client.storage
          .from(normalizedBucket)
          .download(normalizedPath)
          .timeout(downloadTimeout);

      if (bytes.isEmpty) {
        throw const DocumentFailure(
          'O arquivo retornado pelo armazenamento privado está vazio.',
          code: 'empty_downloaded_file',
        );
      }
      return bytes;
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
          _ => 'Parâmetros ou arquivo inválidos para envio. Verifique o PDF selecionado.',
        };
        return DocumentFailure(msg, code: backendCode, httpStatus: 400);
      case 401:
        return DocumentFailure(
          'Sua sessão expirou ou é inválida. Entre novamente para enviar documentos.',
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
          _ => 'Você não tem permissão para enviar arquivo neste requisito.',
        };
        return DocumentFailure(
          msg,
          code: backendCode ?? 'forbidden',
          httpStatus: 403,
        );
      case 404:
        return DocumentFailure(
          'Requisito não encontrado ou inacessível para sua conta.',
          code: backendCode ?? 'not_found',
          httpStatus: 404,
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
