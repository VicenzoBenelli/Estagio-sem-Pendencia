import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/process_models.dart';
import '../domain/process_repository.dart';

class SupabaseProcessRepository implements ProcessRepository {
  const SupabaseProcessRepository(this._client);

  final SupabaseClient _client;

  static const String _processSelectColumns =
      'id, owner_id, institution_id, course_id, course_modality_id, '
      'template_id, template_version, status, is_demo, opened_at, closed_at, '
      'created_at, updated_at, '
      'institutions(id, code, name), '
      'courses(id, code, name), '
      'course_modalities(id, code, name, is_mandatory), '
      'requirement_templates(id, version, title, source_reference)';

  static const String _progressSelectColumns =
      'process_id, owner_id, process_status, required_total, '
      'required_approved, required_under_review, required_correction_requested, '
      'progress_status, progress_percentage';

  @override
  Future<List<CatalogModalityOption>> fetchActiveCatalog() async {
    try {
      final rows = await _client
          .from('course_modalities')
          .select(
            'id, course_id, code, name, is_mandatory, is_demo, active, '
            'courses!inner(id, institution_id, code, name, is_demo, active, '
            'institutions!inner(id, code, name, is_demo, active)), '
            'requirement_templates(id, version, title, source_reference, status, is_demo)',
          )
          .eq('active', true)
          .eq('courses.active', true)
          .eq('courses.institutions.active', true)
          .eq('requirement_templates.status', 'published')
          .order('name', ascending: true);

      final result = <CatalogModalityOption>[];
      for (final raw in rows) {
        final item = CatalogModalityOption.fromMap(raw);
        if (item.active && item.course.active && item.institution.active) {
          result.add(item);
        }
      }
      return result;
    } on ProcessFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  @override
  Future<List<InternshipProcessSummary>> fetchStudentProcesses() async {
    try {
      // Sem !inner para preservar visibilidade de processos históricos cujo catálogo venha a ser desativado.
      final rows = await _client
          .from('internship_processes')
          .select(_processSelectColumns)
          .order('opened_at', ascending: false);

      final summaries = rows
          .map((row) => InternshipProcessSummary.fromMap(row))
          .toList(growable: false);

      if (summaries.isEmpty) {
        return const <InternshipProcessSummary>[];
      }

      final ids = summaries.map((p) => p.id).toList(growable: false);
      final progressRows = await _client
          .from('process_progress_v')
          .select(_progressSelectColumns)
          .inFilter('process_id', ids);

      final progressByProcessId = <String, ProcessProgressSummary>{
        for (final row in progressRows)
          (row['process_id'] as String): ProcessProgressSummary.fromMap(row),
      };

      return summaries
          .map((p) => p.copyWith(progress: progressByProcessId[p.id]))
          .toList(growable: false);
    } on ProcessFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  @override
  Future<InternshipProcessSummary> createProcess({
    required String courseModalityId,
  }) async {
    try {
      final dynamic rpcResult = await _client.rpc(
        'create_internship_process',
        params: <String, dynamic>{
          'p_course_modality_id': courseModalityId.trim(),
        },
      );

      if (rpcResult is! Map) {
        throw const ProcessFailure(
          'Resposta inesperada do servidor ao abrir o processo.',
        );
      }

      final createdMap = rpcResult.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final created = InternshipProcessSummary.fromMap(createdMap);

      final enrichedRow = await _client
          .from('internship_processes')
          .select(_processSelectColumns)
          .eq('id', created.id)
          .maybeSingle();

      if (enrichedRow != null) {
        return InternshipProcessSummary.fromMap(enrichedRow);
      }
      return created;
    } on ProcessFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  @override
  Future<ProcessDetailBundle?> fetchProcessDetail({
    required String processId,
  }) async {
    try {
      final processRow = await _client
          .from('internship_processes')
          .select(_processSelectColumns)
          .eq('id', processId)
          .maybeSingle();

      if (processRow == null) {
        return null;
      }

      final requirementRows = await _client
          .from('process_requirements')
          .select(
            'id, process_id, template_item_id, code, title, description, '
            'acceptance_criteria, is_required, display_order, status, '
            'current_submission_id, current_version, created_at, updated_at',
          )
          .eq('process_id', processId)
          .order('display_order', ascending: true);

      final progressRow = await _client
          .from('process_progress_v')
          .select(_progressSelectColumns)
          .eq('process_id', processId)
          .maybeSingle();

      final progress = progressRow != null
          ? ProcessProgressSummary.fromMap(progressRow)
          : null;
      final process = InternshipProcessSummary.fromMap(
        processRow,
        progress: progress,
      );
      final requirements = requirementRows
          .map(ProcessRequirementItem.fromMap)
          .toList(growable: false);

      return ProcessDetailBundle(
        process: process,
        requirements: requirements,
        progress: progress,
      );
    } on ProcessFailure {
      rethrow;
    } catch (error) {
      throw mapError(error);
    }
  }

  static ProcessFailure mapError(Object error) {
    if (error is ProcessFailure) {
      return error;
    }

    if (error is PostgrestException) {
      final code = (error.code ?? '').trim().toUpperCase();
      switch (code) {
        case '42501':
        case 'PGRST301':
          return const ProcessFailure(
            'Acesso não autorizado ou sessão expirada. Entre novamente.',
            code: '42501',
            isUnauthorized: true,
          );
        case '22023':
          return const ProcessFailure(
            'Selecione uma modalidade de estágio válida para continuar.',
            code: '22023',
          );
        case 'P0002':
          return const ProcessFailure(
            'A modalidade de estágio selecionada não foi encontrada.',
            code: 'P0002',
            isNotFoundOrInaccessible: true,
          );
        case '23505':
          return const ProcessFailure(
            'Já existe um processo ativo para este curso e modalidade.',
            code: '23505',
            isConflict: true,
          );
        case '23514':
          return const ProcessFailure(
            'Catálogo ou checklist publicado indisponível para a modalidade selecionada.',
            code: '23514',
          );
        case 'PGRST202':
          return const ProcessFailure(
            'Contrato da operação de abertura incompatível com o servidor.',
            code: 'PGRST202',
          );
        default:
          return const ProcessFailure(
            'Não foi possível concluir a operação no servidor. Tente novamente.',
          );
      }
    }

    if (error is AuthException) {
      return const ProcessFailure(
        'Sua sessão expirou ou é inválida. Entre novamente.',
        code: '42501',
        isUnauthorized: true,
      );
    }

    final text = error.toString().toLowerCase();
    if (text.contains('socketexception') ||
        text.contains('clientexception') ||
        text.contains('failed host lookup') ||
        text.contains('connection refused') ||
        text.contains('network')) {
      return const ProcessFailure(
        'Não foi possível conectar ao servidor. Verifique sua conexão e tente novamente.',
        code: 'network_error',
      );
    }

    return const ProcessFailure(
      'Não foi possível concluir a operação no momento. Tente novamente.',
    );
  }
}
