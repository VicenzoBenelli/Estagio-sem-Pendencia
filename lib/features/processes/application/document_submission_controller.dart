import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../auth/domain/user_profile.dart';
import '../data/supabase_document_repository.dart';
import '../domain/document_models.dart';
import '../domain/document_repository.dart';
import '../domain/process_models.dart';

class DocumentSubmissionController extends ChangeNotifier {
  DocumentSubmissionController({
    required this.repository,
    required this.pickerGateway,
    this.onSubmissionCommitted,
  });

  final DocumentRepository? repository;
  final PdfPickerGateway pickerGateway;
  final Future<void> Function(String processId)? onSubmissionCommitted;

  int _sessionEpoch = 0;
  final Map<String, int> _historyEpochs = <String, int>{};
  bool _disposed = false;

  String? _activeRequirementId;
  SelectedPdfFile? _selectedFile;
  String? _pendingIdempotencyKey;
  bool _isPickingFile = false;
  bool _isUploading = false;
  bool _hasAmbiguousRetryPending = false;

  String? _selectionErrorMessage;
  String? _selectionErrorRequirementId;
  String? _uploadErrorMessage;
  String? _uploadErrorRequirementId;
  String? _uploadSuccessMessage;
  String? _uploadSuccessRequirementId;

  final Map<String, List<DocumentSubmissionRecord>> _submissionsByRequirement =
      <String, List<DocumentSubmissionRecord>>{};
  final Map<String, Map<String, DocumentReviewRecord>> _reviewsByRequirement =
      <String, Map<String, DocumentReviewRecord>>{};
  final Set<String> _loadingHistoryRequirements = <String>{};
  final Map<String, String> _historyErrorsByRequirement = <String, String>{};
  final Set<String> _expandedHistoryRequirements = <String>{};

  String? _downloadingSubmissionId;
  String? _downloadErrorMessage;
  String? _downloadSuccessMessage;
  String? _downloadFeedbackRequirementId;

  String? get activeRequirementId => _activeRequirementId;
  SelectedPdfFile? get selectedFile => _selectedFile;
  @visibleForTesting
  String? get pendingIdempotencyKey => _pendingIdempotencyKey;
  bool get isPickingFile => _isPickingFile;
  bool get isUploading => _isUploading;
  bool get hasAmbiguousRetryPending => _hasAmbiguousRetryPending;

  String? get selectionErrorMessage => _selectionErrorMessage;
  String? get selectionErrorRequirementId => _selectionErrorRequirementId;
  String? get uploadErrorMessage => _uploadErrorMessage;
  String? get uploadErrorRequirementId => _uploadErrorRequirementId;
  String? get uploadSuccessMessage => _uploadSuccessMessage;
  String? get uploadSuccessRequirementId => _uploadSuccessRequirementId;

  String? get downloadingSubmissionId => _downloadingSubmissionId;
  String? get downloadErrorMessage => _downloadErrorMessage;
  String? get downloadSuccessMessage => _downloadSuccessMessage;
  String? get downloadFeedbackRequirementId => _downloadFeedbackRequirementId;

  bool canSubmitForRequirement(
    ProcessRequirementItem requirement, {
    required ProcessStatus processStatus,
    required UserRole userRole,
  }) {
    if (userRole != UserRole.student) {
      return false;
    }
    if (processStatus == ProcessStatus.cancelled) {
      return false;
    }
    return requirement.status == RequirementStatus.notSubmitted ||
        requirement.status == RequirementStatus.correctionRequested;
  }

  List<DocumentSubmissionRecord> submissionsForRequirement(
    String requirementId,
  ) {
    return _submissionsByRequirement[requirementId] ??
        const <DocumentSubmissionRecord>[];
  }

  DocumentReviewRecord? reviewForSubmission({
    required String requirementId,
    required String submissionId,
  }) {
    return _reviewsByRequirement[requirementId]?[submissionId];
  }

  bool isHistoryLoading(String requirementId) =>
      _loadingHistoryRequirements.contains(requirementId);

  String? historyErrorForRequirement(String requirementId) =>
      _historyErrorsByRequirement[requirementId];

  bool isHistoryExpanded(String requirementId) =>
      _expandedHistoryRequirements.contains(requirementId);

  bool hasSelectedFileFor(String requirementId) =>
      _activeRequirementId == requirementId && _selectedFile != null;

  String? errorForRequirement(String requirementId) {
    if (_uploadErrorRequirementId == requirementId &&
        _uploadErrorMessage != null) {
      return _uploadErrorMessage;
    }
    if (_selectionErrorRequirementId == requirementId &&
        _selectionErrorMessage != null) {
      return _selectionErrorMessage;
    }
    return null;
  }

  String? successForRequirement(String requirementId) {
    if (_uploadSuccessRequirementId == requirementId &&
        _uploadSuccessMessage != null) {
      return _uploadSuccessMessage;
    }
    return null;
  }

  void syncWithProcessDetail(ProcessDetailBundle bundle) {
    if (_disposed || repository == null) {
      return;
    }

    var changed = false;
    final reqIds = bundle.requirements.map((r) => r.id).toSet();
    if (_activeRequirementId != null &&
        !reqIds.contains(_activeRequirementId)) {
      if (!_isUploading) {
        _clearSelectionInternal();
        changed = true;
      }
    }

    for (final req in bundle.requirements) {
      if (_activeRequirementId == req.id &&
          !_isUploading &&
          req.status != RequirementStatus.notSubmitted &&
          req.status != RequirementStatus.correctionRequested) {
        _clearSelectionInternal();
        changed = true;
      }

      if (req.currentVersion > 0) {
        if (_expandedHistoryRequirements.add(req.id)) {
          changed = true;
        }
        final cached = _submissionsByRequirement[req.id];
        final hasCurrentInCache =
            cached != null &&
            cached.any((sub) => isCurrentSubmissionForRequirement(sub, req));
        final loading = _loadingHistoryRequirements.contains(req.id);
        if (!hasCurrentInCache && !loading) {
          unawaited(loadHistoryForRequirement(req.id));
        }
      }
    }
    if (changed) {
      _safeNotify();
    }
  }

  Future<void> toggleHistoryExpanded(String requirementId) async {
    if (_expandedHistoryRequirements.contains(requirementId)) {
      _expandedHistoryRequirements.remove(requirementId);
      _safeNotify();
      return;
    }
    _expandedHistoryRequirements.add(requirementId);
    _safeNotify();
    if (!_submissionsByRequirement.containsKey(requirementId) &&
        !_loadingHistoryRequirements.contains(requirementId)) {
      await loadHistoryForRequirement(requirementId);
    }
  }

  Future<void> reloadExpandedHistories() async {
    if (_disposed || repository == null) {
      return;
    }
    final targetIds = <String>{
      ..._expandedHistoryRequirements,
      ..._submissionsByRequirement.keys,
    };
    for (final reqId in targetIds) {
      if (_disposed) break;
      unawaited(loadHistoryForRequirement(reqId));
    }
  }

  Future<void> loadHistoryForRequirement(String requirementId) async {
    final repo = repository;
    if (repo == null) {
      _submissionsByRequirement[requirementId] =
          const <DocumentSubmissionRecord>[];
      _historyErrorsByRequirement.remove(requirementId);
      _loadingHistoryRequirements.remove(requirementId);
      _safeNotify();
      return;
    }

    final sessionEpoch = _sessionEpoch;
    final historyEpoch = (_historyEpochs[requirementId] ?? 0) + 1;
    _historyEpochs[requirementId] = historyEpoch;
    _loadingHistoryRequirements.add(requirementId);
    _historyErrorsByRequirement.remove(requirementId);
    _safeNotify();

    try {
      final submissions = await repo.fetchRequirementSubmissions(
        processRequirementId: requirementId,
      );
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          _historyEpochs[requirementId] != historyEpoch) {
        return;
      }

      List<DocumentReviewRecord> reviews = const <DocumentReviewRecord>[];
      if (submissions.isNotEmpty) {
        try {
          reviews = await repo.fetchRequirementReviews(
            processRequirementId: requirementId,
          );
        } catch (_) {
          // Consulta auxiliar de revisões persistidas não deve ocultar o histórico já carregado.
          reviews = const <DocumentReviewRecord>[];
        }
      }

      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          _historyEpochs[requirementId] != historyEpoch) {
        return;
      }

      final sorted = List<DocumentSubmissionRecord>.from(submissions)
        ..sort((a, b) => b.version.compareTo(a.version));

      _submissionsByRequirement[requirementId] = sorted;
      _reviewsByRequirement[requirementId] = <String, DocumentReviewRecord>{
        for (final review in reviews) review.submissionId: review,
      };
      _loadingHistoryRequirements.remove(requirementId);
      _historyErrorsByRequirement.remove(requirementId);
    } catch (error) {
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          _historyEpochs[requirementId] != historyEpoch) {
        return;
      }
      _loadingHistoryRequirements.remove(requirementId);
      final failure = SupabaseDocumentRepository.mapError(error);
      _historyErrorsByRequirement[requirementId] = failure.message;
    }
    _safeNotify();
  }

  Future<bool> pickPdfForRequirement(
    ProcessRequirementItem requirement, {
    required ProcessStatus processStatus,
    required UserRole userRole,
  }) async {
    if (!canSubmitForRequirement(
      requirement,
      processStatus: processStatus,
      userRole: userRole,
    )) {
      _selectionErrorRequirementId = requirement.id;
      _selectionErrorMessage =
          'Este requisito não aceita novo envio de PDF no status atual.';
      _safeNotify();
      return false;
    }

    if (_isPickingFile || _isUploading) {
      return false;
    }

    final epoch = _sessionEpoch;
    _isPickingFile = true;
    _selectionErrorMessage = null;
    _selectionErrorRequirementId = null;
    _uploadErrorMessage = null;
    _uploadErrorRequirementId = null;
    _uploadSuccessMessage = null;
    _uploadSuccessRequirementId = null;
    _safeNotify();

    try {
      final picked = await pickerGateway.pickPdf();
      if (_disposed || epoch != _sessionEpoch) {
        return false;
      }
      _isPickingFile = false;
      if (picked == null) {
        _safeNotify();
        return false;
      }
      return selectPdfFileForRequirement(
        requirement,
        picked,
        processStatus: processStatus,
        userRole: userRole,
      );
    } catch (error) {
      if (_disposed || epoch != _sessionEpoch) {
        return false;
      }
      _isPickingFile = false;
      final failure = SupabaseDocumentRepository.mapError(error);
      _selectionErrorRequirementId = requirement.id;
      _selectionErrorMessage = failure.message;
      _safeNotify();
      return false;
    }
  }

  bool selectPdfFileForRequirement(
    ProcessRequirementItem requirement,
    SelectedPdfFile file, {
    required ProcessStatus processStatus,
    required UserRole userRole,
  }) {
    if (_isUploading) {
      return false;
    }

    if (!canSubmitForRequirement(
      requirement,
      processStatus: processStatus,
      userRole: userRole,
    )) {
      _clearSelectionInternal();
      _selectionErrorRequirementId = requirement.id;
      _selectionErrorMessage =
          'Envio bloqueado para o status atual deste requisito.';
      _safeNotify();
      return false;
    }

    final validationError = PdfPreliminaryValidation.validate(file);
    if (validationError != null) {
      _clearSelectionInternal();
      _activeRequirementId = requirement.id;
      _selectionErrorRequirementId = requirement.id;
      _selectionErrorMessage = validationError;
      _safeNotify();
      return false;
    }

    final samePendingAttempt =
        _hasAmbiguousRetryPending &&
        _activeRequirementId == requirement.id &&
        _pendingIdempotencyKey != null &&
        _selectedFile != null &&
        _selectedFile!.basename == file.basename &&
        _selectedFile!.sizeBytes == file.sizeBytes &&
        _bytesEqual(_selectedFile!.bytes, file.bytes);

    _activeRequirementId = requirement.id;
    _selectedFile = file;
    if (!samePendingAttempt) {
      _pendingIdempotencyKey = generateUuidV4();
      _hasAmbiguousRetryPending = false;
    }

    _selectionErrorMessage = null;
    _selectionErrorRequirementId = null;
    _uploadErrorMessage = null;
    _uploadErrorRequirementId = null;
    _uploadSuccessMessage = null;
    _uploadSuccessRequirementId = null;
    _safeNotify();
    return true;
  }

  void cancelSelection() {
    if (_isUploading) {
      return;
    }
    _clearSelectionInternal();
    _safeNotify();
  }

  Future<bool> submitSelectedPdf({
    required ProcessRequirementItem requirement,
    required ProcessStatus processStatus,
    required UserRole userRole,
  }) async {
    if (_isUploading) {
      return false;
    }

    final repo = repository;
    if (repo == null) {
      _uploadErrorRequirementId = requirement.id;
      _uploadErrorMessage = 'Repositório documental não configurado.';
      _safeNotify();
      return false;
    }

    if (!canSubmitForRequirement(
      requirement,
      processStatus: processStatus,
      userRole: userRole,
    )) {
      _uploadErrorRequirementId = requirement.id;
      _uploadErrorMessage =
          'Este requisito não aceita submissão no status atual.';
      _safeNotify();
      return false;
    }

    final file = _selectedFile;
    final idempotencyKey = _pendingIdempotencyKey;
    if (_activeRequirementId != requirement.id ||
        file == null ||
        idempotencyKey == null) {
      _selectionErrorRequirementId = requirement.id;
      _selectionErrorMessage = 'Selecione um arquivo PDF antes de enviar.';
      _safeNotify();
      return false;
    }

    final validationError = PdfPreliminaryValidation.validate(file);
    if (validationError != null) {
      _clearSelectionInternal();
      _selectionErrorRequirementId = requirement.id;
      _selectionErrorMessage = validationError;
      _safeNotify();
      return false;
    }

    final epoch = _sessionEpoch;
    _isUploading = true;
    _uploadErrorMessage = null;
    _uploadErrorRequirementId = null;
    _uploadSuccessMessage = null;
    _uploadSuccessRequirementId = null;
    _selectionErrorMessage = null;
    _selectionErrorRequirementId = null;
    _safeNotify();

    try {
      final outcome = await repo.submitRequirementPdf(
        processRequirementId: requirement.id,
        file: file,
        idempotencyKey: idempotencyKey,
      );
      if (_disposed || epoch != _sessionEpoch) {
        return false;
      }

      await _handleConfirmedSubmission(
        processId: requirement.processId,
        requirementId: requirement.id,
        idempotentReplay: outcome.idempotentReplay,
        sessionEpoch: epoch,
      );
      return true;
    } catch (error) {
      if (_disposed || epoch != _sessionEpoch) {
        return false;
      }

      final failure = SupabaseDocumentRepository.mapError(error);
      if (failure.isAmbiguousNetworkOrTimeout) {
        DocumentSubmissionRecord? persisted;
        try {
          persisted = await repo.findSubmissionByIdempotencyKey(
            processRequirementId: requirement.id,
            idempotencyKey: idempotencyKey,
          );
        } catch (_) {
          persisted = null;
        }

        if (_disposed || epoch != _sessionEpoch) {
          return false;
        }

        if (persisted != null) {
          await _handleConfirmedSubmission(
            processId: requirement.processId,
            requirementId: requirement.id,
            idempotentReplay: true,
            sessionEpoch: epoch,
          );
          return true;
        }

        // Preserva o arquivo e exatamente o mesmo idempotency_key para retry seguro.
        _isUploading = false;
        _hasAmbiguousRetryPending = true;
        _uploadErrorRequirementId = requirement.id;
        _uploadErrorMessage = failure.message;
        _safeNotify();
        return false;
      }

      _isUploading = false;
      _hasAmbiguousRetryPending = false;
      _uploadErrorRequirementId = requirement.id;
      _uploadErrorMessage = failure.message;

      if (failure.httpStatus == 409) {
        if (failure.code == 'idempotency_mismatch') {
          _pendingIdempotencyKey = generateUuidV4();
        } else {
          unawaited(loadHistoryForRequirement(requirement.id));
          final refreshProcess = onSubmissionCommitted;
          if (refreshProcess != null) {
            unawaited(refreshProcess(requirement.processId));
          }
        }
      }

      _safeNotify();
      return false;
    }
  }

  Future<bool> downloadSubmission(DocumentSubmissionRecord submission) async {
    if (_downloadingSubmissionId != null) {
      return false;
    }

    final repo = repository;
    if (repo == null) {
      _downloadFeedbackRequirementId = submission.processRequirementId;
      _downloadErrorMessage = 'Repositório documental não configurado.';
      _safeNotify();
      return false;
    }

    final epoch = _sessionEpoch;
    _downloadingSubmissionId = submission.id;
    _downloadErrorMessage = null;
    _downloadSuccessMessage = null;
    _downloadFeedbackRequirementId = submission.processRequirementId;
    _safeNotify();

    try {
      final bytes = await repo.downloadSubmissionBytes(
        storageBucket: submission.storageBucket,
        storagePath: submission.storagePath,
      );
      if (_disposed || epoch != _sessionEpoch) {
        return false;
      }

      final saved = await pickerGateway.savePdf(
        filename: submission.displayFilename,
        bytes: bytes,
      );
      if (_disposed || epoch != _sessionEpoch) {
        return false;
      }

      _downloadingSubmissionId = null;
      _downloadErrorMessage = null;
      _downloadSuccessMessage = saved
          ? 'Documento v${submission.version} obtido via acesso privado.'
          : 'Salvamento do documento cancelado.';
      _safeNotify();
      return saved;
    } catch (error) {
      if (_disposed || epoch != _sessionEpoch) {
        return false;
      }
      _downloadingSubmissionId = null;
      final failure = SupabaseDocumentRepository.mapError(error);
      _downloadSuccessMessage = null;
      _downloadErrorMessage = failure.message;
      _safeNotify();
      return false;
    }
  }

  void clearPrivateState() {
    ++_sessionEpoch;
    for (final reqId in _historyEpochs.keys.toList(growable: false)) {
      _historyEpochs[reqId] = (_historyEpochs[reqId] ?? 0) + 1;
    }
    _clearSelectionInternal();
    _isPickingFile = false;
    _isUploading = false;
    _submissionsByRequirement.clear();
    _reviewsByRequirement.clear();
    _loadingHistoryRequirements.clear();
    _historyErrorsByRequirement.clear();
    _expandedHistoryRequirements.clear();
    _downloadingSubmissionId = null;
    _downloadErrorMessage = null;
    _downloadSuccessMessage = null;
    _downloadFeedbackRequirementId = null;
    _uploadSuccessMessage = null;
    _uploadSuccessRequirementId = null;
    _safeNotify();
  }

  Future<void> _handleConfirmedSubmission({
    required String processId,
    required String requirementId,
    required bool idempotentReplay,
    required int sessionEpoch,
  }) async {
    _clearSelectionInternal();
    _isUploading = false;
    _hasAmbiguousRetryPending = false;
    _uploadSuccessRequirementId = requirementId;
    _uploadSuccessMessage = idempotentReplay
        ? 'Documento recebido e enviado para análise (envio anterior confirmado).'
        : 'Documento recebido e enviado para análise.';
    _expandedHistoryRequirements.add(requirementId);
    _safeNotify();

    await loadHistoryForRequirement(requirementId);
    if (_disposed || sessionEpoch != _sessionEpoch) {
      return;
    }
    final onCommitted = onSubmissionCommitted;
    if (onCommitted != null) {
      await onCommitted(processId);
    }
  }

  void _clearSelectionInternal() {
    _activeRequirementId = null;
    _selectedFile = null;
    _pendingIdempotencyKey = null;
    _hasAmbiguousRetryPending = false;
    _selectionErrorMessage = null;
    _selectionErrorRequirementId = null;
    _uploadErrorMessage = null;
    _uploadErrorRequirementId = null;
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.lengthInBytes != b.lengthInBytes) return false;
    for (var i = 0; i < a.lengthInBytes; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_sessionEpoch;
    _clearSelectionInternal();
    _submissionsByRequirement.clear();
    _reviewsByRequirement.clear();
    _loadingHistoryRequirements.clear();
    _historyErrorsByRequirement.clear();
    _expandedHistoryRequirements.clear();
    super.dispose();
  }
}
