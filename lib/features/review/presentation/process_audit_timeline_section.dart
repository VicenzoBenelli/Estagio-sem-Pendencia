import 'package:flutter/material.dart';

import '../../processes/domain/document_models.dart';
import '../application/process_timeline_controller.dart';
import '../domain/review_models.dart';

class ProcessAuditTimelineSection extends StatelessWidget {
  const ProcessAuditTimelineSection({
    required this.controller,
    this.title = 'Trilha de auditoria e histórico de eventos',
    super.key,
  });

  final ProcessTimelineController controller;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        final events = controller.events;

        return DecoratedBox(
          key: const Key('process_audit_timeline_section'),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.history_edu_outlined,
                          size: 20,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '$title (${controller.totalCount})',
                            style: textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          key: const Key('timeline_sort_order_button'),
                          onPressed:
                              controller.status == ReviewLoadStatus.loading
                              ? null
                              : controller.toggleSortOrder,
                          icon: const Icon(Icons.swap_vert, size: 18),
                          label: Text(
                            controller.oldestFirst
                                ? 'Mais antigos primeiro'
                                : 'Mais recentes primeiro',
                          ),
                        ),
                        IconButton(
                          key: const Key('timeline_refresh_button'),
                          tooltip: 'Atualizar trilha de auditoria',
                          onPressed:
                              controller.status == ReviewLoadStatus.loading
                              ? null
                              : controller.refresh,
                          icon: const Icon(Icons.refresh, size: 20),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Histórico imutável por escopo do processo (horário local). Versões anteriores permanecem preservadas e não substituem o status vigente.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                switch (controller.status) {
                  ReviewLoadStatus.loading => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text('Carregando eventos de auditoria...'),
                        ],
                      ),
                    ),
                  ),
                  ReviewLoadStatus.error => DecoratedBox(
                    key: const Key('timeline_error_box'),
                    decoration: BoxDecoration(
                      color: colors.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 18,
                                color: colors.onErrorContainer,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  controller.errorMessage ?? 'Não foi possível carregar a trilha de auditoria.',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colors.onErrorContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.tonalIcon(
                              key: const Key('timeline_retry_button'),
                              onPressed: controller.refresh,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Tentar novamente'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ReviewLoadStatus.loaded =>
                    events.isEmpty
                        ? DecoratedBox(
                            key: const Key('timeline_empty_state'),
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerLowest,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: colors.outlineVariant),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                'Nenhum evento de auditoria encontrado para este processo.',
                                style: textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final event in events) ...[
                                _AuditTimelineEventTile(event: event),
                                const SizedBox(height: 8),
                              ],
                              if (controller.totalPages > 1 ||
                                  controller.hasPreviousPage ||
                                  controller.hasNextPage) ...[
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  alignment: WrapAlignment.spaceBetween,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      'Página ${controller.currentPage + 1} de ${controller.totalPages} (${controller.totalCount} eventos)',
                                      key: const Key('timeline_page_indicator'),
                                      style: textTheme.labelMedium,
                                    ),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        OutlinedButton.icon(
                                          key: const Key(
                                            'timeline_prev_page_button',
                                          ),
                                          onPressed: controller.hasPreviousPage
                                              ? controller.previousPage
                                              : null,
                                          icon: const Icon(
                                            Icons.chevron_left,
                                            size: 18,
                                          ),
                                          label: const Text('Anterior'),
                                        ),
                                        OutlinedButton.icon(
                                          key: const Key(
                                            'timeline_next_page_button',
                                          ),
                                          onPressed: controller.hasNextPage
                                              ? controller.nextPage
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
                            ],
                          ),
                },
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AuditTimelineEventTile extends StatelessWidget {
  const _AuditTimelineEventTile({required this.event});

  final ProcessAuditTimelineEvent event;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (icon, badgeBg, badgeFg) = _visualForEvent(colors, event);

    return DecoratedBox(
      key: Key('timeline_event_row_${event.eventId}'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: badgeFg),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        event.displayTitle,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  _formatLocalDateTime(event.occurredAt),
                  key: Key('timeline_event_time_${event.eventId}'),
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _TimelineMiniBadge(
                  label:
                      'Autor: ${event.actorDisplayName} (${event.actorRoleLabel})',
                  backgroundColor: badgeBg,
                  foregroundColor: badgeFg,
                ),
                if (event.submissionVersion != null)
                  _TimelineMiniBadge(
                    label: 'Versão v${event.submissionVersion}',
                    backgroundColor: colors.secondaryContainer,
                    foregroundColor: colors.onSecondaryContainer,
                  ),
                if (event.requirementCode != null &&
                    event.requirementCode!.trim().isNotEmpty)
                  _TimelineMiniBadge(
                    label: event.requirementCode!.trim(),
                    backgroundColor: colors.surfaceContainerHighest,
                    foregroundColor: colors.onSurfaceVariant,
                  ),
              ],
            ),
            if (event.requirementTitle != null &&
                event.requirementTitle!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Requisito: ${event.requirementTitle!.trim()}',
                style: textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (event.reason != null && event.reason!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: event.decision == ReviewDecision.correctionRequested
                      ? colors.errorContainer.withValues(alpha: 0.55)
                      : colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'Justificativa registrada: ${event.reason!.trim()}',
                    style: textTheme.bodySmall?.copyWith(
                      color:
                          event.decision == ReviewDecision.correctionRequested
                          ? colors.onErrorContainer
                          : colors.onSurface,
                    ),
                  ),
                ),
              ),
            ],
            if (event.eventType ==
                AuditEventType.processDocumentallyCompleted) ...[
              const SizedBox(height: 6),
              Text(
                'Conclusão apenas do checklist documental no MVP; não representa autorização oficial de estágio.',
                style: textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  (IconData, Color, Color) _visualForEvent(
    ColorScheme colors,
    ProcessAuditTimelineEvent event,
  ) {
    return switch (event.eventType) {
      AuditEventType.processCreated => (
        Icons.folder_open_outlined,
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      AuditEventType.documentSubmitted => (
        Icons.upload_file_outlined,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      AuditEventType.documentCorrectionRequested => (
        Icons.edit_note_rounded,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      AuditEventType.documentApproved => (
        Icons.check_circle_outline,
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      AuditEventType.processDocumentallyCompleted => (
        Icons.verified_outlined,
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      AuditEventType.other => (
        Icons.event_note_outlined,
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
    };
  }
}

class _TimelineMiniBadge extends StatelessWidget {
  const _TimelineMiniBadge({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: foregroundColor),
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
