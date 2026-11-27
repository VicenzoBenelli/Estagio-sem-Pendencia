import 'dart:typed_data';

import 'document_models.dart';

abstract interface class PdfPickerGateway {
  Future<SelectedPdfFile?> pickPdf();

  Future<bool> savePdf({required String filename, required Uint8List bytes});
}

abstract interface class DocumentRepository {
  Future<SubmitPdfOutcome> submitRequirementPdf({
    required String processRequirementId,
    required SelectedPdfFile file,
    required String idempotencyKey,
  });

  Future<DocumentSubmissionRecord?> findSubmissionByIdempotencyKey({
    required String processRequirementId,
    required String idempotencyKey,
  });

  Future<List<DocumentSubmissionRecord>> fetchRequirementSubmissions({
    required String processRequirementId,
  });

  Future<List<DocumentReviewRecord>> fetchRequirementReviews({
    required String processRequirementId,
  });

  Future<Uint8List> downloadSubmissionBytes({required String submissionId});
}
