import 'dart:typed_data';

import '../../processes/domain/document_models.dart';
import 'review_models.dart';

abstract interface class ReviewRepository {
  Future<PaginatedResult<ReviewerQueueItem>> fetchReviewerQueue({
    ReviewerQueueQuery query = const ReviewerQueueQuery(),
  });

  Future<Uint8List> downloadSubmissionBytes({required String submissionId});

  Future<ReviewDecisionOutcome> reviewSubmission({
    required String submissionId,
    required ReviewDecision decision,
    String? reason,
    String? idempotencyKey,
  });

  Future<List<DocumentSubmissionRecord>> fetchRequirementSubmissions({
    required String processRequirementId,
  });

  Future<List<DocumentReviewRecord>> fetchRequirementReviews({
    required String processRequirementId,
  });

  Future<PaginatedResult<ProcessAuditTimelineEvent>> fetchProcessAuditTimeline({
    required String processId,
    int page = 0,
    int pageSize = kDefaultReviewPageSize,
    bool oldestFirst = false,
  });
}
