import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/responsive/app_breakpoints.dart';
import '../../auth/domain/user_profile.dart';
import '../../review/application/process_timeline_controller.dart';
import '../../review/presentation/process_audit_timeline_section.dart';
import '../application/document_submission_controller.dart';
import '../application/process_controller.dart';
import '../domain/process_models.dart';
import 'requirement_documents_section.dart';

class StudentProcessesWorkspace extends StatefulWidget {
  const StudentProcessesWorkspace({
    required this.profile,
    required this.controller,
    this.documentController,
    this.timelineController,
    super.key,
  });

  final UserProfile profile;
  final ProcessController controller;
  final DocumentSubmissionController? documentController;
  final ProcessTimelineController? timelineController;

  @override
  State<StudentProcessesWorkspace> createState() =>
      _StudentProcessesWorkspaceState();
}

class _StudentProcessesWorkspaceState extends State<StudentProcessesWorkspace> {
  ProcessDetailBundle? _lastSyncedDetailBundle;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncDocumentsIfDetailChanged);
    unawaited(widget.controller.loadDashboard());
  }

  @override
  void didUpdateWidget(covariant StudentProcessesWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncDocumentsIfDetailChanged);
      widget.controller.addListener(_syncDocumentsIfDetailChanged);
      _lastSyncedDetailBundle = null;
    }
    if (oldWidget.documentController != widget.documentController ||
        oldWidget.timelineController != widget.timelineController) {
      _lastSyncedDetailBundle = null;
    }
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.controller != widget.controller) {
      unawaited(widget.controller.loadDashboard(clearFeedback: true));
    }
    _syncDocumentsIfDetailChanged();
  }

  void _syncDocumentsIfDetailChanged() {
    final docCtrl = widget.documentController;
    final timelineCtrl = widget.timelineController;
    if (docCtrl == null && timelineCtrl == null) return;
    if (widget.controller.subView == StudentProcessSubView.detail &&
        widget.controller.detailStatus == ProcessLoadStatus.loaded &&
        widget.controller.detailBundle != null) {
      final bundle = widget.controller.detailBundle!;
      if (!identical(bundle, _lastSyncedDetailBundle)) {
        _lastSyncedDetailBundle = bundle;
        docCtrl?.syncWithProcessDetail(bundle);
        if (timelineCtrl != null &&
            timelineCtrl.activeProcessId != bundle.process.id) {
          unawaited(timelineCtrl.loadTimeline(bundle.process.id));
        }
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncDocumentsIfDetailChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final canPopRoute =
            widget.controller.subView == StudentProcessSubView.dashboard;
        return PopScope(
          canPop: canPopRoute,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && !widget.controller.isCreatingProcess) {
              widget.controller.returnToDashboard();
            }
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < AppBreakpoints.compact;
              return SingleChildScrollView(
                padding: EdgeInsets.all(compact ? 16 : 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _StudentHeaderCard(
                          profile: widget.profile,
                          compact: compact,
                        ),
                        const SizedBox(height: 16),
                        switch (widget.controller.subView) {
                          StudentProcessSubView.dashboard =>
                            _ProcessesDashboardView(
                              controller: widget.controller,
                              compact: compact,
                            ),
                          StudentProcessSubView.openForm =>
                            _CreateProcessFormView(
                              profile: widget.profile,
                              controller: widget.controller,
                              compact: compact,
                            ),
                          StudentProcessSubView.detail => _ProcessDetailView(
                            controller: widget.controller,
                            documentController: widget.documentController,
                            timelineController: widget.timelineController,
                            userRole: widget.profile.role,
                            compact: compact,
                          ),
                        },
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _StudentHeaderCard extends StatelessWidget {
  const _StudentHeaderCard({required this.profile, required this.compact});

  final UserProfile profile;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
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
                          Icons.school_outlined,
                          size: 20,
                          color: colors.onPrimaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Perfil Estudante',
                            style: textTheme.labelLarge?.copyWith(
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(profile.displayName, style: textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              profile.email,
              style: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            const _NormativeDisclaimerBanner(),
          ],
        ),
      ),
    );
  }
}

class _NormativeDisclaimerBanner extends StatelessWidget {
  const _NormativeDisclaimerBanner();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              size: 20,
              color: colors.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'A conclusão documental não representa autorização oficial de estágio pela instituição de ensino.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessesDashboardView extends StatelessWidget {
  const _ProcessesDashboardView({
    required this.controller,
    required this.compact,
  });

  final ProcessController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Meus processos de estágio',
                      style: textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Acompanhe seus processos e consulte o checklist versionado de cada modalidade.',
                      style: textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('refresh_processes_button'),
                      onPressed:
                          controller.listStatus == ProcessLoadStatus.loading
                          ? null
                          : () => controller.loadDashboard(clearFeedback: true),
                      icon: const Icon(Icons.sync),
                      label: const Text('Atualizar lista'),
                    ),
                    FilledButton.icon(
                      key: const Key('open_create_process_button'),
                      onPressed: controller.openCreateProcessForm,
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Abrir processo de estágio'),
                    ),
                  ],
                ),
              ],
            ),
            if (controller.feedbackMessage != null) ...[
              const SizedBox(height: 16),
              _MessageBanner(
                key: const Key('process_feedback_banner'),
                icon: Icons.check_circle_outline,
                message: controller.feedbackMessage!,
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
              ),
            ],
            const SizedBox(height: 20),
            switch (controller.listStatus) {
              ProcessLoadStatus.loading => const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Carregando processos de estágio...'),
                    ],
                  ),
                ),
              ),
              ProcessLoadStatus.error => _ErrorRetryBox(
                message:
                    controller.listErrorMessage ??
                    'Não foi possível carregar seus processos.',
                retryButtonKey: const Key('processes_retry_button'),
                onRetry: () => controller.loadDashboard(clearFeedback: true),
              ),
              ProcessLoadStatus.loaded =>
                controller.processes.isEmpty
                    ? _EmptyProcessesBox(
                        onOpenCreate: controller.openCreateProcessForm,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final process in controller.processes) ...[
                            _ProcessSummaryCard(
                              process: process,
                              onOpenDetail: () =>
                                  controller.openProcessDetail(process.id),
                            ),
                            const SizedBox(height: 12),
                          ],
                        ],
                      ),
            },
          ],
        ),
      ),
    );
  }
}

class _EmptyProcessesBox extends StatelessWidget {
  const _EmptyProcessesBox({required this.onOpenCreate});

  final VoidCallback onOpenCreate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      key: const Key('processes_empty_state'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.folder_open_outlined, size: 40, color: colors.primary),
            const SizedBox(height: 12),
            Text(
              'Nenhum processo de estágio aberto',
              style: textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Você ainda não abriu um processo de acompanhamento documental. Selecione instituição, curso e modalidade para gerar o checklist aplicável.',
              style: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('empty_open_process_button'),
              onPressed: onOpenCreate,
              icon: const Icon(Icons.add),
              label: const Text('Abrir primeiro processo'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessSummaryCard extends StatelessWidget {
  const _ProcessSummaryCard({
    required this.process,
    required this.onOpenDetail,
  });

  final InternshipProcessSummary process;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final progress = process.progress;

    return DecoratedBox(
      key: Key('process_card_${process.id}'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _ProcessStatusBadge(status: process.status),
                _ChipBadge(
                  icon: Icons.layers_outlined,
                  label: 'Checklist v${process.templateVersion}',
                  backgroundColor: colors.secondaryContainer,
                  foregroundColor: colors.onSecondaryContainer,
                ),
                if (process.isDemo)
                  _ChipBadge(
                    icon: Icons.science_outlined,
                    label: 'Catálogo fictício de demonstração',
                    backgroundColor: colors.surfaceContainerHighest,
                    foregroundColor: colors.onSurfaceVariant,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(process.displayCourseName, style: textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              process.displayModalityName,
              style: textTheme.bodyLarge?.copyWith(color: colors.primary),
            ),
            const SizedBox(height: 4),
            Text(
              process.displayInstitutionName,
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Data de abertura: ${_formatDate(process.openedAt)}',
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            if (progress != null) ...[
              const SizedBox(height: 8),
              Text(
                progress.isIndeterminate
                    ? 'Progresso obrigatório: Indeterminado (sem requisitos obrigatórios)'
                    : 'Progresso obrigatório: ${progress.requiredApproved} de ${progress.requiredTotal} aprovados (${progress.progressPercentage!.toStringAsFixed(0)}%)',
                style: textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                key: Key('open_process_detail_${process.id}'),
                onPressed: onOpenDetail,
                icon: const Icon(Icons.checklist_outlined),
                label: const Text('Ver detalhes e checklist'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateProcessFormView extends StatelessWidget {
  const _CreateProcessFormView({
    required this.profile,
    required this.controller,
    required this.compact,
  });

  final UserProfile profile;
  final ProcessController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final institutions = controller.availableInstitutions;
    final courses = controller.availableCourses;
    final modalities = controller.availableModalities;
    final selectedModality = controller.selectedModalityOption;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  key: const Key('back_to_processes_button'),
                  onPressed: controller.isCreatingProcess
                      ? null
                      : controller.returnToDashboard,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Voltar para processos'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Abrir novo processo de estágio', style: textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'O processo será vinculado exclusivamente ao seu perfil autenticado (${profile.email}). Os dados de demonstração do catálogo são fictícios e não representam normas oficiais.',
              style: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            switch (controller.catalogStatus) {
              ProcessLoadStatus.loading => const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Carregando catálogo ativo...'),
                    ],
                  ),
                ),
              ),
              ProcessLoadStatus.error => _ErrorRetryBox(
                message: controller.catalogErrorMessage ?? 'Não foi possível carregar o catálogo de cursos e modalidades.',
                retryButtonKey: const Key('catalog_retry_button'),
                onRetry: controller.loadCatalog,
              ),
              ProcessLoadStatus.loaded =>
                institutions.isEmpty
                    ? _ErrorRetryBox(
                        message: 'Nenhuma instituição, curso ou modalidade ativa disponível no catálogo.',
                        retryButtonKey: const Key('catalog_retry_button'),
                        onRetry: controller.loadCatalog,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DropdownButtonFormField<String>(
                            key: const Key('select_institution_field'),
                            isExpanded: true,
                            initialValue: controller.selectedInstitutionId,
                            decoration: const InputDecoration(
                              labelText: 'Instituição',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final inst in institutions)
                                DropdownMenuItem<String>(
                                  value: inst.id,
                                  child: Text(
                                    inst.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: controller.isCreatingProcess
                                ? null
                                : controller.selectInstitution,
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'select_course_${controller.selectedInstitutionId ?? 'none'}',
                            ),
                            isExpanded: true,
                            initialValue: controller.selectedCourseId,
                            decoration: const InputDecoration(
                              labelText: 'Curso',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final course in courses)
                                DropdownMenuItem<String>(
                                  value: course.id,
                                  child: Text(
                                    course.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged:
                                (controller.isCreatingProcess ||
                                    courses.isEmpty)
                                ? null
                                : controller.selectCourse,
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            key: const Key('select_modality_field'),
                            isExpanded: true,
                            initialValue: controller.selectedModalityId,
                            decoration: const InputDecoration(
                              labelText: 'Modalidade de estágio',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final mod in modalities)
                                DropdownMenuItem<String>(
                                  value: mod.id,
                                  child: Text(
                                    mod.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged:
                                (controller.isCreatingProcess ||
                                    modalities.isEmpty)
                                ? null
                                : controller.selectModality,
                          ),
                          const SizedBox(height: 16),
                          if (selectedModality != null)
                            selectedModality.hasPublishedTemplate
                                ? _PublishedTemplateCard(
                                    template:
                                        selectedModality.publishedTemplate!,
                                  )
                                : _MessageBanner(
                                    key: const Key('missing_template_warning'),
                                    icon: Icons.warning_amber_rounded,
                                    message: 'Configuração pendente: não há checklist publicado para esta modalidade. A abertura de processo está indisponível até a publicação do template.',
                                    backgroundColor: colors.errorContainer,
                                    foregroundColor: colors.onErrorContainer,
                                  ),
                          if (controller.createErrorMessage != null) ...[
                            const SizedBox(height: 16),
                            _MessageBanner(
                              key: const Key('create_process_error_banner'),
                              icon: Icons.error_outline,
                              message: controller.createErrorMessage!,
                              backgroundColor: colors.errorContainer,
                              foregroundColor: colors.onErrorContainer,
                            ),
                          ],
                          const SizedBox(height: 20),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            alignment: WrapAlignment.end,
                            children: [
                              OutlinedButton(
                                onPressed: controller.isCreatingProcess
                                    ? null
                                    : controller.returnToDashboard,
                                child: const Text('Cancelar'),
                              ),
                              FilledButton.icon(
                                key: const Key('submit_create_process_button'),
                                onPressed: controller.canSubmitCreateProcess
                                    ? controller.submitCreateProcess
                                    : null,
                                icon: controller.isCreatingProcess
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.check),
                                label: Text(
                                  controller.isCreatingProcess
                                      ? 'Abrindo...'
                                      : 'Confirmar abertura',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
            },
          ],
        ),
      ),
    );
  }
}

class _PublishedTemplateCard extends StatelessWidget {
  const _PublishedTemplateCard({required this.template});

  final PublishedTemplateSummary template;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      key: const Key('published_template_info_card'),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.primary.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_outlined, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Checklist aplicável: ${template.title} (v${template.version})',
                    style: textTheme.titleSmall?.copyWith(
                      color: colors.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            if (template.sourceReference.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Origem: ${template.sourceReference}',
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProcessDetailView extends StatelessWidget {
  const _ProcessDetailView({
    required this.controller,
    required this.documentController,
    required this.timelineController,
    required this.userRole,
    required this.compact,
  });

  final ProcessController controller;
  final DocumentSubmissionController? documentController;
  final ProcessTimelineController? timelineController;
  final UserRole userRole;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  key: const Key('detail_back_button'),
                  onPressed: controller.returnToDashboard,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Voltar para processos'),
                ),
                OutlinedButton.icon(
                  key: const Key('detail_refresh_button'),
                  onPressed:
                      controller.detailStatus == ProcessLoadStatus.loading
                      ? null
                      : () {
                          unawaited(controller.refreshActiveDetail());
                          unawaited(
                            documentController?.reloadExpandedHistories() ??
                                Future<void>.value(),
                          );
                          unawaited(
                            timelineController?.refresh() ??
                                Future<void>.value(),
                          );
                        },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Atualizar checklist'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            switch (controller.detailStatus) {
              ProcessLoadStatus.loading => const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Carregando detalhes e checklist do processo...'),
                    ],
                  ),
                ),
              ),
              ProcessLoadStatus.error => _ErrorRetryBox(
                message:
                    controller.detailErrorMessage ??
                    'Não foi possível carregar os detalhes do processo.',
                retryButtonKey: const Key('detail_retry_button'),
                onRetry: controller.refreshActiveDetail,
              ),
              ProcessLoadStatus.loaded =>
                controller.detailNotFoundOrDenied ||
                        controller.detailBundle == null
                    ? _ProcessNotFoundOrDeniedBox(
                        onReturn: controller.returnToDashboard,
                      )
                    : _ProcessDetailLoadedContent(
                        bundle: controller.detailBundle!,
                        documentController: documentController,
                        timelineController: timelineController,
                        userRole: userRole,
                        textTheme: textTheme,
                        colors: colors,
                      ),
            },
          ],
        ),
      ),
    );
  }
}

class _ProcessNotFoundOrDeniedBox extends StatelessWidget {
  const _ProcessNotFoundOrDeniedBox({required this.onReturn});

  final VoidCallback onReturn;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      key: const Key('process_not_found_view'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.lock_outline, size: 38, color: colors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Processo não encontrado ou indisponível para sua conta.',
              style: textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Por segurança, registros inexistentes ou pertencentes a outros usuários não podem ser exibidos.',
              style: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onReturn,
              child: const Text('Voltar ao painel de processos'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessDetailLoadedContent extends StatelessWidget {
  const _ProcessDetailLoadedContent({
    required this.bundle,
    required this.documentController,
    required this.timelineController,
    required this.userRole,
    required this.textTheme,
    required this.colors,
  });

  final ProcessDetailBundle bundle;
  final DocumentSubmissionController? documentController;
  final ProcessTimelineController? timelineController;
  final UserRole userRole;
  final TextTheme textTheme;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final process = bundle.process;
    final progress = bundle.progress ?? process.progress;
    final requirements = bundle.requirements;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _ProcessStatusBadge(status: process.status),
            _ChipBadge(
              key: const Key('process_template_version_label'),
              icon: Icons.layers_outlined,
              label: 'Versão do template: v${process.templateVersion}',
              backgroundColor: colors.secondaryContainer,
              foregroundColor: colors.onSecondaryContainer,
            ),
            if (process.isDemo)
              _ChipBadge(
                icon: Icons.science_outlined,
                label: 'Dados fictícios de demonstração',
                backgroundColor: colors.surfaceContainerHighest,
                foregroundColor: colors.onSurfaceVariant,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(process.displayCourseName, style: textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          process.displayModalityName,
          style: textTheme.titleMedium?.copyWith(color: colors.primary),
        ),
        const SizedBox(height: 4),
        Text(
          process.displayInstitutionName,
          style: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Text(
          'Data de abertura: ${_formatDate(process.openedAt)}',
          style: textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        _ProgressOverviewCard(progress: progress),
        const SizedBox(height: 16),
        if (documentController == null)
          _MessageBanner(
            key: const Key('pdf_upload_future_stage_notice'),
            icon: Icons.picture_as_pdf_outlined,
            message: 'O envio privado de documentos PDF será disponibilizado em etapa posterior do MVP. Os status abaixo refletem os registros atuais no servidor.',
            backgroundColor: colors.surfaceContainerHighest,
            foregroundColor: colors.onSurfaceVariant,
          )
        else
          _MessageBanner(
            key: const Key('pdf_upload_active_notice'),
            icon: Icons.picture_as_pdf_outlined,
            message: 'Envio privado de documentos PDF (máx. 5 MiB): documentos enviados seguem para análise e não representam aprovação ou autorização oficial.',
            backgroundColor: colors.surfaceContainerHighest,
            foregroundColor: colors.onSurfaceVariant,
          ),
        const SizedBox(height: 20),
        Text(
          'Checklist de requisitos (${requirements.length})',
          style: textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (requirements.isEmpty)
          const Text('Nenhum requisito encontrado para este processo.')
        else
          for (final item in requirements) ...[
            _RequirementItemCard(
              item: item,
              processStatus: process.status,
              userRole: userRole,
              documentController: documentController,
            ),
            const SizedBox(height: 12),
          ],
        if (timelineController != null) ...[
          const SizedBox(height: 12),
          ProcessAuditTimelineSection(controller: timelineController!),
        ],
      ],
    );
  }
}

class _ProgressOverviewCard extends StatelessWidget {
  const _ProgressOverviewCard({required this.progress});

  final ProcessProgressSummary? progress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isIndeterminate = progress == null || progress!.isIndeterminate;

    return DecoratedBox(
      key: const Key('process_progress_card'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Progresso documental', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            if (isIndeterminate) ...[
              Row(
                children: [
                  Icon(Icons.help_outline, color: colors.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Estado indeterminado: não há requisitos obrigatórios configurados para calcular percentual.',
                      key: const Key('progress_indeterminate_label'),
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Text(
                '${progress!.requiredApproved} de ${progress!.requiredTotal} obrigatórios aprovados (${progress!.progressPercentage!.toStringAsFixed(0)}%)',
                key: const Key('progress_percentage_label'),
                style: textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: (progress!.progressPercentage! / 100.0).clamp(0.0, 1.0),
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  Text(
                    'Aprovados: ${progress!.requiredApproved}',
                    style: textTheme.bodySmall,
                  ),
                  Text(
                    'Em análise: ${progress!.requiredUnderReview}',
                    style: textTheme.bodySmall,
                  ),
                  Text(
                    'Correção solicitada: ${progress!.requiredCorrectionRequested}',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Itens opcionais não bloqueiam a conclusão documental. A conclusão documental não representa autorização oficial de estágio pela instituição de ensino.',
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequirementItemCard extends StatelessWidget {
  const _RequirementItemCard({
    required this.item,
    required this.processStatus,
    required this.userRole,
    required this.documentController,
  });

  final ProcessRequirementItem item;
  final ProcessStatus processStatus;
  final UserRole userRole;
  final DocumentSubmissionController? documentController;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      key: Key('requirement_card_${item.code}'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _ChipBadge(
                  icon: item.isRequired
                      ? Icons.priority_high_rounded
                      : Icons.bookmark_border,
                  label: item.isRequired ? 'Obrigatório' : 'Opcional',
                  backgroundColor: item.isRequired
                      ? colors.primaryContainer
                      : colors.surfaceContainerHighest,
                  foregroundColor: item.isRequired
                      ? colors.onPrimaryContainer
                      : colors.onSurfaceVariant,
                ),
                _RequirementStatusBadge(status: item.status),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${item.displayOrder}. ${item.title}',
              style: textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Código: ${item.code}',
              style: textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(item.description, style: textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(
              'Critério de aceite: ${item.acceptanceCriteria}',
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.currentVersion > 0
                  ? 'Versão da submissão: v${item.currentVersion}'
                  : 'Submissão: nenhuma versão enviada',
              key: Key('requirement_version_${item.code}'),
              style: textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (documentController != null)
              RequirementDocumentsSection(
                item: item,
                processStatus: processStatus,
                userRole: userRole,
                controller: documentController!,
              ),
          ],
        ),
      ),
    );
  }
}

class _ProcessStatusBadge extends StatelessWidget {
  const _ProcessStatusBadge({required this.status});

  final ProcessStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, bg, fg) = switch (status) {
      ProcessStatus.inProgress => (
        Icons.timelapse_outlined,
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      ProcessStatus.documentallyComplete => (
        Icons.verified_outlined,
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      ProcessStatus.cancelled => (
        Icons.cancel_outlined,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
    };

    return _ChipBadge(
      icon: icon,
      label: status.label,
      backgroundColor: bg,
      foregroundColor: fg,
    );
  }
}

class _RequirementStatusBadge extends StatelessWidget {
  const _RequirementStatusBadge({required this.status});

  final RequirementStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, bg, fg) = switch (status) {
      RequirementStatus.notSubmitted => (
        Icons.radio_button_unchecked,
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      RequirementStatus.underReview => (
        Icons.hourglass_top_rounded,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      RequirementStatus.correctionRequested => (
        Icons.edit_note_rounded,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      RequirementStatus.approved => (
        Icons.check_circle_outline,
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
    };

    return _ChipBadge(
      icon: icon,
      label: status.label,
      backgroundColor: bg,
      foregroundColor: fg,
    );
  }
}

class _ChipBadge extends StatelessWidget {
  const _ChipBadge({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    super.key,
  });

  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: foregroundColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: foregroundColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({
    required this.icon,
    required this.message,
    required this.backgroundColor,
    required this.foregroundColor,
    super.key,
  });

  final IconData icon;
  final String message;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: foregroundColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: foregroundColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRetryBox extends StatelessWidget {
  const _ErrorRetryBox({
    required this.message,
    required this.retryButtonKey,
    required this.onRetry,
  });

  final String message;
  final Key retryButtonKey;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: colors.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: colors.onErrorContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                key: retryButtonKey,
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Tentar novamente'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime dateTime) {
  final local = dateTime.toLocal();
  final d = local.day.toString().padLeft(2, '0');
  final m = local.month.toString().padLeft(2, '0');
  final y = local.year.toString().padLeft(4, '0');
  return '$d/$m/$y';
}
