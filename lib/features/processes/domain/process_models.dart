enum ProcessStatus {
  inProgress('in_progress', 'Em andamento'),
  documentallyComplete('documentally_complete', 'Sem pendências documentais'),
  cancelled('cancelled', 'Cancelado');

  const ProcessStatus(this.value, this.label);

  final String value;
  final String label;

  static ProcessStatus fromDatabase(String? raw) {
    return switch (raw) {
      'in_progress' => ProcessStatus.inProgress,
      'documentally_complete' => ProcessStatus.documentallyComplete,
      'cancelled' => ProcessStatus.cancelled,
      _ => ProcessStatus.inProgress,
    };
  }
}

enum RequirementStatus {
  notSubmitted('not_submitted', 'Não enviado'),
  underReview('under_review', 'Em análise'),
  correctionRequested('correction_requested', 'Correção solicitada'),
  approved('approved', 'Aprovado');

  const RequirementStatus(this.value, this.label);

  final String value;
  final String label;

  static RequirementStatus fromDatabase(String? raw) {
    return switch (raw) {
      'not_submitted' => RequirementStatus.notSubmitted,
      'under_review' => RequirementStatus.underReview,
      'correction_requested' => RequirementStatus.correctionRequested,
      'approved' => RequirementStatus.approved,
      _ => RequirementStatus.notSubmitted,
    };
  }
}

enum ProgressStatus {
  indeterminate('indeterminate', 'Indeterminado'),
  inProgress('in_progress', 'Em andamento'),
  documentallyComplete('documentally_complete', 'Sem pendências documentais');

  const ProgressStatus(this.value, this.label);

  final String value;
  final String label;

  static ProgressStatus fromDatabase(String? raw) {
    return switch (raw) {
      'indeterminate' => ProgressStatus.indeterminate,
      'in_progress' => ProgressStatus.inProgress,
      'documentally_complete' => ProgressStatus.documentallyComplete,
      _ => ProgressStatus.indeterminate,
    };
  }
}

class CatalogInstitution {
  const CatalogInstitution({
    required this.id,
    required this.code,
    required this.name,
    required this.isDemo,
    required this.active,
  });

  factory CatalogInstitution.fromMap(Map<String, dynamic> map) {
    return CatalogInstitution(
      id: map['id'] as String,
      code: (map['code'] as String?) ?? '',
      name: (map['name'] as String?) ?? 'Instituição não identificada',
      isDemo: (map['is_demo'] as bool?) ?? true,
      active: (map['active'] as bool?) ?? true,
    );
  }

  final String id;
  final String code;
  final String name;
  final bool isDemo;
  final bool active;
}

class CatalogCourse {
  const CatalogCourse({
    required this.id,
    required this.institutionId,
    required this.code,
    required this.name,
    required this.isDemo,
    required this.active,
    required this.institution,
  });

  factory CatalogCourse.fromMap(Map<String, dynamic> map) {
    final instMap = _asMap(map['institutions']);
    final institution = instMap != null
        ? CatalogInstitution.fromMap(instMap)
        : CatalogInstitution(
            id: (map['institution_id'] as String?) ?? '',
            code: '',
            name: 'Instituição',
            isDemo: true,
            active: true,
          );
    return CatalogCourse(
      id: map['id'] as String,
      institutionId: (map['institution_id'] as String?) ?? institution.id,
      code: (map['code'] as String?) ?? '',
      name: (map['name'] as String?) ?? 'Curso não identificado',
      isDemo: (map['is_demo'] as bool?) ?? true,
      active: (map['active'] as bool?) ?? true,
      institution: institution,
    );
  }

  final String id;
  final String institutionId;
  final String code;
  final String name;
  final bool isDemo;
  final bool active;
  final CatalogInstitution institution;
}

class PublishedTemplateSummary {
  const PublishedTemplateSummary({
    required this.id,
    required this.version,
    required this.title,
    required this.sourceReference,
    required this.status,
    required this.isDemo,
  });

  factory PublishedTemplateSummary.fromMap(Map<String, dynamic> map) {
    return PublishedTemplateSummary(
      id: map['id'] as String,
      version: _asInt(map['version'], fallback: 1),
      title: (map['title'] as String?) ?? 'Checklist publicado',
      sourceReference: (map['source_reference'] as String?) ?? '',
      status: (map['status'] as String?) ?? 'published',
      isDemo: (map['is_demo'] as bool?) ?? true,
    );
  }

  final String id;
  final int version;
  final String title;
  final String sourceReference;
  final String status;
  final bool isDemo;
}

class CatalogModalityOption {
  const CatalogModalityOption({
    required this.id,
    required this.courseId,
    required this.code,
    required this.name,
    required this.isMandatory,
    required this.isDemo,
    required this.active,
    required this.course,
    this.publishedTemplate,
  });

  factory CatalogModalityOption.fromMap(Map<String, dynamic> map) {
    final courseMap = _asMap(map['courses']);
    if (courseMap == null) {
      throw const FormatException(
        'Modalidade do catálogo sem vínculo de curso ativo.',
      );
    }
    final course = CatalogCourse.fromMap(courseMap);
    final rawTemplates = map['requirement_templates'];
    PublishedTemplateSummary? published;

    if (rawTemplates is List) {
      for (final item in rawTemplates) {
        final itemMap = _asMap(item);
        if (itemMap != null &&
            ((itemMap['status'] as String?) ?? 'published') == 'published') {
          final candidate = PublishedTemplateSummary.fromMap(itemMap);
          if (published == null || candidate.version > published.version) {
            published = candidate;
          }
        }
      }
    } else {
      final itemMap = _asMap(rawTemplates);
      if (itemMap != null &&
          ((itemMap['status'] as String?) ?? 'published') == 'published') {
        published = PublishedTemplateSummary.fromMap(itemMap);
      }
    }

    return CatalogModalityOption(
      id: map['id'] as String,
      courseId: (map['course_id'] as String?) ?? course.id,
      code: (map['code'] as String?) ?? '',
      name: (map['name'] as String?) ?? 'Modalidade não identificada',
      isMandatory: (map['is_mandatory'] as bool?) ?? true,
      isDemo:
          ((map['is_demo'] as bool?) ?? true) ||
          course.isDemo ||
          course.institution.isDemo,
      active: (map['active'] as bool?) ?? true,
      course: course,
      publishedTemplate: published,
    );
  }

  final String id;
  final String courseId;
  final String code;
  final String name;
  final bool isMandatory;
  final bool isDemo;
  final bool active;
  final CatalogCourse course;
  final PublishedTemplateSummary? publishedTemplate;

  CatalogInstitution get institution => course.institution;
  bool get hasPublishedTemplate => publishedTemplate != null;
}

class ProcessProgressSummary {
  const ProcessProgressSummary({
    required this.processId,
    required this.ownerId,
    required this.processStatus,
    required this.requiredTotal,
    required this.requiredApproved,
    required this.requiredUnderReview,
    required this.requiredCorrectionRequested,
    required this.progressStatus,
    required this.progressPercentage,
  });

  factory ProcessProgressSummary.fromMap(Map<String, dynamic> map) {
    final total = _asInt(map['required_total']);
    final status = ProgressStatus.fromDatabase(
      map['progress_status'] as String?,
    );
    final rawPct = map['progress_percentage'];
    double? pct;
    if (rawPct is num) {
      pct = rawPct.toDouble();
    } else if (rawPct is String && rawPct.trim().isNotEmpty) {
      pct = double.tryParse(rawPct.trim());
    }
    if (total <= 0 || status == ProgressStatus.indeterminate) {
      pct = null;
    }

    return ProcessProgressSummary(
      processId: map['process_id'] as String,
      ownerId: (map['owner_id'] as String?) ?? '',
      processStatus: ProcessStatus.fromDatabase(
        map['process_status'] as String?,
      ),
      requiredTotal: total,
      requiredApproved: _asInt(map['required_approved']),
      requiredUnderReview: _asInt(map['required_under_review']),
      requiredCorrectionRequested: _asInt(map['required_correction_requested']),
      progressStatus: total <= 0 ? ProgressStatus.indeterminate : status,
      progressPercentage: pct,
    );
  }

  final String processId;
  final String ownerId;
  final ProcessStatus processStatus;
  final int requiredTotal;
  final int requiredApproved;
  final int requiredUnderReview;
  final int requiredCorrectionRequested;
  final ProgressStatus progressStatus;
  final double? progressPercentage;

  bool get isIndeterminate =>
      progressStatus == ProgressStatus.indeterminate ||
      progressPercentage == null ||
      requiredTotal <= 0;
}

class InternshipProcessSummary {
  const InternshipProcessSummary({
    required this.id,
    required this.ownerId,
    required this.institutionId,
    required this.courseId,
    required this.courseModalityId,
    required this.templateId,
    required this.templateVersion,
    required this.status,
    required this.isDemo,
    required this.openedAt,
    required this.createdAt,
    required this.updatedAt,
    this.closedAt,
    this.institutionName,
    this.institutionCode,
    this.courseName,
    this.courseCode,
    this.modalityName,
    this.modalityCode,
    this.isMandatoryModality,
    this.templateTitle,
    this.templateSourceReference,
    this.progress,
  });

  factory InternshipProcessSummary.fromMap(
    Map<String, dynamic> map, {
    ProcessProgressSummary? progress,
  }) {
    final instMap = _asMap(map['institutions']);
    final courseMap = _asMap(map['courses']);
    final modalityMap = _asMap(map['course_modalities']);
    final templateMap = _asMap(map['requirement_templates']);

    return InternshipProcessSummary(
      id: map['id'] as String,
      ownerId: (map['owner_id'] as String?) ?? '',
      institutionId: (map['institution_id'] as String?) ?? '',
      courseId: (map['course_id'] as String?) ?? '',
      courseModalityId: (map['course_modality_id'] as String?) ?? '',
      templateId: (map['template_id'] as String?) ?? '',
      templateVersion: _asInt(map['template_version'], fallback: 1),
      status: ProcessStatus.fromDatabase(map['status'] as String?),
      isDemo: (map['is_demo'] as bool?) ?? true,
      openedAt: _parseDateTime(map['opened_at']),
      closedAt: map['closed_at'] == null
          ? null
          : _parseDateTime(map['closed_at']),
      createdAt: _parseDateTime(map['created_at']),
      updatedAt: _parseDateTime(map['updated_at']),
      institutionName: instMap?['name'] as String?,
      institutionCode: instMap?['code'] as String?,
      courseName: courseMap?['name'] as String?,
      courseCode: courseMap?['code'] as String?,
      modalityName: modalityMap?['name'] as String?,
      modalityCode: modalityMap?['code'] as String?,
      isMandatoryModality: modalityMap?['is_mandatory'] as bool?,
      templateTitle: templateMap?['title'] as String?,
      templateSourceReference: templateMap?['source_reference'] as String?,
      progress: progress,
    );
  }

  final String id;
  final String ownerId;
  final String institutionId;
  final String courseId;
  final String courseModalityId;
  final String templateId;
  final int templateVersion;
  final ProcessStatus status;
  final bool isDemo;
  final DateTime openedAt;
  final DateTime? closedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? institutionName;
  final String? institutionCode;
  final String? courseName;
  final String? courseCode;
  final String? modalityName;
  final String? modalityCode;
  final bool? isMandatoryModality;
  final String? templateTitle;
  final String? templateSourceReference;
  final ProcessProgressSummary? progress;

  String get displayInstitutionName =>
      (institutionName != null && institutionName!.trim().isNotEmpty)
      ? institutionName!.trim()
      : 'Instituição vinculada ao processo';

  String get displayCourseName =>
      (courseName != null && courseName!.trim().isNotEmpty)
      ? courseName!.trim()
      : 'Curso vinculado ao processo';

  String get displayModalityName =>
      (modalityName != null && modalityName!.trim().isNotEmpty)
      ? modalityName!.trim()
      : 'Modalidade vinculada ao processo';

  String get displayTemplateTitle =>
      (templateTitle != null && templateTitle!.trim().isNotEmpty)
      ? templateTitle!.trim()
      : 'Checklist v$templateVersion';

  InternshipProcessSummary copyWith({ProcessProgressSummary? progress}) {
    return InternshipProcessSummary(
      id: id,
      ownerId: ownerId,
      institutionId: institutionId,
      courseId: courseId,
      courseModalityId: courseModalityId,
      templateId: templateId,
      templateVersion: templateVersion,
      status: status,
      isDemo: isDemo,
      openedAt: openedAt,
      closedAt: closedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      institutionName: institutionName,
      institutionCode: institutionCode,
      courseName: courseName,
      courseCode: courseCode,
      modalityName: modalityName,
      modalityCode: modalityCode,
      isMandatoryModality: isMandatoryModality,
      templateTitle: templateTitle,
      templateSourceReference: templateSourceReference,
      progress: progress ?? this.progress,
    );
  }
}

class ProcessRequirementItem {
  const ProcessRequirementItem({
    required this.id,
    required this.processId,
    required this.templateItemId,
    required this.code,
    required this.title,
    required this.description,
    required this.acceptanceCriteria,
    required this.isRequired,
    required this.displayOrder,
    required this.status,
    required this.currentVersion,
    required this.createdAt,
    required this.updatedAt,
    this.currentSubmissionId,
  });

  factory ProcessRequirementItem.fromMap(Map<String, dynamic> map) {
    return ProcessRequirementItem(
      id: map['id'] as String,
      processId: (map['process_id'] as String?) ?? '',
      templateItemId: (map['template_item_id'] as String?) ?? '',
      code: (map['code'] as String?) ?? '',
      title: (map['title'] as String?) ?? 'Requisito documental',
      description: (map['description'] as String?) ?? '',
      acceptanceCriteria: (map['acceptance_criteria'] as String?) ?? '',
      isRequired: (map['is_required'] as bool?) ?? true,
      displayOrder: _asInt(map['display_order'], fallback: 1),
      status: RequirementStatus.fromDatabase(map['status'] as String?),
      currentSubmissionId: map['current_submission_id'] as String?,
      currentVersion: _asInt(map['current_version']),
      createdAt: _parseDateTime(map['created_at']),
      updatedAt: _parseDateTime(map['updated_at']),
    );
  }

  final String id;
  final String processId;
  final String templateItemId;
  final String code;
  final String title;
  final String description;
  final String acceptanceCriteria;
  final bool isRequired;
  final int displayOrder;
  final RequirementStatus status;
  final String? currentSubmissionId;
  final int currentVersion;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class ProcessDetailBundle {
  const ProcessDetailBundle({
    required this.process,
    required this.requirements,
    required this.progress,
  });

  final InternshipProcessSummary process;
  final List<ProcessRequirementItem> requirements;
  final ProcessProgressSummary? progress;
}

class ProcessFailure implements Exception {
  const ProcessFailure(
    this.message, {
    this.code,
    this.isUnauthorized = false,
    this.isNotFoundOrInaccessible = false,
    this.isConflict = false,
  });

  final String message;
  final String? code;
  final bool isUnauthorized;
  final bool isNotFoundOrInaccessible;
  final bool isConflict;

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

int _asInt(Object? raw, {int fallback = 0}) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? fallback;
  return fallback;
}

DateTime _parseDateTime(Object? raw) {
  if (raw is DateTime) return raw;
  if (raw is String && raw.trim().isNotEmpty) {
    return DateTime.tryParse(raw.trim())?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
