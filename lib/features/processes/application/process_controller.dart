import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/supabase_process_repository.dart';
import '../domain/process_models.dart';
import '../domain/process_repository.dart';

enum StudentProcessSubView { dashboard, openForm, detail }

enum ProcessLoadStatus { loading, loaded, error }

class ProcessController extends ChangeNotifier {
  ProcessController({required this.repository});

  final ProcessRepository? repository;

  int _listEpoch = 0;
  int _catalogEpoch = 0;
  int _detailEpoch = 0;
  int _createEpoch = 0;
  bool _listRequestInFlight = false;
  bool _disposed = false;

  StudentProcessSubView _subView = StudentProcessSubView.dashboard;

  // Estado da listagem principal
  ProcessLoadStatus _listStatus = ProcessLoadStatus.loading;
  List<InternshipProcessSummary> _processes =
      const <InternshipProcessSummary>[];
  String? _listErrorMessage;
  String? _feedbackMessage;

  // Estado do formulário de abertura e catálogo
  ProcessLoadStatus _catalogStatus = ProcessLoadStatus.loading;
  List<CatalogModalityOption> _catalog = const <CatalogModalityOption>[];
  String? _catalogErrorMessage;
  String? _selectedInstitutionId;
  String? _selectedCourseId;
  String? _selectedModalityId;
  bool _isCreatingProcess = false;
  String? _createErrorMessage;

  // Estado de detalhes e checklist
  ProcessLoadStatus _detailStatus = ProcessLoadStatus.loading;
  String? _activeDetailProcessId;
  ProcessDetailBundle? _detailBundle;
  String? _detailErrorMessage;
  bool _detailNotFoundOrDenied = false;

  StudentProcessSubView get subView => _subView;
  ProcessLoadStatus get listStatus => _listStatus;
  List<InternshipProcessSummary> get processes => _processes;
  String? get listErrorMessage => _listErrorMessage;
  String? get feedbackMessage => _feedbackMessage;

  ProcessLoadStatus get catalogStatus => _catalogStatus;
  List<CatalogModalityOption> get catalog => _catalog;
  String? get catalogErrorMessage => _catalogErrorMessage;
  String? get selectedInstitutionId => _selectedInstitutionId;
  String? get selectedCourseId => _selectedCourseId;
  String? get selectedModalityId => _selectedModalityId;
  bool get isCreatingProcess => _isCreatingProcess;
  String? get createErrorMessage => _createErrorMessage;

  ProcessLoadStatus get detailStatus => _detailStatus;
  String? get activeDetailProcessId => _activeDetailProcessId;
  ProcessDetailBundle? get detailBundle => _detailBundle;
  String? get detailErrorMessage => _detailErrorMessage;
  bool get detailNotFoundOrDenied => _detailNotFoundOrDenied;

  List<CatalogInstitution> get availableInstitutions {
    final byId = <String, CatalogInstitution>{};
    for (final option in _catalog) {
      byId.putIfAbsent(option.institution.id, () => option.institution);
    }
    return byId.values.toList(growable: false);
  }

  List<CatalogCourse> get availableCourses {
    if (_selectedInstitutionId == null) return const <CatalogCourse>[];
    final byId = <String, CatalogCourse>{};
    for (final option in _catalog) {
      if (option.institution.id == _selectedInstitutionId) {
        byId.putIfAbsent(option.course.id, () => option.course);
      }
    }
    return byId.values.toList(growable: false);
  }

  List<CatalogModalityOption> get availableModalities {
    if (_selectedCourseId == null) return const <CatalogModalityOption>[];
    return _catalog
        .where((option) => option.course.id == _selectedCourseId)
        .toList(growable: false);
  }

  CatalogModalityOption? get selectedModalityOption {
    if (_selectedModalityId == null) return null;
    for (final option in availableModalities) {
      if (option.id == _selectedModalityId) {
        return option;
      }
    }
    return null;
  }

  bool get canSubmitCreateProcess {
    final modality = selectedModalityOption;
    return !_isCreatingProcess &&
        modality != null &&
        modality.hasPublishedTemplate;
  }

  Future<void> loadDashboard({bool clearFeedback = false}) async {
    final repo = repository;
    if (repo == null) {
      ++_listEpoch;
      _listRequestInFlight = false;
      _processes = const <InternshipProcessSummary>[];
      _listErrorMessage = null;
      _listStatus = ProcessLoadStatus.loaded;
      _safeNotify();
      return;
    }

    final currentEpoch = ++_listEpoch;
    _listRequestInFlight = true;
    _listStatus = ProcessLoadStatus.loading;
    _listErrorMessage = null;
    if (clearFeedback) {
      _feedbackMessage = null;
    }
    _safeNotify();

    try {
      final loaded = await repo.fetchStudentProcesses();
      if (_disposed || currentEpoch != _listEpoch) return;
      _listRequestInFlight = false;
      _processes = loaded;
      _listStatus = ProcessLoadStatus.loaded;
    } catch (error) {
      if (_disposed || currentEpoch != _listEpoch) return;
      _listRequestInFlight = false;
      final failure = SupabaseProcessRepository.mapError(error);
      _listErrorMessage = failure.message;
      _listStatus = ProcessLoadStatus.error;
    }
    _safeNotify();
  }

  Future<void> openCreateProcessForm() async {
    _subView = StudentProcessSubView.openForm;
    _createErrorMessage = null;
    _feedbackMessage = null;
    _safeNotify();
    await loadCatalog();
  }

  Future<void> loadCatalog() async {
    final repo = repository;
    if (repo == null) {
      ++_catalogEpoch;
      _catalog = const <CatalogModalityOption>[];
      _catalogErrorMessage = null;
      _catalogStatus = ProcessLoadStatus.loaded;
      _safeNotify();
      return;
    }

    final currentEpoch = ++_catalogEpoch;
    _catalogStatus = ProcessLoadStatus.loading;
    _catalogErrorMessage = null;
    _safeNotify();

    try {
      final loaded = await repo.fetchActiveCatalog();
      if (_disposed || currentEpoch != _catalogEpoch) return;
      _catalog = loaded;
      _catalogStatus = ProcessLoadStatus.loaded;
      _reconcileSelectionsAfterCatalogLoad();
    } catch (error) {
      if (_disposed || currentEpoch != _catalogEpoch) return;
      final failure = SupabaseProcessRepository.mapError(error);
      _catalogErrorMessage = failure.message;
      _catalogStatus = ProcessLoadStatus.error;
    }
    _safeNotify();
  }

  void selectInstitution(String? institutionId) {
    if (_selectedInstitutionId == institutionId) return;
    _selectedInstitutionId = institutionId;
    _createErrorMessage = null;

    final courses = availableCourses;
    _selectedCourseId = courses.length == 1 ? courses.first.id : null;
    final modalities = availableModalities;
    _selectedModalityId = modalities.length == 1 ? modalities.first.id : null;
    _safeNotify();
  }

  void selectCourse(String? courseId) {
    if (_selectedCourseId == courseId) return;
    _selectedCourseId = courseId;
    _createErrorMessage = null;

    final modalities = availableModalities;
    _selectedModalityId = modalities.length == 1 ? modalities.first.id : null;
    _safeNotify();
  }

  void selectModality(String? modalityId) {
    if (_selectedModalityId == modalityId) return;
    _selectedModalityId = modalityId;
    _createErrorMessage = null;
    _safeNotify();
  }

  Future<bool> submitCreateProcess() async {
    if (_isCreatingProcess) {
      return false;
    }

    final repo = repository;
    if (repo == null) {
      _createErrorMessage = 'Repositório de processos não configurado.';
      _safeNotify();
      return false;
    }

    final modality = selectedModalityOption;
    if (modality == null) {
      _createErrorMessage = 'Selecione instituição, curso e modalidade válidos antes de confirmar.';
      _safeNotify();
      return false;
    }

    if (!modality.hasPublishedTemplate) {
      _createErrorMessage = 'Configuração pendente: não há checklist publicado para esta modalidade.';
      _safeNotify();
      return false;
    }

    final currentCreateEpoch = ++_createEpoch;
    _isCreatingProcess = true;
    _createErrorMessage = null;
    _safeNotify();

    try {
      final created = await repo.createProcess(courseModalityId: modality.id);
      if (_disposed || currentCreateEpoch != _createEpoch) return false;

      _isCreatingProcess = false;
      _feedbackMessage =
          'Processo aberto com sucesso e checklist v${created.templateVersion} gerado.';

      // Atualiza listagem em memória/servidor invalidando qualquer leitura anterior pendente
      final refreshListEpoch = ++_listEpoch;
      _listRequestInFlight = true;
      try {
        final refreshedList = await repo.fetchStudentProcesses();
        if (!_disposed &&
            currentCreateEpoch == _createEpoch &&
            refreshListEpoch == _listEpoch) {
          _listRequestInFlight = false;
          _processes = refreshedList;
          _listStatus = ProcessLoadStatus.loaded;
          _listErrorMessage = null;
        }
      } catch (_) {
        if (!_disposed &&
            currentCreateEpoch == _createEpoch &&
            refreshListEpoch == _listEpoch) {
          _listRequestInFlight = false;
          _processes = <InternshipProcessSummary>[
            created,
            ..._processes.where((p) => p.id != created.id),
          ];
          _listStatus = ProcessLoadStatus.loaded;
        }
      }

      if (_disposed || currentCreateEpoch != _createEpoch) return false;
      await openProcessDetail(created.id);
      return true;
    } catch (error) {
      if (_disposed || currentCreateEpoch != _createEpoch) return false;
      final failure = SupabaseProcessRepository.mapError(error);
      _isCreatingProcess = false;
      _createErrorMessage = failure.message;
      _safeNotify();
      return false;
    }
  }

  Future<void> openProcessDetail(String processId) async {
    final repo = repository;
    _subView = StudentProcessSubView.detail;
    _activeDetailProcessId = processId;
    _detailStatus = ProcessLoadStatus.loading;
    _detailBundle = null;
    _detailErrorMessage = null;
    _detailNotFoundOrDenied = false;
    _safeNotify();

    if (repo == null) {
      ++_detailEpoch;
      _detailNotFoundOrDenied = true;
      _detailStatus = ProcessLoadStatus.loaded;
      _safeNotify();
      return;
    }

    final currentEpoch = ++_detailEpoch;
    try {
      final detail = await repo.fetchProcessDetail(processId: processId);
      if (_disposed || currentEpoch != _detailEpoch) return;

      if (detail == null) {
        _detailBundle = null;
        _detailNotFoundOrDenied = true;
        _detailStatus = ProcessLoadStatus.loaded;
      } else {
        _detailBundle = detail;
        _detailNotFoundOrDenied = false;
        _detailStatus = ProcessLoadStatus.loaded;
      }
    } catch (error) {
      if (_disposed || currentEpoch != _detailEpoch) return;
      final failure = SupabaseProcessRepository.mapError(error);
      if (failure.isNotFoundOrInaccessible) {
        _detailBundle = null;
        _detailNotFoundOrDenied = true;
        _detailStatus = ProcessLoadStatus.loaded;
      } else {
        _detailErrorMessage = failure.message;
        _detailStatus = ProcessLoadStatus.error;
      }
    }
    _safeNotify();
  }

  Future<void> refreshActiveDetail() async {
    final id = _activeDetailProcessId;
    if (id == null) return;
    await openProcessDetail(id);
  }

  /// Atualiza detalhes apenas do processo alterado e sincroniza progresso na lista.
  Future<void> refreshAfterDocumentUpdate(String processId) async {
    final repo = repository;
    if (repo == null || _disposed) return;

    if (_activeDetailProcessId == processId) {
      final currentDetailEpoch = ++_detailEpoch;
      try {
        final detail = await repo.fetchProcessDetail(processId: processId);
        if (_disposed ||
            currentDetailEpoch != _detailEpoch ||
            _activeDetailProcessId != processId) {
          return;
        }
        if (detail == null) {
          _detailBundle = null;
          _detailNotFoundOrDenied = true;
          _detailStatus = ProcessLoadStatus.loaded;
        } else {
          _detailBundle = detail;
          _detailNotFoundOrDenied = false;
          _detailStatus = ProcessLoadStatus.loaded;
        }
        _safeNotify();
      } catch (_) {
        // Preserva detalhes atuais e feedback de submissão se falhar recarga silenciosa.
      }
    }

    final currentListEpoch = ++_listEpoch;
    _listRequestInFlight = true;
    try {
      final refreshedList = await repo.fetchStudentProcesses();
      if (_disposed || currentListEpoch != _listEpoch) return;
      _listRequestInFlight = false;
      _processes = refreshedList;
      _listStatus = ProcessLoadStatus.loaded;
      _listErrorMessage = null;
      _safeNotify();
    } catch (error) {
      if (_disposed || currentListEpoch != _listEpoch) return;
      _listRequestInFlight = false;
      if (_listStatus != ProcessLoadStatus.loaded) {
        final failure = SupabaseProcessRepository.mapError(error);
        _listErrorMessage = failure.message;
        _listStatus = ProcessLoadStatus.error;
      }
      _safeNotify();
    }
  }

  void returnToDashboard() {
    _subView = StudentProcessSubView.dashboard;
    _createErrorMessage = null;
    _detailErrorMessage = null;
    if (_listStatus == ProcessLoadStatus.loading && !_listRequestInFlight) {
      unawaited(loadDashboard());
      return;
    }
    _safeNotify();
  }

  void clearPrivateState() {
    ++_listEpoch;
    ++_catalogEpoch;
    ++_detailEpoch;
    ++_createEpoch;
    _listRequestInFlight = false;
    _subView = StudentProcessSubView.dashboard;
    _listStatus = ProcessLoadStatus.loading;
    _catalogStatus = ProcessLoadStatus.loading;
    _detailStatus = ProcessLoadStatus.loading;
    _processes = const <InternshipProcessSummary>[];
    _catalog = const <CatalogModalityOption>[];
    _detailBundle = null;
    _activeDetailProcessId = null;
    _selectedInstitutionId = null;
    _selectedCourseId = null;
    _selectedModalityId = null;
    _listErrorMessage = null;
    _catalogErrorMessage = null;
    _createErrorMessage = null;
    _detailErrorMessage = null;
    _feedbackMessage = null;
    _isCreatingProcess = false;
    _detailNotFoundOrDenied = false;
    _safeNotify();
  }

  void _reconcileSelectionsAfterCatalogLoad() {
    final institutions = availableInstitutions;
    if (_selectedInstitutionId == null ||
        !institutions.any((i) => i.id == _selectedInstitutionId)) {
      _selectedInstitutionId = institutions.length == 1
          ? institutions.first.id
          : null;
    }

    final courses = availableCourses;
    if (_selectedCourseId == null ||
        !courses.any((c) => c.id == _selectedCourseId)) {
      _selectedCourseId = courses.length == 1 ? courses.first.id : null;
    }

    final modalities = availableModalities;
    if (_selectedModalityId == null ||
        !modalities.any((m) => m.id == _selectedModalityId)) {
      _selectedModalityId = modalities.length == 1 ? modalities.first.id : null;
    }
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_listEpoch;
    ++_catalogEpoch;
    ++_detailEpoch;
    ++_createEpoch;
    _listRequestInFlight = false;
    super.dispose();
  }
}
