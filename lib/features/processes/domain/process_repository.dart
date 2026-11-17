import 'process_models.dart';

abstract interface class ProcessRepository {
  Future<List<CatalogModalityOption>> fetchActiveCatalog();

  Future<List<InternshipProcessSummary>> fetchStudentProcesses();

  Future<InternshipProcessSummary> createProcess({
    required String courseModalityId,
  });

  Future<ProcessDetailBundle?> fetchProcessDetail({required String processId});
}
