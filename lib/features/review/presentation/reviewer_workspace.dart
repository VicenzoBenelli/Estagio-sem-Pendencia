import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/responsive/app_breakpoints.dart';
import '../../auth/domain/user_profile.dart';
import '../../processes/domain/document_models.dart';
import '../application/process_timeline_controller.dart';
import '../application/reviewer_controller.dart';
import '../domain/review_models.dart';
import 'pdf_document_viewer.dart';
import 'process_audit_timeline_section.dart';

class ReviewerWorkspace extends StatefulWidget {
  const ReviewerWorkspace({
    required this.profile,
    required this.controller,
    super.key,
  });

  final UserProfile profile;
  final ReviewerController controller;

  @override
  State<ReviewerWorkspace> createState() => _ReviewerWorkspaceState();
}

class _ReviewerWorkspaceState extends State<ReviewerWorkspace> {
  late final TextEditingController _searchTextController;
  late final TextEditingController _reasonTextController;
  String? _lastSyncedSubmissionId;

  @override
  void initState() {
    super.initState();
    _searchTextController = TextEditingController(
      text: widget.controller.query.searchQuery,
    );
    _reasonTextController = TextEditingController(
      text: widget.controller.reasonText,
    );
    widget.controller.addListener(_syncControllersWithState);
    unawaited(widget.controller.loadQueue());
  }

  @override
  void didUpdateWidget(covariant ReviewerWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncControllersWithState);
      widget.controller.addListener(_syncControllersWithState);
      _lastSyncedSubmissionId = null;
    }
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.controller != widget.controller) {
      _searchTextController.text = widget.controller.query.searchQuery;
      _reasonTextController.text = widget.controller.reasonText;
      unawaited(widget.controller.loadQueue());
    }
  }

  void _syncControllersWithState() {
    final currentSearch = widget.controller.query.searchQuery;
    if (_searchTextController.text != currentSearch &&
        currentSearch.isEmpty &&
        !widget.controller.query.hasActiveFilters) {
      _searchTextController.text = '';
    }

    final selectedSubId = widget.controller.selectedItem?.submissionId;
    if (selectedSubId != _lastSyncedSubmissionId ||
        widget.controller.reasonText.isEmpty) {
      _lastSyncedSubmissionId = selectedSubId;
      if (_reasonTextController.text != widget.controller.reasonText) {
        _reasonTextController.text = widget.controller.reasonText;
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncControllersWithState);
    _searchTextController.dispose();
    _reasonTextController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < AppBreakpoints.compact;
            final wideSplit = constraints.maxWidth >= AppBreakpoints.medium;

            return SingleChildScrollView(
              padding: EdgeInsets.all(compact ? 14 : 28),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1240),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ReviewerHeaderCard(
                        profile: widget.profile,
                        compact: compact,
                      ),
                      if (widget.controller.feedbackMessage != null) ...[
                        const SizedBox(height: 16),
                        _ReviewerBanner(
                          key: const Key('reviewer_feedback_banner'),
                          icon: widget.controller.isFeedbackError
                              ? Icons.warning_amber_rounded
                              : Icons.check_circle_outline,
                          message: widget.controller.feedbackMessage!,
                          isError: widget.controller.isFeedbackError,
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (wideSplit)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 5,
                              child: _ReviewerQueueCard(
                                controller: widget.controller,
                                searchController: _searchTextController,
                                compact: compact,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              flex: 7,
                              child: _ReviewerInspectionAndDecisionColumn(
                                controller: widget.controller,
                                reasonController: _reasonTextController,
                                compact: compact,
                              ),
                            ),
                          ],
                        )
                      else ...[
                        _ReviewerQueueCard(
                          controller: widget.controller,
                          searchController: _searchTextController,
                          compact: compact,
                        ),
                        const SizedBox(height: 16),
                        _ReviewerInspectionAndDecisionColumn(
                          controller: widget.controller,
                          reasonController: _reasonTextController,
                          compact: compact,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ReviewerHeaderCard extends StatelessWidget {
  const _ReviewerHeaderCard({required this.profile, required this.compact});

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
                    color: colors.tertiaryContainer,
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
                          Icons.fact_check_outlined,
                          size: 20,
                          color: colors.onTertiaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Perfil Revisor (Escopo Protegido)',
                            style: textTheme.labelLarge?.copyWith(
                              color: colors.onTertiaryContainer,
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
            Text(profile.displayName, style: textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              profile.email,
              style: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            DecoratedBox(
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
                        'Aprovação documental no MVP não equivale a autorização oficial de estágio.',
                        style: textTheme.bodyMedium?.copyWith(
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
    );
  }
}

class _ReviewerQueueCard extends StatelessWidget {
  const _ReviewerQueueCard({
    required this.controller,
    required this.searchController,
    required this.compact,
  });

  final ReviewerController controller;
  final TextEditingController searchController;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final query = controller.query;

    return Card(
      key: const Key('reviewer_queue_card'),
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Fila de documentos para revisão (${controller.totalQueueCount})',
                      style: textTheme.titleLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Apenas versões vigentes em análise dentro do seu escopo ativo.',
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                OutlinedButton.icon(
                  key: const Key('reviewer_refresh_queue_button'),
                  onPressed: controller.queueStatus == ReviewLoadStatus.loading
                      ? null
                      : () => controller.loadQueue(preserveFeedback: false),
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('Atualizar fila'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('reviewer_search_field'),
                    controller: searchController,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      labelText: 'Buscar por estudante, requisito ou curso',
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: searchController.text.isNotEmpty
                          ? IconButton(
                              key: const Key('reviewer_clear_search_button'),
                              tooltip: 'Limpar busca',
                              onPressed: () {
                                searchController.clear();
                                unawaited(controller.updateSearchQuery(''));
                              },
                              icon: const Icon(Icons.clear, size: 18),
                            )
                          : null,
                    ),
                    onSubmitted: (value) =>
                        unawaited(controller.updateSearchQuery(value)),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: const Key('reviewer_apply_search_button'),
                  onPressed: controller.queueStatus == ReviewLoadStatus.loading
                      ? null
                      : () => unawaited(
                          controller.updateSearchQuery(searchController.text),
                        ),
                  child: const Text('Filtrar'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  key: const Key('reviewer_filter_required_only'),
                  label: const Text('Apenas obrigatórios'),
                  selected: query.onlyRequired == true,
                  onSelected: controller.queueStatus == ReviewLoadStatus.loading
                      ? null
                      : (selected) => unawaited(
                          controller.setOnlyRequiredFilter(
                            selected ? true : null,
                          ),
                        ),
                ),
                FilterChip(
                  key: const Key('reviewer_filter_optional_only'),
                  label: const Text('Apenas opcionais'),
                  selected: query.onlyRequired == false,
                  onSelected: controller.queueStatus == ReviewLoadStatus.loading
                      ? null
                      : (selected) => unawaited(
                          controller.setOnlyRequiredFilter(
                            selected ? false : null,
                          ),
                        ),
                ),
                FilterChip(
                  key: const Key('reviewer_filter_resubmission_only'),
                  label: const Text('Reenvios pós-correção'),
                  selected: query.onlyResubmissions == true,
                  onSelected: controller.queueStatus == ReviewLoadStatus.loading
                      ? null
                      : (selected) => unawaited(
                          controller.setOnlyResubmissionsFilter(
                            selected ? true : null,
                          ),
                        ),
                ),
                TextButton.icon(
                  key: const Key('reviewer_sort_order_button'),
                  onPressed: controller.queueStatus == ReviewLoadStatus.loading
                      ? null
                      : () => unawaited(controller.toggleQueueSortOrder()),
                  icon: const Icon(Icons.swap_vert, size: 18),
                  label: Text(
                    query.oldestFirst
                        ? 'Ordem: mais antigos (FIFO)'
                        : 'Ordem: mais recentes',
                  ),
                ),
                if (query.hasActiveFilters)
                  TextButton.icon(
                    key: const Key('reviewer_clear_filters_button'),
                    onPressed:
                        controller.queueStatus == ReviewLoadStatus.loading
                        ? null
                        : () {
                            searchController.clear();
                            unawaited(controller.clearFilters());
                          },
                    icon: const Icon(Icons.filter_alt_off, size: 18),
                    label: const Text('Limpar filtros'),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            switch (controller.queueStatus) {
              ReviewLoadStatus.loading => const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Carregando fila de revisão...'),
                    ],
                  ),
                ),
              ),
              ReviewLoadStatus.error => DecoratedBox(
                key: const Key('reviewer_queue_error_box'),
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
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: colors.onErrorContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              controller.queueErrorMessage ?? 'Não foi possível carregar a fila de revisão.',
                              style: textTheme.bodyMedium?.copyWith(
                                color: colors.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonalIcon(
                          key: const Key('reviewer_queue_retry_button'),
                          onPressed: () =>
                              controller.loadQueue(preserveFeedback: false),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Tentar novamente'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ReviewLoadStatus.loaded =>
                controller.queueItems.isEmpty
                    ? _EmptyQueueBox(
                        hasFilters: query.hasActiveFilters,
                        onClearFilters: () {
                          searchController.clear();
                          unawaited(controller.clearFilters());
                        },
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final item in controller.queueItems) ...[
                            _QueueSubmissionTile(
                              item: item,
                              isSelected:
                                  controller.selectedItem?.submissionId ==
                                  item.submissionId,
                              onSelect: () => controller.selectQueueItem(item),
                            ),
                            const SizedBox(height: 10),
                          ],
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                'Página ${query.page + 1} de ${controller.totalQueuePages} (Total: ${controller.totalQueueCount})',
                                key: const Key('reviewer_queue_page_indicator'),
                                style: textTheme.labelMedium,
                              ),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    key: const Key(
                                      'reviewer_queue_prev_page_button',
                                    ),
                                    onPressed: controller.hasPreviousQueuePage
                                        ? controller.previousQueuePage
                                        : null,
                                    icon: const Icon(
                                      Icons.chevron_left,
                                      size: 18,
                                    ),
                                    label: const Text('Anterior'),
                                  ),
                                  OutlinedButton.icon(
                                    key: const Key(
                                      'reviewer_queue_next_page_button',
                                    ),
                                    onPressed: controller.hasNextQueuePage
                                        ? controller.nextQueuePage
                                        : null,
                                    icon: const Icon(
                                      Icons.chevron_right,
                                      size: 18,
                                    ),
                                    label: const Text('Próxima'),
                                  ),
                                ],
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

class _EmptyQueueBox extends StatelessWidget {
  const _EmptyQueueBox({
    required this.hasFilters,
    required this.onClearFilters,
  });

  final bool hasFilters;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      key: const Key('reviewer_queue_empty_state'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.inbox_outlined, size: 38, color: colors.primary),
            const SizedBox(height: 10),
            Text(
              hasFilters
                  ? 'Nenhum documento encontrado para os filtros aplicados'
                  : 'Nenhum documento pendente de revisão no seu escopo atribuído',
              style: textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              hasFilters
                  ? 'Limpe ou ajuste os filtros para visualizar outras submissões vigentes em análise.'
                  : 'Somente submissões vigentes em status Em análise dentro de atribuições ativas (reviewer_assignments) são listadas aqui.',
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (hasFilters) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const Key('reviewer_empty_clear_filters_button'),
                onPressed: onClearFilters,
                icon: const Icon(Icons.filter_alt_off, size: 18),
                label: const Text('Limpar filtros'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QueueSubmissionTile extends StatelessWidget {
  const _QueueSubmissionTile({
    required this.item,
    required this.isSelected,
    required this.onSelect,
  });

  final ReviewerQueueItem item;
  final bool isSelected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      key: Key('reviewer_queue_item_${item.submissionId}'),
      decoration: BoxDecoration(
        color: isSelected
            ? colors.primaryContainer.withValues(alpha: 0.35)
            : colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? colors.primary : colors.outlineVariant,
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: InkWell(
        key: Key('select_queue_submission_${item.submissionId}'),
        borderRadius: BorderRadius.circular(12),
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _QueueChip(
                    label: 'Versão v${item.submissionVersion}',
                    backgroundColor: colors.primaryContainer,
                    foregroundColor: colors.onPrimaryContainer,
                  ),
                  if (item.isResubmission)
                    _QueueChip(
                      key: Key('resubmission_badge_${item.submissionId}'),
                      label: 'Reenvio após correção',
                      backgroundColor: colors.tertiaryContainer,
                      foregroundColor: colors.onTertiaryContainer,
                    ),
                  _QueueChip(
                    label: item.isRequired
                        ? 'Item obrigatório'
                        : 'Item opcional',
                    backgroundColor: colors.surfaceContainerHighest,
                    foregroundColor: colors.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                item.requirementTitle,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Código: ${item.requirementCode} • Estudante: ${item.studentName}',
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '${item.displayCourseName} — ${item.displayModalityName}',
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    'Arquivo: ${item.displayFilename} (${item.formattedSize})',
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    'Enviado em: ${_formatLocalDateTime(item.submittedAt)}',
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewerInspectionAndDecisionColumn extends StatelessWidget {
  const _ReviewerInspectionAndDecisionColumn({
    required this.controller,
    required this.reasonController,
    required this.compact,
  });

  final ReviewerController controller;
  final TextEditingController reasonController;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedItem;
    final hasHistoryContext = controller.activeHistoryRequirementId != null;
    final hasTimelineContext =
        controller.timelineController.activeProcessId != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (selected != null) ...[
          _SelectedSubmissionInspectionCard(
            item: selected,
            controller: controller,
            reasonController: reasonController,
            compact: compact,
          ),
          const SizedBox(height: 16),
        ] else ...[
          _NoSelectedSubmissionPlaceholder(
            hasLastOutcome: controller.lastDecisionOutcome != null,
          ),
          const SizedBox(height: 16),
        ],
        if (hasHistoryContext) ...[
          _ReviewerRequirementHistoryCard(
            controller: controller,
            compact: compact,
          ),
          const SizedBox(height: 16),
        ],
        if (hasTimelineContext)
          ProcessAuditTimelineSection(
            controller: controller.timelineController,
          ),
      ],
    );
  }
}

class _NoSelectedSubmissionPlaceholder extends StatelessWidget {
  const _NoSelectedSubmissionPlaceholder({required this.hasLastOutcome});

  final bool hasLastOutcome;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: const Key('reviewer_no_selection_card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              hasLastOutcome
                  ? Icons.task_alt_outlined
                  : Icons.touch_app_outlined,
              size: 36,
              color: colors.primary,
            ),
            const SizedBox(height: 10),
            Text(
              hasLastOutcome
                  ? 'Decisão concluída e fila sincronizada'
                  : 'Selecione um documento na fila para inspecionar e decidir',
              style: textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              hasLastOutcome
                  ? 'O histórico atualizado do requisito e a trilha de auditoria do processo permanecem visíveis abaixo. Selecione outro item na fila para continuar.'
                  : 'A visualização autenticada do PDF, os metadados da versão vigente e o formulário de aprovação ou solicitação de correção serão exibidos aqui.',
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectedSubmissionInspectionCard extends StatelessWidget {
  const _SelectedSubmissionInspectionCard({
    required this.item,
    required this.controller,
    required this.reasonController,
    required this.compact,
  });

  final ReviewerQueueItem item;
  final ReviewerController controller;
  final TextEditingController reasonController;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final loadedPdf = controller.loadedPdf;

    return Card(
      key: Key('reviewer_inspection_card_${item.submissionId}'),
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Metadados obrigatórios da versão vigente (ESP-19 RN3)
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _QueueChip(
                  key: const Key('inspected_version_badge'),
                  label:
                      'Versão vigente em análise: v${item.submissionVersion}',
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                ),
                if (item.isResubmission)
                  _QueueChip(
                    label: 'Reenvio após solicitação de correção',
                    backgroundColor: colors.tertiaryContainer,
                    foregroundColor: colors.onTertiaryContainer,
                  ),
                _QueueChip(
                  label: item.isRequired
                      ? 'Requisito obrigatório'
                      : 'Requisito opcional',
                  backgroundColor: colors.secondaryContainer,
                  foregroundColor: colors.onSecondaryContainer,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(item.requirementTitle, style: textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'Código do requisito: ${item.requirementCode} • Checklist v${item.templateVersion}',
              style: textTheme.labelLarge?.copyWith(color: colors.primary),
            ),
            const SizedBox(height: 10),
            DecoratedBox(
              key: const Key('reviewer_submission_metadata_box'),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Estudante: ${item.studentName}',
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Curso / Modalidade: ${item.displayCourseName} — ${item.displayModalityName}',
                      style: textTheme.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Instituição: ${item.displayInstitutionName}',
                      style: textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Arquivo enviado: ${item.displayFilename} (${item.formattedSize})',
                      style: textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Data/hora do envio (local): ${_formatLocalDateTime(item.submittedAt)}',
                      style: textTheme.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'ID da submissão: ${item.submissionId}',
                      key: const Key('inspected_submission_id_label'),
                      style: textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (item.sha256Checksum != null &&
                        item.sha256Checksum!.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'SHA-256: ${item.sha256Checksum}',
                        style: textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 2. Visualização segura de PDF pelo Storage autenticado (ESP-19)
            Text(
              'Visualização autenticada do documento PDF',
              style: textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Acesso exclusivo via download autenticado de sessão (sem URL pública nem link assinado). Os bytes são zerados da memória ao trocar de item ou encerrar a sessão.',
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('reviewer_load_pdf_button'),
                  onPressed:
                      (controller.isLoadingPdf ||
                          controller.isSubmittingDecision)
                      ? null
                      : () => unawaited(
                          controller.loadAuthenticatedPdfForSelected(),
                        ),
                  icon: controller.isLoadingPdf
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: Text(
                    controller.isLoadingPdf
                        ? 'Baixando PDF autenticado...'
                        : (loadedPdf != null && !loadedPdf.isWiped
                              ? 'Recarregar PDF autenticado (v${item.submissionVersion})'
                              : 'Visualizar PDF autenticado (v${item.submissionVersion})'),
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('reviewer_save_pdf_button'),
                  onPressed:
                      (controller.isSavingPdf ||
                          controller.isLoadingPdf ||
                          controller.isSubmittingDecision)
                      ? null
                      : () => unawaited(controller.saveLoadedPdfLocally()),
                  icon: controller.isSavingPdf
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: const Text('Salvar / Abrir PDF localmente'),
                ),
                if (loadedPdf != null && !loadedPdf.isWiped)
                  TextButton.icon(
                    key: const Key('reviewer_clear_pdf_button'),
                    onPressed: controller.isSubmittingDecision
                        ? null
                        : controller.clearLoadedPdf,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('Descartar da memória'),
                  ),
              ],
            ),
            if (controller.pdfErrorMessage != null) ...[
              const SizedBox(height: 10),
              _ReviewerBanner(
                key: const Key('reviewer_pdf_error_banner'),
                icon: Icons.error_outline,
                message: controller.pdfErrorMessage!,
                isError: true,
              ),
            ],
            if (controller.pdfActionMessage != null &&
                controller.pdfErrorMessage == null) ...[
              const SizedBox(height: 10),
              _ReviewerBanner(
                key: const Key('reviewer_pdf_action_banner'),
                icon: Icons.verified_user_outlined,
                message: controller.pdfActionMessage!,
                isError: false,
              ),
            ],
            if (loadedPdf != null &&
                !loadedPdf.isWiped &&
                loadedPdf.renderedDocument != null &&
                !loadedPdf.renderedDocument!.isWiped) ...[
              const SizedBox(height: 10),
              PdfDocumentViewer(
                payload: loadedPdf,
                currentPage: controller.currentPdfPage,
                zoomScale: controller.pdfZoomScale,
                onPreviousPage: controller.canGoToPreviousPdfPage
                    ? controller.previousPdfPage
                    : null,
                onNextPage: controller.canGoToNextPdfPage
                    ? controller.nextPdfPage
                    : null,
                onSelectPage: controller.goToPdfPage,
                onZoomIn: controller.pdfZoomScale < 2.5
                    ? controller.zoomInPdf
                    : null,
                onZoomOut: controller.pdfZoomScale > 0.75
                    ? controller.zoomOutPdf
                    : null,
                onResetZoom: controller.pdfZoomScale != 1.0
                    ? controller.resetPdfZoom
                    : null,
                onOpenFallbackViewer: () => _openExpandedPdfViewer(
                  context: context,
                  controller: controller,
                  targetSubmissionId: loadedPdf.submissionId,
                ),
              ),
            ],

            const Divider(height: 32),

            // 3. Decisão atômica sobre a versão vigente (ESP-20)
            Text(
              'Registrar decisão sobre a versão v${item.submissionVersion}',
              style: textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Alvo da decisão: ${item.requirementTitle} (${item.requirementCode}) • Submissão ${item.submissionId} (v${item.submissionVersion}). Solicitações de correção exigem justificativa clara para orientar o reenvio pelo estudante.',
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                ChoiceChip(
                  key: const Key('reviewer_select_approve_button'),
                  label: const Text('Aprovar documento'),
                  selected:
                      controller.selectedDecision == ReviewDecision.approved,
                  onSelected: controller.isSubmittingDecision
                      ? null
                      : (_) =>
                            controller.selectDecision(ReviewDecision.approved),
                ),
                ChoiceChip(
                  key: const Key('reviewer_select_correction_button'),
                  label: const Text('Solicitar correção'),
                  selected:
                      controller.selectedDecision ==
                      ReviewDecision.correctionRequested,
                  onSelected: controller.isSubmittingDecision
                      ? null
                      : (_) => controller.selectDecision(
                          ReviewDecision.correctionRequested,
                        ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('reviewer_reason_field'),
              controller: reasonController,
              enabled: !controller.isSubmittingDecision,
              minLines: 2,
              maxLines: 5,
              maxLength: kMaxReviewReasonLength,
              decoration: InputDecoration(
                labelText:
                    controller.selectedDecision ==
                        ReviewDecision.correctionRequested
                    ? 'Justificativa da correção (obrigatória)'
                    : 'Observação da aprovação (opcional)',
                hintText:
                    controller.selectedDecision ==
                        ReviewDecision.correctionRequested
                    ? 'Descreva claramente o que o estudante precisa corrigir no PDF...'
                    : 'Observação adicional opcional para o histórico...',
                border: const OutlineInputBorder(),
              ),
              onChanged: controller.updateReason,
            ),
            if (controller.decisionErrorMessage != null) ...[
              const SizedBox(height: 10),
              _ReviewerBanner(
                key: const Key('reviewer_decision_error_banner'),
                icon: Icons.error_outline,
                message: controller.decisionErrorMessage!,
                isError: true,
              ),
            ],
            const SizedBox(height: 12),
            if (!controller.isConfirmingDecision)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const Key('reviewer_prepare_decision_button'),
                  onPressed: controller.isSubmittingDecision
                      ? null
                      : controller.prepareDecisionConfirmation,
                  icon: Icon(
                    controller.selectedDecision == ReviewDecision.approved
                        ? Icons.check_circle_outline
                        : Icons.edit_note_rounded,
                  ),
                  label: Text(
                    controller.selectedDecision == ReviewDecision.approved
                        ? 'Revisar e confirmar aprovação (v${item.submissionVersion})'
                        : 'Revisar e confirmar pedido de correção (v${item.submissionVersion})',
                  ),
                ),
              )
            else
              DecoratedBox(
                key: const Key('reviewer_confirm_decision_card'),
                decoration: BoxDecoration(
                  color: controller.selectedDecision == ReviewDecision.approved
                      ? colors.tertiaryContainer.withValues(alpha: 0.45)
                      : colors.errorContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color:
                        controller.selectedDecision == ReviewDecision.approved
                        ? colors.tertiary
                        : colors.error,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        controller.selectedDecision == ReviewDecision.approved
                            ? 'Confirmação de aprovação documental'
                            : 'Confirmação de solicitação de correção',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Você está prestes a registrar a decisão "${controller.selectedDecision.label}" para o requisito "${item.requirementTitle}" (${item.requirementCode}), versão v${item.submissionVersion} (ID: ${item.submissionId}), do estudante ${item.studentName}. Esta decisão é única e imutável para esta versão.',
                        style: textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Aviso normativo: aprovação documental no MVP refere-se apenas ao checklist e não equivale a autorização oficial de estágio.',
                        style: textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: [
                          OutlinedButton(
                            key: const Key('reviewer_cancel_confirm_button'),
                            onPressed: controller.isSubmittingDecision
                                ? null
                                : controller.cancelDecisionConfirmation,
                            child: const Text('Voltar e editar'),
                          ),
                          FilledButton.icon(
                            key: const Key('reviewer_confirm_submit_button'),
                            onPressed: controller.isSubmittingDecision
                                ? null
                                : () => unawaited(
                                    controller.submitConfirmedDecision(),
                                  ),
                            icon: controller.isSubmittingDecision
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.verified_outlined),
                            label: Text(
                              controller.isSubmittingDecision
                                  ? 'Registrando decisão...'
                                  : (controller.hasAmbiguousDecisionRetryPending
                                        ? 'Tentar novamente com segurança'
                                        : 'Confirmar e registrar decisão'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReviewerRequirementHistoryCard extends StatelessWidget {
  const _ReviewerRequirementHistoryCard({
    required this.controller,
    required this.compact,
  });

  final ReviewerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final submissions = controller.requirementSubmissions;
    final reqId = controller.activeHistoryRequirementId;
    final reqTitle =
        controller.activeHistoryRequirementTitle ?? 'Requisito selecionado';
    final reqCode = controller.activeHistoryRequirementCode ?? '';

    return Card(
      key: const Key('reviewer_req_history_card'),
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Histórico de versões do requisito (${submissions.length})',
                      style: textTheme.titleMedium,
                    ),
                    Text(
                      reqCode.isNotEmpty ? '$reqTitle ($reqCode)' : reqTitle,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (reqId != null)
                  IconButton(
                    key: const Key('reviewer_refresh_req_history_button'),
                    tooltip: 'Atualizar histórico do requisito',
                    onPressed:
                        controller.historyStatus == ReviewLoadStatus.loading
                        ? null
                        : () => unawaited(
                            controller.loadRequirementHistory(reqId),
                          ),
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            switch (controller.historyStatus) {
              ReviewLoadStatus.loading => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('Carregando histórico de submissões...'),
                    ],
                  ),
                ),
              ),
              ReviewLoadStatus.error => _ReviewerBanner(
                icon: Icons.warning_amber_rounded,
                message:
                    controller.historyErrorMessage ??
                    'Não foi possível carregar o histórico de versões.',
                isError: true,
              ),
              ReviewLoadStatus.loaded =>
                submissions.isEmpty
                    ? Text(
                        'Nenhuma submissão encontrada para este requisito.',
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final sub in submissions) ...[
                            _ReviewerHistoryVersionTile(
                              submission: sub,
                              review: controller.reviewForSubmission(sub.id),
                              isCurrent: controller
                                  .isCurrentSubmissionInHistory(sub),
                            ),
                            const SizedBox(height: 8),
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

class _ReviewerHistoryVersionTile extends StatelessWidget {
  const _ReviewerHistoryVersionTile({
    required this.submission,
    required this.review,
    required this.isCurrent,
  });

  final DocumentSubmissionRecord submission;
  final DocumentReviewRecord? review;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      key: Key('reviewer_history_version_v${submission.version}'),
      decoration: BoxDecoration(
        color: isCurrent
            ? colors.primaryContainer.withValues(alpha: 0.25)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isCurrent ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Versão v${submission.version}',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                _QueueChip(
                  label: isCurrent
                      ? 'Versão vigente'
                      : 'Versão histórica preservada',
                  backgroundColor: isCurrent
                      ? colors.primaryContainer
                      : colors.surfaceContainerHighest,
                  foregroundColor: isCurrent
                      ? colors.onPrimaryContainer
                      : colors.onSurfaceVariant,
                ),
                _QueueChip(
                  label: submission.status.label,
                  backgroundColor: _statusBg(colors, submission.status),
                  foregroundColor: _statusFg(colors, submission.status),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${submission.displayFilename} (${submission.formattedSize}) • Enviado em: ${_formatLocalDateTime(submission.submittedAt)}',
              style: textTheme.bodySmall,
            ),
            if (review != null) ...[
              const SizedBox(height: 6),
              Text(
                'Revisado em: ${_formatLocalDateTime(review!.reviewedAt)} • Decisão: ${review!.decision.label}',
                style: textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (review!.reason != null &&
                  review!.reason!.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Motivo/observação da revisão: ${review!.reason!.trim()}',
                  style: textTheme.bodySmall?.copyWith(
                    color:
                        review!.decision == ReviewDecision.correctionRequested
                        ? colors.onErrorContainer
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Color _statusBg(ColorScheme colors, SubmissionStatus status) {
    return switch (status) {
      SubmissionStatus.underReview => colors.secondaryContainer,
      SubmissionStatus.correctionRequested => colors.errorContainer,
      SubmissionStatus.approved => colors.tertiaryContainer,
    };
  }

  Color _statusFg(ColorScheme colors, SubmissionStatus status) {
    return switch (status) {
      SubmissionStatus.underReview => colors.onSecondaryContainer,
      SubmissionStatus.correctionRequested => colors.onErrorContainer,
      SubmissionStatus.approved => colors.onTertiaryContainer,
    };
  }
}

class _QueueChip extends StatelessWidget {
  const _QueueChip({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    super.key,
  });

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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: foregroundColor),
        ),
      ),
    );
  }
}

class _ReviewerBanner extends StatelessWidget {
  const _ReviewerBanner({
    required this.icon,
    required this.message,
    required this.isError,
    super.key,
  });

  final IconData icon;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bg = isError ? colors.errorContainer : colors.primaryContainer;
    final fg = isError ? colors.onErrorContainer : colors.onPrimaryContainer;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatLocalDateTime(DateTime dateTime) {
  final local = dateTime.toLocal();
  final d = local.day.toString().padLeft(2, '0');
  final m = local.month.toString().padLeft(2, '0');
  final y = local.year.toString().padLeft(4, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$d/$m/$y $hh:$mm';
}

void _openExpandedPdfViewer({
  required BuildContext context,
  required ReviewerController controller,
  required String targetSubmissionId,
}) {
  controller.openPdfInBrowserOrFallback();
  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return ListenableBuilder(
        listenable: controller,
        builder: (ctx, _) {
          final currentPayload = controller.loadedPdf;
          if (currentPayload == null ||
              currentPayload.isWiped ||
              currentPayload.submissionId != targetSubmissionId ||
              currentPayload.renderedDocument == null ||
              currentPayload.renderedDocument!.isWiped) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (dialogContext.mounted &&
                  Navigator.of(dialogContext).canPop()) {
                Navigator.of(dialogContext).pop();
              }
            });
            return const SizedBox.shrink();
          }

          return Dialog.fullscreen(
            key: const Key('pdf_fullscreen_viewer_dialog'),
            child: Scaffold(
              appBar: AppBar(
                title: Text(
                  'Leitor de PDF — ${currentPayload.originalFilename} (v${currentPayload.submissionVersion})',
                ),
                leading: IconButton(
                  key: const Key('close_fullscreen_pdf_button'),
                  tooltip: 'Fechar leitor em tela cheia',
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close),
                ),
              ),
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: PdfDocumentViewer(
                    payload: currentPayload,
                    currentPage: controller.currentPdfPage,
                    zoomScale: controller.pdfZoomScale,
                    onPreviousPage: controller.canGoToPreviousPdfPage
                        ? controller.previousPdfPage
                        : null,
                    onNextPage: controller.canGoToNextPdfPage
                        ? controller.nextPdfPage
                        : null,
                    onSelectPage: controller.goToPdfPage,
                    onZoomIn: controller.pdfZoomScale < 2.5
                        ? controller.zoomInPdf
                        : null,
                    onZoomOut: controller.pdfZoomScale > 0.75
                        ? controller.zoomOutPdf
                        : null,
                    onResetZoom: controller.pdfZoomScale != 1.0
                        ? controller.resetPdfZoom
                        : null,
                    onOpenFallbackViewer: () {},
                    isFullScreenModal: true,
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
