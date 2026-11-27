import 'package:flutter/foundation.dart';

import '../data/supabase_review_repository.dart';
import '../domain/review_models.dart';
import '../domain/review_repository.dart';

enum ReviewLoadStatus { loading, loaded, error }

class ProcessTimelineController extends ChangeNotifier {
  ProcessTimelineController({
    required this.repository,
    this.pageSize = kDefaultReviewPageSize,
  });

  final ReviewRepository? repository;
  final int pageSize;

  int _sessionEpoch = 0;
  int _loadEpoch = 0;
  bool _disposed = false;

  String? _activeProcessId;
  ReviewLoadStatus _status = ReviewLoadStatus.loaded;
  List<ProcessAuditTimelineEvent> _events = const <ProcessAuditTimelineEvent>[];
  int _totalCount = 0;
  int _currentPage = 0;
  bool _oldestFirst = false;
  String? _errorMessage;

  String? get activeProcessId => _activeProcessId;
  ReviewLoadStatus get status => _status;
  List<ProcessAuditTimelineEvent> get events => _events;
  int get totalCount => _totalCount;
  int get currentPage => _currentPage;
  bool get oldestFirst => _oldestFirst;
  String? get errorMessage => _errorMessage;

  int get totalPages {
    if (_totalCount <= 0 || pageSize <= 0) {
      return 1;
    }
    return (_totalCount + pageSize - 1) ~/ pageSize;
  }

  bool get hasPreviousPage => _currentPage > 0;
  bool get hasNextPage => (_currentPage + 1) * pageSize < _totalCount;

  Future<void> loadTimeline(
    String processId, {
    int page = 0,
    bool? oldestFirst,
  }) async {
    final cleanId = processId.trim();
    final targetPage = page < 0 ? 0 : page;
    final targetOldestFirst = oldestFirst ?? _oldestFirst;

    _activeProcessId = cleanId;
    _currentPage = targetPage;
    _oldestFirst = targetOldestFirst;

    final repo = repository;
    if (repo == null || cleanId.isEmpty) {
      ++_loadEpoch;
      _events = const <ProcessAuditTimelineEvent>[];
      _totalCount = 0;
      _errorMessage = null;
      _status = ReviewLoadStatus.loaded;
      _safeNotify();
      return;
    }

    final sessionEpoch = _sessionEpoch;
    final loadEpoch = ++_loadEpoch;
    _status = ReviewLoadStatus.loading;
    _errorMessage = null;
    _safeNotify();

    try {
      final result = await repo.fetchProcessAuditTimeline(
        processId: cleanId,
        page: targetPage,
        pageSize: pageSize,
        oldestFirst: targetOldestFirst,
      );
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          loadEpoch != _loadEpoch ||
          _activeProcessId != cleanId) {
        return;
      }

      _events = result.items;
      _totalCount = result.totalCount;
      _currentPage = result.page;
      _errorMessage = null;
      _status = ReviewLoadStatus.loaded;
    } catch (error) {
      if (_disposed ||
          sessionEpoch != _sessionEpoch ||
          loadEpoch != _loadEpoch ||
          _activeProcessId != cleanId) {
        return;
      }
      final failure = SupabaseReviewRepository.mapError(error);
      _errorMessage = failure.message;
      _status = ReviewLoadStatus.error;
    }
    _safeNotify();
  }

  Future<void> refresh() async {
    final id = _activeProcessId;
    if (id == null || id.isEmpty) return;
    await loadTimeline(id, page: _currentPage, oldestFirst: _oldestFirst);
  }

  Future<void> nextPage() async {
    final id = _activeProcessId;
    if (id == null || !hasNextPage || _status == ReviewLoadStatus.loading) {
      return;
    }
    await loadTimeline(id, page: _currentPage + 1, oldestFirst: _oldestFirst);
  }

  Future<void> previousPage() async {
    final id = _activeProcessId;
    if (id == null || !hasPreviousPage || _status == ReviewLoadStatus.loading) {
      return;
    }
    await loadTimeline(id, page: _currentPage - 1, oldestFirst: _oldestFirst);
  }

  Future<void> toggleSortOrder() async {
    final id = _activeProcessId;
    if (id == null || _status == ReviewLoadStatus.loading) {
      return;
    }
    await loadTimeline(id, page: 0, oldestFirst: !_oldestFirst);
  }

  void clearPrivateState() {
    ++_sessionEpoch;
    ++_loadEpoch;
    _activeProcessId = null;
    _events = const <ProcessAuditTimelineEvent>[];
    _totalCount = 0;
    _currentPage = 0;
    _oldestFirst = false;
    _errorMessage = null;
    _status = ReviewLoadStatus.loaded;
    _safeNotify();
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
    ++_loadEpoch;
    _events = const <ProcessAuditTimelineEvent>[];
    super.dispose();
  }
}
