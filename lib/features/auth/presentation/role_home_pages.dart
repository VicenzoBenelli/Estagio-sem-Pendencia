import 'package:flutter/material.dart';

import '../../../core/responsive/app_breakpoints.dart';
import '../../processes/application/document_submission_controller.dart';
import '../../processes/application/process_controller.dart';
import '../../processes/data/file_picker_pdf_gateway.dart';
import '../../processes/domain/document_repository.dart';
import '../../processes/domain/process_repository.dart';
import '../../processes/presentation/student_processes_workspace.dart';
import '../application/auth_controller.dart';
import '../domain/user_profile.dart';

class StudentHomePage extends StatefulWidget {
  const StudentHomePage({
    required this.profile,
    required this.controller,
    this.processRepository,
    this.documentRepository,
    this.pdfPickerGateway,
    super.key,
  });

  final UserProfile profile;
  final AuthController controller;
  final ProcessRepository? processRepository;
  final DocumentRepository? documentRepository;
  final PdfPickerGateway? pdfPickerGateway;

  @override
  State<StudentHomePage> createState() => _StudentHomePageState();
}

class _StudentHomePageState extends State<StudentHomePage> {
  late ProcessController _processController;
  DocumentSubmissionController? _documentController;

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  void _initControllers() {
    _processController = ProcessController(
      repository: widget.processRepository,
    );
    _documentController = widget.documentRepository == null
        ? null
        : DocumentSubmissionController(
            repository: widget.documentRepository,
            pickerGateway:
                widget.pdfPickerGateway ?? const FilePickerPdfGateway(),
            onSubmissionCommitted:
                _processController.refreshAfterDocumentUpdate,
          );
  }

  @override
  void didUpdateWidget(covariant StudentHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.processRepository != widget.processRepository ||
        oldWidget.documentRepository != widget.documentRepository ||
        oldWidget.pdfPickerGateway != widget.pdfPickerGateway) {
      _disposeControllers();
      _initControllers();
    }
  }

  void _disposeControllers() {
    _documentController?.clearPrivateState();
    _documentController?.dispose();
    _documentController = null;
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
        ),
      ),
    );
  }
}

class ReviewerHomePage extends StatelessWidget {
  const ReviewerHomePage({
    required this.profile,
    required this.controller,
    super.key,
  });

  final UserProfile profile;
  final AuthController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _AuthenticatedRoleShell(
      profile: profile,
      controller: controller,
      appBarTitle: 'Estágio sem Pendência — Revisor',
      badgeLabel: 'Perfil Revisor (Escopo Protegido)',
      badgeIcon: Icons.fact_check_outlined,
      badgeBackground: colors.tertiaryContainer,
      badgeForeground: colors.onTertiaryContainer,
      scopeTitle: 'Painel inicial do revisor autenticado',
      scopeDescription: 'Seu papel foi verificado no backend com isolamento por atribuição de escopo (reviewer_assignments). A fila de revisão documental e o histórico de decisões serão habilitados nos próximos lotes.',
      disclaimer: 'Aprovação documental no MVP não equivale a autorização oficial de estágio.',
    );
  }
}

class _AuthenticatedRoleShell extends StatelessWidget {
  const _AuthenticatedRoleShell({
    required this.profile,
    required this.controller,
    required this.appBarTitle,
    required this.badgeLabel,
    required this.badgeIcon,
    required this.badgeBackground,
    required this.badgeForeground,
    required this.scopeTitle,
    required this.scopeDescription,
    required this.disclaimer,
  });

  final UserProfile profile;
  final AuthController controller;
  final String appBarTitle;
  final String badgeLabel;
  final IconData badgeIcon;
  final Color badgeBackground;
  final Color badgeForeground;
  final String scopeTitle;
  final String scopeDescription;
  final String disclaimer;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(appBarTitle),
        actions: [
          IconButton(
            key: const Key('revalidate_session_button'),
            tooltip: 'Revalidar sessão',
            onPressed: controller.isBusy ? null : controller.revalidateSession,
            icon: const Icon(Icons.refresh),
          ),
          TextButton.icon(
            key: const Key('logout_button'),
            onPressed: controller.isBusy ? null : controller.signOut,
            icon: const Icon(Icons.logout),
            label: const Text('Sair'),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < AppBreakpoints.compact;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(compact ? 20 : 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 24 : 36),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: badgeBackground,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    badgeIcon,
                                    size: 20,
                                    color: badgeForeground,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    badgeLabel,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(color: badgeForeground),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            profile.displayName,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            profile.email,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            scopeTitle,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: colors.primary),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            scopeDescription,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 20),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.secondaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    color: colors.onSecondaryContainer,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      disclaimer,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: colors.onSecondaryContainer,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
