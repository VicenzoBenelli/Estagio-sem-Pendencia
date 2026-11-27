import 'package:flutter/material.dart';

import '../../processes/application/document_submission_controller.dart';
import '../../processes/application/process_controller.dart';
import '../../processes/data/file_picker_pdf_gateway.dart';
import '../../processes/domain/document_repository.dart';
import '../../processes/domain/process_repository.dart';
import '../../processes/presentation/student_processes_workspace.dart';
import '../../review/application/process_timeline_controller.dart';
import '../../review/application/reviewer_controller.dart';
import '../../review/data/pdf_document_renderer.dart';
import '../../review/domain/review_repository.dart';
import '../../review/presentation/reviewer_workspace.dart';
import '../application/auth_controller.dart';
import '../domain/user_profile.dart';

class StudentHomePage extends StatefulWidget {
  const StudentHomePage({
    required this.profile,
    required this.controller,
    this.processRepository,
    this.documentRepository,
    this.pdfPickerGateway,
    this.reviewRepository,
    super.key,
  });

  final UserProfile profile;
  final AuthController controller;
  final ProcessRepository? processRepository;
  final DocumentRepository? documentRepository;
  final PdfPickerGateway? pdfPickerGateway;
  final ReviewRepository? reviewRepository;

  @override
  State<StudentHomePage> createState() => _StudentHomePageState();
}

class _StudentHomePageState extends State<StudentHomePage> {
  late ProcessController _processController;
  DocumentSubmissionController? _documentController;
  ProcessTimelineController? _timelineController;

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  void _initControllers() {
    _processController = ProcessController(
      repository: widget.processRepository,
    );
    _timelineController = widget.reviewRepository == null
        ? null
        : ProcessTimelineController(repository: widget.reviewRepository);
    _documentController = widget.documentRepository == null
        ? null
        : DocumentSubmissionController(
            repository: widget.documentRepository,
            pickerGateway:
                widget.pdfPickerGateway ?? const FilePickerPdfGateway(),
            onSubmissionCommitted: (processId) async {
              await _processController.refreshAfterDocumentUpdate(processId);
              final timelineCtrl = _timelineController;
              if (timelineCtrl != null &&
                  timelineCtrl.activeProcessId == processId) {
                await timelineCtrl.refresh();
              }
            },
          );
  }

  @override
  void didUpdateWidget(covariant StudentHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.processRepository != widget.processRepository ||
        oldWidget.documentRepository != widget.documentRepository ||
        oldWidget.pdfPickerGateway != widget.pdfPickerGateway ||
        oldWidget.reviewRepository != widget.reviewRepository) {
      _disposeControllers();
      _initControllers();
    }
  }

  void _disposeControllers() {
    _documentController?.clearPrivateState();
    _documentController?.dispose();
    _documentController = null;
    _timelineController?.clearPrivateState();
    _timelineController?.dispose();
    _timelineController = null;
    _processController.clearPrivateState();
    _processController.dispose();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Estágio sem Pendência — Estudante'),
        actions: [
          IconButton(
            key: const Key('revalidate_session_button'),
            tooltip: 'Revalidar sessão',
            onPressed: widget.controller.isBusy
                ? null
                : widget.controller.revalidateSession,
            icon: const Icon(Icons.refresh),
          ),
          TextButton.icon(
            key: const Key('logout_button'),
            onPressed: widget.controller.isBusy
                ? null
                : () {
                    _documentController?.clearPrivateState();
                    _timelineController?.clearPrivateState();
                    _processController.clearPrivateState();
                    widget.controller.signOut();
                  },
            icon: const Icon(Icons.logout),
            label: const Text('Sair'),
          ),
        ],
      ),
      body: SafeArea(
        child: StudentProcessesWorkspace(
          profile: widget.profile,
          controller: _processController,
          documentController: _documentController,
          timelineController: _timelineController,
        ),
      ),
    );
  }
}

class ReviewerHomePage extends StatefulWidget {
  const ReviewerHomePage({
    required this.profile,
    required this.controller,
    this.reviewRepository,
    this.pdfPickerGateway,
    this.pdfRendererGateway,
    super.key,
  });

  final UserProfile profile;
  final AuthController controller;
  final ReviewRepository? reviewRepository;
  final PdfPickerGateway? pdfPickerGateway;
  final PdfRendererGateway? pdfRendererGateway;

  @override
  State<ReviewerHomePage> createState() => _ReviewerHomePageState();
}

class _ReviewerHomePageState extends State<ReviewerHomePage> {
  late ReviewerController _reviewerController;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  void _initController() {
    _reviewerController = ReviewerController(
      repository: widget.reviewRepository,
      pickerGateway: widget.pdfPickerGateway ?? const FilePickerPdfGateway(),
      pdfRendererGateway: widget.pdfRendererGateway,
    );
  }

  @override
  void didUpdateWidget(covariant ReviewerHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.reviewRepository != widget.reviewRepository ||
        oldWidget.pdfPickerGateway != widget.pdfPickerGateway ||
        oldWidget.pdfRendererGateway != widget.pdfRendererGateway) {
      _disposeController();
      _initController();
    }
  }

  void _disposeController() {
    _reviewerController.clearPrivateState();
    _reviewerController.dispose();
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Estágio sem Pendência — Revisor'),
        actions: [
          IconButton(
            key: const Key('revalidate_session_button'),
            tooltip: 'Revalidar sessão',
            onPressed: widget.controller.isBusy
                ? null
                : widget.controller.revalidateSession,
            icon: const Icon(Icons.refresh),
          ),
          TextButton.icon(
            key: const Key('logout_button'),
            onPressed: widget.controller.isBusy
                ? null
                : () {
                    _reviewerController.clearPrivateState();
                    widget.controller.signOut();
                  },
            icon: const Icon(Icons.logout),
            label: const Text('Sair'),
          ),
        ],
      ),
      body: SafeArea(
        child: ReviewerWorkspace(
          profile: widget.profile,
          controller: _reviewerController,
        ),
      ),
    );
  }
}
