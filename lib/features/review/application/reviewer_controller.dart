import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../processes/data/file_picker_pdf_gateway.dart';
import '../../processes/domain/document_models.dart';
import '../../processes/domain/document_repository.dart';
import '../data/pdf_document_renderer.dart';
import '../data/supabase_review_repository.dart';
import '../domain/review_models.dart';
import '../domain/review_repository.dart';
import 'process_timeline_controller.dart';

class ReviewerController extends ChangeNotifier {
  ReviewerController({
    required this.repository,
    PdfPickerGateway? pickerGateway,
    PdfRendererGateway? pdfRendererGateway,
    int pageSize = kDefaultReviewPageSize,
  }) : pickerGateway = pickerGateway ?? const FilePickerPdfGateway(),
       pdfRendererGateway = pdfRendererGateway ?? PlatformPdfRendererGateway(),
       _query = ReviewerQueueQuery(pageSize: pageSize),
       timelineController = ProcessTimelineController(
         repository: repository,
         pageSize: pageSize,
       );

  final ReviewRepository? repository;
  final PdfPickerGateway pickerGateway;
  final PdfRendererGateway pdfRendererGateway;
  final ProcessTimelineController timelineController;

  int _sessionEpoch = 0;
  int _queueEpoch = 0;
  int _pdfEpoch = 0;
  int _historyEpoch = 0;
  int _decisionEpoch = 0;
  bool _disposed = false;

  // Estado da fila paginada (ESP-18)
  ReviewLoadStatus _queueStatus = ReviewLoadStatus.loading;
  ReviewerQueueQuery _query;
  List<ReviewerQueueItem> _queueItems = const <ReviewerQueueItem>[];
  int _totalQueueCount = 0;
  String? _queueErrorMessage;
  String? _feedbackMessage;
  bool _isFeedbackError = false;

  // Item selecionado para inspeção e decisão
  ReviewerQueueItem? _selectedItem;
  ReviewDecisionOutcome? _lastDecisionOutcome;

  // Estado de visualização/download autenticado de PDF (ESP-19)
  bool _isLoadingPdf = false;
  bool _isSavingPdf = false;
  VerifiedPdfPayload? _loadedPdf;
  int _currentPdfPage = 1;
  double _pdfZoomScale = 1.0;
  String? _pdfErrorMessage;
  String? _pdfActionMessage;

  // Estado de decisão atômica (ESP-20)
  ReviewDecision _selectedDecision = ReviewDecision.approved;
  String _reasonText = '';
  bool _isConfirmingDecision = false;
  bool _isSubmittingDecision = false;
  String? _decisionErrorMessage;
  String? _pendingDecisionIdempotencyKey;
  String? _pendingDecisionSubmissionId;
  ReviewDecision? _pendingDecisionType;
  String? _pendingDecisionReason;
  bool _hasAmbiguousDecisionRetryPending = false;

  // Histórico de versões do requisito inspecionado (ESP-21)
  String? _activeHistoryRequirementId;
  String? _activeHistoryRequirementCode;
  String? _activeHistoryRequirementTitle;
  int? _activeHistoryCurrentVersion;
  String? _activeHistoryCurrentSubmissionId;
  ReviewLoadStatus _historyStatus = ReviewLoadStatus.loaded;
  List<DocumentSubmissionRecord> _requirementSubmissions =
      const <DocumentSubmissionRecord>[];
  Map<String, DocumentReviewRecord> _requirementReviewsBySubmissionId =
      const <String, DocumentReviewRecord>{};
  String? _historyErrorMessage;

  ReviewLoadStatus get queueStatus => _queueStatus;
  ReviewerQueueQuery get query => _query;
  List<ReviewerQueueItem> get queueItems => _queueItems;
  int get totalQueueCount => _totalQueueCount;
  String? get queueErrorMessage => _queueErrorMessage;
  String? get feedbackMessage => _feedbackMessage;
  bool get isFeedbackError => _isFeedbackError;

  ReviewerQueueItem? get selectedItem => _selectedItem;
  ReviewDecisionOutcome? get lastDecisionOutcome => _lastDecisionOutcome;

  bool get isLoadingPdf => _isLoadingPdf;
  bool get isSavingPdf => _isSavingPdf;
  VerifiedPdfPayload? get loadedPdf => _loadedPdf;
  int get currentPdfPage => _currentPdfPage;
  int get totalPdfPages => _loadedPdf?.pageCount ?? 0;
  double get pdfZoomScale => _pdfZoomScale;
  bool get canGoToPreviousPdfPage =>
      _loadedPdf != null &&
      !_loadedPdf!.isWiped &&
      (_loadedPdf!.renderedDocument?.hasValidatedPageCount ?? false) &&
      _currentPdfPage > 1;
  bool get canGoToNextPdfPage =>
      _loadedPdf != null &&
      !_loadedPdf!.isWiped &&
      (_loadedPdf!.renderedDocument?.hasValidatedPageCount ?? false) &&
      _currentPdfPage < totalPdfPages;
  String? get pdfErrorMessage => _pdfErrorMessage;
  String? get pdfActionMessage => _pdfActionMessage;

  ReviewDecision get selectedDecision => _selectedDecision;
  String get reasonText => _reasonText;
  bool get isConfirmingDecision => _isConfirmingDecision;
  bool get isSubmittingDecision => _isSubmittingDecision;
  String? get decisionErrorMessage => _decisionErrorMessage;
  @visibleForTesting
  String? get pendingDecisionIdempotencyKey => _pendingDecisionIdempotencyKey;
  bool get hasAmbiguousDecisionRetryPending =>
      _hasAmbiguousDecisionRetryPending;

  String? get activeHistoryRequirementId => _activeHistoryRequirementId;
  String? get activeHistoryRequirementCode => _activeHistoryRequirementCode;
  String? get activeHistoryRequirementTitle => _activeHistoryRequirementTitle;
  int? get activeHistoryCurrentVersion => _activeHistoryCurrentVersion;
  String? get activeHistoryCurrentSubmissionId =>
      _activeHistoryCurrentSubmissionId;
  ReviewLoadStatus get historyStatus => _historyStatus;
  List<DocumentSubmissionRecord> get requirementSubmissions =>
      _requirementSubmissions;
  String? get historyErrorMessage => _historyErrorMessage;

  int get totalQueuePages {
    if (_totalQueueCount <= 0 || _query.pageSize <= 0) {
      return 1;
    }
    return (_totalQueueCount + _query.pageSize - 1) ~/ _query.pageSize;
  }

  bool get hasPreviousQueuePage => _query.page > 0;
  bool get hasNextQueuePage =>
      (_query.page + 1) * _query.pageSize < _totalQueueCount;

  DocumentReviewRecord? reviewForSubmission(String submissionId) =>
      _requirementReviewsBySubmissionId[submissionId];

  bool isCurrentSubmissionInHistory(DocumentSubmissionRecord submission) {
    final currentId = _activeHistoryCurrentSubmissionId;
    if (currentId != null && currentId.isNotEmpty) {
      return submission.id == currentId;
    }
    final currentVer = _activeHistoryCurrentVersion ?? 0;
    return currentVer > 0 && submission.version == currentVer;
  }

  Future<void> loadQueue({
    ReviewerQueueQuery? newQuery,
    bool preserveFeedback = false,
    bool autoSelectFirstIfNone = true,
  }) async {
    if (newQuery != null) {
      _query = newQuery;
    }
    if (!preserveFeedback) {
      _feedbackMessage = null;
      _isFeedbackError = false;
    }

    final repo = repository;
    if (repo == null) {
      ++_queueEpoch;
      _queueItems = const <ReviewerQueueItem>[];
      _totalQueueCount = 0;
      _queueErrorMessage = null;
      _queueStatus = ReviewLoadStatus.loaded;
      _safeNotify();
      return;
    }

    final sessionEpoch = _sessionEpoch;
    final queueEpoch = ++_queueEpoch;
    _queueStatus = ReviewLoadStatus.loading;
    _queueErrorMessage = null;
    _safeNotify();

    try {
      var result = await repo.fetchReviewerQueue(query: _query);
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          queueEpoch != _queueEpoch) {
        return;
      }

      // Se a página atual ficou vazia após decisão/remoção, mas ainda existem itens em páginas anteriores,
      // recua automaticamente para a última página válida.
      if (result.items.isEmpty && result.totalCount > 0 && _query.page > 0) {
        final lastValidPage = ((result.totalCount - 1) ~/ _query.pageSize);
        _query = _query.copyWith(page: lastValidPage);
        result = await repo.fetchReviewerQueue(query: _query);
        if (_disposed ||
            sessionEpoch != _sessionEpoch ||
            queueEpoch != _queueEpoch) {
          return;
        }
      }

      _queueItems = result.items;
      _totalQueueCount = result.totalCount;
      _queueStatus = ReviewLoadStatus.loaded;
      _queueErrorMessage = null;

      _reconcileSelectedItemAfterQueueLoad(
        autoSelectFirstIfNone: autoSelectFirstIfNone,
      );
    } catch (error) {
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          queueEpoch != _queueEpoch) {
        return;
      }
      final failure = SupabaseReviewRepository.mapError(error);
      _queueErrorMessage = failure.message;
      _queueStatus = ReviewLoadStatus.error;
      if (failure.isForbiddenScope || failure.isUnauthorized) {
        _wipeLoadedPdfInternal();
        _selectedItem = null;
      }
    }
    _safeNotify();
  }

  void _reconcileSelectedItemAfterQueueLoad({
    required bool autoSelectFirstIfNone,
  }) {
    final currentSelected = _selectedItem;
    if (currentSelected != null) {
      ReviewerQueueItem? updatedMatch;
      for (final item in _queueItems) {
        if (item.submissionId == currentSelected.submissionId) {
          updatedMatch = item;
          break;
        }
      }

      if (updatedMatch != null) {
        _selectedItem = updatedMatch;
        _activeHistoryRequirementId = updatedMatch.processRequirementId;
        _activeHistoryRequirementCode = updatedMatch.requirementCode;
        _activeHistoryRequirementTitle = updatedMatch.requirementTitle;
        _activeHistoryCurrentVersion = updatedMatch.currentVersion;
        _activeHistoryCurrentSubmissionId = updatedMatch.submissionId;
        return;
      }

      // A submissão selecionada saiu da fila (já revisada, substituída por v(n+1) ou fora de escopo)
      _wipeLoadedPdfInternal();
      _selectedItem = null;
      _resetDecisionFormInternal();

      // Verificar se o mesmo requisito possui uma nova versão vigente na fila
      for (final item in _queueItems) {
        if (item.processRequirementId == currentSelected.processRequirementId) {
          selectQueueItem(item, preserveFeedback: true);
          return;
        }
      }
    }

    if (_selectedItem == null &&
        autoSelectFirstIfNone &&
        _queueItems.isNotEmpty) {
      selectQueueItem(_queueItems.first, preserveFeedback: true);
    }
  }

  Future<void> updateSearchQuery(String value) async {
    await loadQueue(newQuery: _query.copyWith(searchQuery: value, page: 0));
  }

  Future<void> setOnlyRequiredFilter(bool? onlyRequired) async {
    await loadQueue(
      newQuery: _query.copyWith(onlyRequired: () => onlyRequired, page: 0),
    );
  }

  Future<void> setOnlyResubmissionsFilter(bool? onlyResubmissions) async {
    await loadQueue(
      newQuery: _query.copyWith(
        onlyResubmissions: () => onlyResubmissions,
        page: 0,
      ),
    );
  }

  Future<void> toggleQueueSortOrder() async {
    await loadQueue(
      newQuery: _query.copyWith(oldestFirst: !_query.oldestFirst, page: 0),
    );
  }

  Future<void> clearFilters() async {
    await loadQueue(
      newQuery: ReviewerQueueQuery(
        page: 0,
        pageSize: _query.pageSize,
        oldestFirst: _query.oldestFirst,
      ),
    );
  }

  Future<void> nextQueuePage() async {
    if (!hasNextQueuePage || _queueStatus == ReviewLoadStatus.loading) {
      return;
    }
    await loadQueue(
      newQuery: _query.copyWith(page: _query.page + 1),
      preserveFeedback: true,
    );
  }

  Future<void> previousQueuePage() async {
    if (!hasPreviousQueuePage || _queueStatus == ReviewLoadStatus.loading) {
      return;
    }
    await loadQueue(
      newQuery: _query.copyWith(page: _query.page - 1),
      preserveFeedback: true,
    );
  }

  void selectQueueItem(
    ReviewerQueueItem item, {
    bool preserveFeedback = false,
  }) {
    if (_isSubmittingDecision) {
      return;
    }

    final isSameSubmission = _selectedItem?.submissionId == item.submissionId;
    _selectedItem = item;
    _lastDecisionOutcome = null;
    if (!preserveFeedback) {
      _feedbackMessage = null;
      _isFeedbackError = false;
    }

    if (!isSameSubmission) {
      _wipeLoadedPdfInternal();
      _resetDecisionFormInternal();
    }

    _activeHistoryRequirementId = item.processRequirementId;
    _activeHistoryRequirementCode = item.requirementCode;
    _activeHistoryRequirementTitle = item.requirementTitle;
    _activeHistoryCurrentVersion = item.currentVersion;
    _activeHistoryCurrentSubmissionId = item.submissionId;
    _safeNotify();

    unawaited(loadRequirementHistory(item.processRequirementId));
    unawaited(timelineController.loadTimeline(item.processId));
  }

  Future<void> loadRequirementHistory(String processRequirementId) async {
    final cleanReqId = processRequirementId.trim();
    final repo = repository;
    if (repo == null || cleanReqId.isEmpty) {
      ++_historyEpoch;
      _requirementSubmissions = const <DocumentSubmissionRecord>[];
      _requirementReviewsBySubmissionId =
          const <String, DocumentReviewRecord>{};
      _historyErrorMessage = null;
      _historyStatus = ReviewLoadStatus.loaded;
      _safeNotify();
      return;
    }

    final sessionEpoch = _sessionEpoch;
    final historyEpoch = ++_historyEpoch;
    _activeHistoryRequirementId = cleanReqId;
    _historyStatus = ReviewLoadStatus.loading;
    _historyErrorMessage = null;
    _safeNotify();

    try {
      final submissions = await repo.fetchRequirementSubmissions(
        processRequirementId: cleanReqId,
      );
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          historyEpoch != _historyEpoch) {
        return;
      }

      List<DocumentReviewRecord> reviews = const <DocumentReviewRecord>[];
      if (submissions.isNotEmpty) {
        try {
          reviews = await repo.fetchRequirementReviews(
            processRequirementId: cleanReqId,
          );
        } catch (_) {
          reviews = const <DocumentReviewRecord>[];
        }
      }

      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          historyEpoch != _historyEpoch) {
        return;
      }

      final sorted = List<DocumentSubmissionRecord>.from(submissions)
        ..sort((a, b) => b.version.compareTo(a.version));

      _requirementSubmissions = sorted;
      _requirementReviewsBySubmissionId = <String, DocumentReviewRecord>{
        for (final review in reviews) review.submissionId: review,
      };
      _historyErrorMessage = null;
      _historyStatus = ReviewLoadStatus.loaded;
    } catch (error) {
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          historyEpoch != _historyEpoch) {
        return;
      }
      final failure = SupabaseReviewRepository.mapError(error);
      _historyErrorMessage = failure.message;
      _historyStatus = ReviewLoadStatus.error;
    }
    _safeNotify();
  }

  Future<bool> loadAuthenticatedPdfForSelected() async {
    if (_isLoadingPdf) {
      return false;
    }

    final item = _selectedItem;
    if (item == null) {
      _pdfErrorMessage =
          'Selecione uma submissão na fila antes de carregar o PDF.';
      _safeNotify();
      return false;
    }

    final repo = repository;
    if (repo == null) {
      _pdfErrorMessage = 'Repositório de revisão não configurado.';
      _safeNotify();
      return false;
    }

    _wipeLoadedPdfInternal();

    final sessionEpoch = _sessionEpoch;
    final pdfEpoch = ++_pdfEpoch;
    final targetSubmissionId = item.submissionId;

    _isLoadingPdf = true;
    _pdfErrorMessage = null;
    _pdfActionMessage = null;
    _safeNotify();

    try {
      final bytes = await repo.downloadSubmissionBytes(
        submissionId: item.submissionId,
      );

      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          pdfEpoch != _pdfEpoch ||
          _selectedItem?.submissionId != targetSubmissionId) {
        if (bytes.isNotEmpty) {
          bytes.fillRange(0, bytes.length, 0);
        }
        return false;
      }

      if (!PdfPreliminaryValidation.hasPdfHeader(bytes)) {
        bytes.fillRange(0, bytes.length, 0);
        _isLoadingPdf = false;
        _pdfErrorMessage =
            'O arquivo retornado não possui assinatura válida de PDF (%PDF-).';
        _safeNotify();
        return false;
      }

      final renderedDoc = await pdfRendererGateway.renderDocument(
        bytes: bytes,
        submissionId: item.submissionId,
        submissionVersion: item.submissionVersion,
        documentTitle: item.requirementTitle,
      );

      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          pdfEpoch != _pdfEpoch ||
          _selectedItem?.submissionId != targetSubmissionId) {
        if (bytes.isNotEmpty) {
          bytes.fillRange(0, bytes.length, 0);
        }
        renderedDoc.wipe();
        unawaited(pdfRendererGateway.clearTemporaryResources(renderedDoc));
        return false;
      }

      if (!renderedDoc.isViewable) {
        if (bytes.isNotEmpty) {
          bytes.fillRange(0, bytes.length, 0);
        }
        renderedDoc.wipe();
        unawaited(pdfRendererGateway.clearTemporaryResources(renderedDoc));
        _isLoadingPdf = false;
        _pdfErrorMessage =
            'O documento PDF não contém páginas válidas para exibição.';
        _safeNotify();
        return false;
      }

      _loadedPdf = VerifiedPdfPayload(
        submissionId: item.submissionId,
        submissionVersion: item.submissionVersion,
        processId: item.processId,
        processRequirementId: item.processRequirementId,
        requirementCode: item.requirementCode,
        requirementTitle: item.requirementTitle,
        studentName: item.studentName,
        originalFilename: item.displayFilename,
        storageBucket: item.storageBucket,
        storagePath: item.storagePath,
        bytes: bytes,
        loadedAt: DateTime.now(),
        renderedDocument: renderedDoc,
      );
      _currentPdfPage = 1;
      _pdfZoomScale = 1.0;
      _isLoadingPdf = false;
      _pdfErrorMessage = null;
      if (renderedDoc.hasValidatedPageCount) {
        final pageLabel = renderedDoc.pageCount == 1
            ? '1 página'
            : '${renderedDoc.pageCount} páginas';
        _pdfActionMessage =
            'PDF v${item.submissionVersion} carregado e renderizado ($pageLabel • ${_loadedPdf!.formattedSize}).';
      } else {
        _pdfActionMessage =
            'PDF v${item.submissionVersion} carregado no visualizador nativo do navegador (${_loadedPdf!.formattedSize}).';
      }
      _safeNotify();
      return true;
    } catch (error) {
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          pdfEpoch != _pdfEpoch ||
          _selectedItem?.submissionId != targetSubmissionId) {
        return false;
      }
      _isLoadingPdf = false;
      _wipeLoadedPdfInternal();
      final failure = SupabaseReviewRepository.mapError(error);
      _pdfErrorMessage = failure.message;
      _safeNotify();

      if (failure.isForbiddenScope || failure.shouldReloadQueue) {
        _feedbackMessage = failure.message;
        _isFeedbackError = true;
        unawaited(
          loadQueue(preserveFeedback: true, autoSelectFirstIfNone: false),
        );
      }
      return false;
    }
  }

  Future<bool> saveLoadedPdfLocally() async {
    if (_isSavingPdf) {
      return false;
    }

    var payload = _loadedPdf;
    if (payload == null || payload.isWiped) {
      final loaded = await loadAuthenticatedPdfForSelected();
      if (!loaded) {
        return false;
      }
      payload = _loadedPdf;
    }

    if (payload == null || payload.isWiped) {
      return false;
    }

    final sessionEpoch = _sessionEpoch;
    _isSavingPdf = true;
    _pdfActionMessage = null;
    _safeNotify();

    try {
      final saved = await pickerGateway.savePdf(
        filename: payload.originalFilename,
        bytes: Uint8List.fromList(payload.bytes),
      );
      if (_disposed || sessionEpoch != _sessionEpoch) {
        return false;
      }
      _isSavingPdf = false;
      _pdfActionMessage = saved
          ? 'PDF v${payload.submissionVersion} exportado localmente.'
          : 'Exportação local do PDF cancelada.';
      _safeNotify();
      return saved;
    } catch (error) {
      if (_disposed || sessionEpoch != _sessionEpoch) {
        return false;
      }
      _isSavingPdf = false;
      final failure = SupabaseReviewRepository.mapError(error);
      _pdfErrorMessage = failure.message;
      _safeNotify();
      return false;
    }
  }

  void clearLoadedPdf() {
    _wipeLoadedPdfInternal();
    _pdfActionMessage = 'Bytes do PDF descartados da memória.';
    _safeNotify();
  }

  void goToPdfPage(int pageNumber) {
    final doc = _loadedPdf?.renderedDocument;
    if (doc == null ||
        doc.isWiped ||
        _loadedPdf == null ||
        _loadedPdf!.isWiped) {
      return;
    }
    if (!doc.hasValidatedPageCount) {
      final safeTarget = pageNumber < 1 ? 1 : pageNumber;
      _currentPdfPage = safeTarget;
      doc.navigateToPage(safeTarget);
      _safeNotify();
      return;
    }
    final target = pageNumber.clamp(1, doc.pageCount);
    if (_currentPdfPage == target) {
      return;
    }
    _currentPdfPage = target;
    doc.navigateToPage(target);
    _safeNotify();
  }

  void nextPdfPage() {
    if (!canGoToNextPdfPage) return;
    goToPdfPage(_currentPdfPage + 1);
  }

  void previousPdfPage() {
    if (!canGoToPreviousPdfPage) return;
    goToPdfPage(_currentPdfPage - 1);
  }

  void zoomInPdf() {
    final payload = _loadedPdf;
    if (payload == null || payload.isWiped) return;
    final nextScale = (_pdfZoomScale + 0.25).clamp(0.75, 2.5);
    if (nextScale == _pdfZoomScale) return;
    _pdfZoomScale = nextScale;
    _safeNotify();
  }

  void zoomOutPdf() {
    final payload = _loadedPdf;
    if (payload == null || payload.isWiped) return;
    final nextScale = (_pdfZoomScale - 0.25).clamp(0.75, 2.5);
    if (nextScale == _pdfZoomScale) return;
    _pdfZoomScale = nextScale;
    _safeNotify();
  }

  void resetPdfZoom() {
    final payload = _loadedPdf;
    if (payload == null || payload.isWiped) return;
    if (_pdfZoomScale == 1.0) return;
    _pdfZoomScale = 1.0;
    _safeNotify();
  }

  bool openPdfInBrowserOrFallback() {
    final payload = _loadedPdf;
    final doc = payload?.renderedDocument;
    if (payload == null || payload.isWiped || doc == null || doc.isWiped) {
      return false;
    }
    final openedBrowserTab = doc.openInBrowserTab(pageNumber: _currentPdfPage);
    _pdfActionMessage = openedBrowserTab
        ? 'PDF v${payload.submissionVersion} aberto em nova aba temporária do navegador (página $_currentPdfPage).'
        : 'Leitor expandido aberto para o PDF v${payload.submissionVersion} (página $_currentPdfPage de ${doc.pageCount}).';
    _safeNotify();
    return openedBrowserTab;
  }

  void selectDecision(ReviewDecision decision) {
    if (_isSubmittingDecision) {
      return;
    }
    if (_selectedDecision == decision) {
      return;
    }
    _selectedDecision = decision;
    _isConfirmingDecision = false;
    _decisionErrorMessage = null;
    _invalidatePendingIdempotencyIfChanged();
    _safeNotify();
  }

  void updateReason(String value) {
    if (_isSubmittingDecision) {
      return;
    }
    _reasonText = value;
    _decisionErrorMessage = null;
    _invalidatePendingIdempotencyIfChanged();
    _safeNotify();
  }

  bool prepareDecisionConfirmation() {
    if (_isSubmittingDecision) {
      return false;
    }
    final item = _selectedItem;
    if (item == null) {
      _decisionErrorMessage = 'Selecione uma submissão vigente na fila antes de registrar uma decisão.';
      _safeNotify();
      return false;
    }

    final validationError = ReviewDecisionValidation.validate(
      decision: _selectedDecision,
      reason: _reasonText,
    );
    if (validationError != null) {
      _isConfirmingDecision = false;
      _decisionErrorMessage = validationError;
      _safeNotify();
      return false;
    }

    _decisionErrorMessage = null;
    _isConfirmingDecision = true;
    _safeNotify();
    return true;
  }

  void cancelDecisionConfirmation() {
    if (_isSubmittingDecision) {
      return;
    }
    _isConfirmingDecision = false;
    _decisionErrorMessage = null;
    _safeNotify();
  }

  Future<bool> submitConfirmedDecision() async {
    if (_isSubmittingDecision) {
      return false;
    }

    final item = _selectedItem;
    if (item == null) {
      _decisionErrorMessage = 'Selecione uma submissão vigente na fila antes de registrar uma decisão.';
      _safeNotify();
      return false;
    }

    final repo = repository;
    if (repo == null) {
      _decisionErrorMessage = 'Repositório de revisão não configurado.';
      _safeNotify();
      return false;
    }

    final validationError = ReviewDecisionValidation.validate(
      decision: _selectedDecision,
      reason: _reasonText,
    );
    if (validationError != null) {
      _isConfirmingDecision = false;
      _decisionErrorMessage = validationError;
      _safeNotify();
      return false;
    }

    final cleanedReason = ReviewDecisionValidation.cleanReason(_reasonText);
    final isSameRetryAttempt =
        _hasAmbiguousDecisionRetryPending &&
        _pendingDecisionIdempotencyKey != null &&
        _pendingDecisionSubmissionId == item.submissionId &&
        _pendingDecisionType == _selectedDecision &&
        _pendingDecisionReason == cleanedReason;

    if (!isSameRetryAttempt) {
      _pendingDecisionIdempotencyKey = generateUuidV4();
      _pendingDecisionSubmissionId = item.submissionId;
      _pendingDecisionType = _selectedDecision;
      _pendingDecisionReason = cleanedReason;
      _hasAmbiguousDecisionRetryPending = false;
    }

    final idempotencyKey = _pendingDecisionIdempotencyKey!;
    final sessionEpoch = _sessionEpoch;
    final decisionEpoch = ++_decisionEpoch;

    _isConfirmingDecision = true;
    _isSubmittingDecision = true;
    _decisionErrorMessage = null;
    _feedbackMessage = null;
    _isFeedbackError = false;
    _safeNotify();

    try {
      final outcome = await repo.reviewSubmission(
        submissionId: item.submissionId,
        decision: _selectedDecision,
        reason: cleanedReason.isEmpty ? null : cleanedReason,
        idempotencyKey: idempotencyKey,
      );

      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          decisionEpoch != _decisionEpoch) {
        return false;
      }

      _wipeLoadedPdfInternal();
      _isSubmittingDecision = false;
      _isConfirmingDecision = false;
      _hasAmbiguousDecisionRetryPending = false;
      _pendingDecisionIdempotencyKey = null;
      _pendingDecisionSubmissionId = null;
      _pendingDecisionType = null;
      _pendingDecisionReason = null;
      _reasonText = '';

      _lastDecisionOutcome = outcome;
      _activeHistoryRequirementId = outcome.requirement.id;
      _activeHistoryRequirementCode = outcome.requirement.code;
      _activeHistoryRequirementTitle = outcome.requirement.title;
      _activeHistoryCurrentVersion = outcome.requirement.currentVersion;
      _activeHistoryCurrentSubmissionId =
          outcome.requirement.currentSubmissionId;

      final replaySuffix = outcome.idempotentReplay
          ? ' (confirmação idempotente sem duplicação)'
          : '';
      if (outcome.review.decision == ReviewDecision.approved) {
        final completedProcess =
            outcome.process.status.value == 'documentally_complete';
        _feedbackMessage = completedProcess
            ? 'Decisão registrada$replaySuffix: ${item.requirementTitle} (v${item.submissionVersion}) aprovado documentalmente. Todos os requisitos obrigatórios foram aprovados (sem pendências documentais — não representa autorização oficial de estágio).'
            : 'Decisão registrada$replaySuffix: ${item.requirementTitle} (v${item.submissionVersion}) aprovado documentalmente.';
      } else {
        _feedbackMessage =
            'Decisão registrada$replaySuffix: correção solicitada para ${item.requirementTitle} (v${item.submissionVersion}).';
      }
      _isFeedbackError = false;
      _selectedItem = null;
      _safeNotify();

      await Future.wait(<Future<void>>[
        loadQueue(preserveFeedback: true, autoSelectFirstIfNone: false),
        loadRequirementHistory(outcome.requirement.id),
        timelineController.loadTimeline(outcome.process.id),
      ]);
      return true;
    } catch (error) {
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          decisionEpoch != _decisionEpoch) {
        return false;
      }

      final failure = SupabaseReviewRepository.mapError(error);
      _isSubmittingDecision = false;

      if (failure.isAmbiguousNetworkOrTimeout) {
        // Mantém a mesma idempotency_key e justificativa para retry seguro
        _hasAmbiguousDecisionRetryPending = true;
        _decisionErrorMessage = failure.message;
        _safeNotify();
        return false;
      }

      _hasAmbiguousDecisionRetryPending = false;
      _decisionErrorMessage = failure.message;

      if (failure.isIdempotencyMismatch) {
        _pendingDecisionIdempotencyKey = generateUuidV4();
      } else if (!failure.isValidationError) {
        _pendingDecisionIdempotencyKey = null;
        _pendingDecisionSubmissionId = null;
        _pendingDecisionType = null;
        _pendingDecisionReason = null;
      }

      if (failure.isForbiddenScope) {
        _wipeLoadedPdfInternal();
        _isConfirmingDecision = false;
        _feedbackMessage = failure.message;
        _isFeedbackError = true;
        _selectedItem = null;
        _safeNotify();
        await loadQueue(preserveFeedback: true, autoSelectFirstIfNone: false);
        return false;
      }

      if (failure.shouldReloadQueue ||
          failure.isConflict ||
          failure.isNotFound ||
          failure.isProcessCancelled) {
        _wipeLoadedPdfInternal();
        _isConfirmingDecision = false;
        _feedbackMessage = failure.message;
        _isFeedbackError = true;
        _safeNotify();
        await Future.wait(<Future<void>>[
          loadQueue(preserveFeedback: true, autoSelectFirstIfNone: false),
          loadRequirementHistory(item.processRequirementId),
          timelineController.loadTimeline(item.processId),
        ]);
        return false;
      }

      _safeNotify();
      return false;
    }
  }

  void clearPrivateState() {
    ++_sessionEpoch;
    ++_queueEpoch;
    ++_pdfEpoch;
    ++_historyEpoch;
    ++_decisionEpoch;

    _wipeLoadedPdfInternal();
    timelineController.clearPrivateState();

    _queueStatus = ReviewLoadStatus.loading;
    _queueItems = const <ReviewerQueueItem>[];
    _totalQueueCount = 0;
    _queueErrorMessage = null;
    _feedbackMessage = null;
    _isFeedbackError = false;
    _selectedItem = null;
    _lastDecisionOutcome = null;

    _resetDecisionFormInternal();

    _activeHistoryRequirementId = null;
    _activeHistoryRequirementCode = null;
    _activeHistoryRequirementTitle = null;
    _activeHistoryCurrentVersion = null;
    _activeHistoryCurrentSubmissionId = null;
    _historyStatus = ReviewLoadStatus.loaded;
    _requirementSubmissions = const <DocumentSubmissionRecord>[];
    _requirementReviewsBySubmissionId = const <String, DocumentReviewRecord>{};
    _historyErrorMessage = null;
    _safeNotify();
  }

  void _invalidatePendingIdempotencyIfChanged() {
    final item = _selectedItem;
    final cleanedReason = ReviewDecisionValidation.cleanReason(_reasonText);
    if (item == null ||
        _pendingDecisionSubmissionId != item.submissionId ||
        _pendingDecisionType != _selectedDecision ||
        _pendingDecisionReason != cleanedReason) {
      _pendingDecisionIdempotencyKey = null;
      _pendingDecisionSubmissionId = null;
      _pendingDecisionType = null;
      _pendingDecisionReason = null;
      _hasAmbiguousDecisionRetryPending = false;
    }
  }

  void _resetDecisionFormInternal() {
    _selectedDecision = ReviewDecision.approved;
    _reasonText = '';
    _isConfirmingDecision = false;
    _isSubmittingDecision = false;
    _decisionErrorMessage = null;
    _pendingDecisionIdempotencyKey = null;
    _pendingDecisionSubmissionId = null;
    _pendingDecisionType = null;
    _pendingDecisionReason = null;
    _hasAmbiguousDecisionRetryPending = false;
  }

  void _wipeLoadedPdfInternal() {
    ++_pdfEpoch;
    _isLoadingPdf = false;
    _isSavingPdf = false;
    final prevDoc = _loadedPdf?.renderedDocument;
    _loadedPdf?.wipeBytes();
    _loadedPdf = null;
    _currentPdfPage = 1;
    _pdfZoomScale = 1.0;
    _pdfErrorMessage = null;
    _pdfActionMessage = null;
    unawaited(pdfRendererGateway.clearTemporaryResources(prevDoc));
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
    ++_queueEpoch;
    ++_pdfEpoch;
    ++_historyEpoch;
    ++_decisionEpoch;
    _wipeLoadedPdfInternal();
    timelineController.dispose();
    super.dispose();
  }
}
