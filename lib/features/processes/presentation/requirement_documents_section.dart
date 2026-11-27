import 'dart:async';

import 'package:flutter/material.dart';

import '../../auth/domain/user_profile.dart';
import '../application/document_submission_controller.dart';
import '../domain/document_models.dart';
import '../domain/process_models.dart';

class RequirementDocumentsSection extends StatelessWidget {
  const RequirementDocumentsSection({
    required this.item,
    required this.processStatus,
    required this.userRole,
    required this.controller,
    super.key,
  });

  final ProcessRequirementItem item;
  final ProcessStatus processStatus;
  final UserRole userRole;
  final DocumentSubmissionController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;

        final canSubmit = controller.canSubmitForRequirement(
          item,
          processStatus: processStatus,
          userRole: userRole,
        );
        final hasSelection = controller.hasSelectedFileFor(item.id);
        final selectedFile = hasSelection ? controller.selectedFile : null;
        final isUploadingThis = controller.isUploading && hasSelection;
        final errorMessage = controller.errorForRequirement(item.id);
        final successMessage = controller.successForRequirement(item.id);

        final submissions = controller.submissionsForRequirement(item.id);
        final historyExpanded =
            controller.isHistoryExpanded(item.id) ||
            item.currentVersion > 0 ||
            submissions.isNotEmpty;
        final historyLoading = controller.isHistoryLoading(item.id);
        final historyError = controller.historyErrorForRequirement(item.id);

        final showDownloadFeedback =
            controller.downloadFeedbackRequirementId == item.id &&
            (controller.downloadErrorMessage != null ||
                controller.downloadSuccessMessage != null);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 24),
            if (successMessage != null) ...[
              _SectionBanner(
                key: Key('upload_success_banner_${item.code}'),
                icon: Icons.check_circle_outline,
                message: successMessage,
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
              ),
              const SizedBox(height: 10),
            ],
            if (errorMessage != null) ...[
              _SectionBanner(
                key: Key('upload_error_banner_${item.code}'),
                icon: Icons.error_outline,
                message: errorMessage,
                backgroundColor: colors.errorContainer,
                foregroundColor: colors.onErrorContainer,
              ),
              const SizedBox(height: 10),
            ],
            if (item.status == RequirementStatus.correctionRequested) ...[
              _SectionBanner(
                key: Key('correction_requested_notice_${item.code}'),
                icon: Icons.rate_review_outlined,
                message:
                    'Pendência de correção: verifique a justificativa registrada na revisão abaixo e envie um novo PDF (v${item.currentVersion + 1}). As versões anteriores permanecem preservadas no histórico.',
                backgroundColor: colors.errorContainer.withValues(alpha: 0.65),
                foregroundColor: colors.onErrorContainer,
              ),
              const SizedBox(height: 10),
            ],
            if (canSubmit) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    key: Key('pick_pdf_button_${item.code}'),
                    onPressed:
                        (controller.isPickingFile || controller.isUploading)
                        ? null
                        : () => unawaited(
                            controller.pickPdfForRequirement(
                              item,
                              processStatus: processStatus,
                              userRole: userRole,
                            ),
                          ),
                    icon: const Icon(Icons.upload_file_outlined),
                    label: Text(
                      item.status == RequirementStatus.correctionRequested
                          ? 'Selecionar novo PDF (reenvio)'
                          : 'Selecionar PDF',
                    ),
                  ),
                  Text(
                    'Apenas PDF (máx. 5 MiB)',
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (selectedFile != null) ...[
                const SizedBox(height: 12),
                DecoratedBox(
                  key: Key('selected_pdf_card_${item.code}'),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Enviar para: ${item.title} (${item.code})',
                          style: textTheme.labelLarge,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.picture_as_pdf_outlined,
                              size: 20,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    selectedFile.basename,
                                    style: textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    'Tamanho: ${selectedFile.formattedSize}',
                                    style: textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (isUploadingThis) ...[
                          const SizedBox(height: 10),
                          Row(
                            key: Key('upload_progress_${item.code}'),
                            children: [
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Enviando PDF para armazenamento privado...',
                                  style: textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              key: Key('submit_pdf_button_${item.code}'),
                              onPressed: controller.isUploading
                                  ? null
                                  : () => unawaited(
                                      controller.submitSelectedPdf(
                                        requirement: item,
                                        processStatus: processStatus,
                                        userRole: userRole,
                                      ),
                                    ),
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: Text(
                                controller.hasAmbiguousRetryPending
                                    ? 'Tentar novamente'
                                    : 'Enviar PDF',
                              ),
                            ),
                            TextButton(
                              key: Key('cancel_pdf_button_${item.code}'),
                              onPressed: controller.isUploading
                                  ? null
                                  : controller.cancelSelection,
                              child: const Text('Cancelar seleção'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ] else ...[
              _SectionBanner(
                key: Key('upload_locked_notice_${item.code}'),
                icon: item.status == RequirementStatus.approved
                    ? Icons.verified_outlined
                    : Icons.lock_clock_outlined,
                message: _lockedMessageForRequirement(
                  item: item,
                  processStatus: processStatus,
                  userRole: userRole,
                ),
                backgroundColor: colors.surfaceContainerHighest,
                foregroundColor: colors.onSurfaceVariant,
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  key: Key('toggle_history_button_${item.code}'),
                  onPressed: () =>
                      unawaited(controller.toggleHistoryExpanded(item.id)),
                  icon: Icon(
                    historyExpanded ? Icons.expand_less : Icons.expand_more,
                  ),
                  label: Text(
                    submissions.isNotEmpty
                        ? 'Histórico de submissões (${submissions.length})'
                        : 'Histórico de submissões',
                  ),
                ),
                IconButton(
                  key: Key('refresh_history_button_${item.code}'),
                  tooltip: 'Atualizar histórico de versões',
                  onPressed: historyLoading
                      ? null
                      : () => unawaited(
                          controller.loadHistoryForRequirement(item.id),
                        ),
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            if (showDownloadFeedback) ...[
              const SizedBox(height: 6),
              _SectionBanner(
                key: Key('download_feedback_banner_${item.code}'),
                icon: controller.downloadErrorMessage != null
                    ? Icons.error_outline
                    : Icons.download_done_outlined,
                message:
                    controller.downloadErrorMessage ??
                    controller.downloadSuccessMessage ??
                    '',
                backgroundColor: controller.downloadErrorMessage != null
                    ? colors.errorContainer
                    : colors.secondaryContainer,
                foregroundColor: controller.downloadErrorMessage != null
                    ? colors.onErrorContainer
                    : colors.onSecondaryContainer,
              ),
            ],
            if (historyExpanded) ...[
              const SizedBox(height: 8),
              if (historyLoading && submissions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('Carregando versões enviadas...'),
                    ],
                  ),
                )
              else if (historyError != null && submissions.isEmpty)
                _SectionBanner(
                  icon: Icons.warning_amber_rounded,
                  message: historyError,
                  backgroundColor: colors.errorContainer,
                  foregroundColor: colors.onErrorContainer,
                )
              else if (submissions.isEmpty)
                Text(
                  'Nenhuma submissão registrada para este requisito.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                )
              else
                Column(
                  key: Key('history_list_${item.code}'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final submission in submissions) ...[
                      _SubmissionVersionTile(
                        item: item,
                        submission: submission,
                        review: controller.reviewForSubmission(
                          requirementId: item.id,
                          submissionId: submission.id,
                        ),
                        isCurrent: isCurrentSubmissionForRequirement(
                          submission,
                          item,
                        ),
                        isDownloading:
                            controller.downloadingSubmissionId == submission.id,
                        disableAllDownloads:
                            controller.downloadingSubmissionId != null,
                        onDownload: () => unawaited(
                          controller.downloadSubmission(submission),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
            ],
          ],
        );
      },
    );
  }

  String _lockedMessageForRequirement({
    required ProcessRequirementItem item,
    required ProcessStatus processStatus,
    required UserRole userRole,
  }) {
    if (userRole != UserRole.student) {
      return 'Apenas o estudante proprietário pode enviar documentos.';
    }
    if (processStatus == ProcessStatus.cancelled) {
      return 'Processo cancelado não aceita novos envios documentais.';
    }
    return switch (item.status) {
      RequirementStatus.underReview => 'Documento em análise. Novos envios ficam bloqueados até a devolutiva da revisão.',
      RequirementStatus.approved =>
        'Requisito aprovado documentalmente. Não são permitidos novos envios.',
      RequirementStatus.notSubmitted ||
      RequirementStatus.correctionRequested => 'Envio disponível.',
    };
  }
}

class _SubmissionVersionTile extends StatelessWidget {
  const _SubmissionVersionTile({
    required this.item,
    required this.submission,
    required this.review,
    required this.isCurrent,
    required this.isDownloading,
    required this.disableAllDownloads,
    required this.onDownload,
  });

  final ProcessRequirementItem item;
  final DocumentSubmissionRecord submission;
  final DocumentReviewRecord? review;
  final bool isCurrent;
  final bool isDownloading;
  final bool disableAllDownloads;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      key: Key('submission_version_row_${item.code}_v${submission.version}'),
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
                if (isCurrent)
                  _MiniChip(
                    key: Key(
                      'current_version_badge_${item.code}_v${submission.version}',
                    ),
                    label: 'Versão vigente',
                    backgroundColor: colors.primaryContainer,
                    foregroundColor: colors.onPrimaryContainer,
                  )
                else
                  _MiniChip(
                    key: Key(
                      'historical_version_badge_${item.code}_v${submission.version}',
                    ),
                    label: 'Versão histórica preservada',
                    backgroundColor: colors.surfaceContainerHighest,
                    foregroundColor: colors.onSurfaceVariant,
                  ),
                _MiniChip(
                  label: submission.status.label,
                  backgroundColor: _statusBackground(colors, submission.status),
                  foregroundColor: _statusForeground(colors, submission.status),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(submission.displayFilename, style: textTheme.bodyMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  'Tamanho: ${submission.formattedSize}',
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Text(
                  'Enviado em: ${_formatDateTime(submission.submittedAt)}',
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (review?.reason != null &&
                review!.reason!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Observação da revisão: ${review!.reason!.trim()}',
                key: Key('review_reason_${item.code}_v${submission.version}'),
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onErrorContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                key: Key(
                  'download_submission_button_${item.code}_v${submission.version}',
                ),
                onPressed: disableAllDownloads ? null : onDownload,
                icon: isDownloading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined, size: 18),
                label: Text(isDownloading ? 'Baixando...' : 'Baixar PDF'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusBackground(ColorScheme colors, SubmissionStatus status) {
    return switch (status) {
      SubmissionStatus.underReview => colors.secondaryContainer,
      SubmissionStatus.correctionRequested => colors.errorContainer,
      SubmissionStatus.approved => colors.tertiaryContainer,
    };
  }

  Color _statusForeground(ColorScheme colors, SubmissionStatus status) {
    return switch (status) {
      SubmissionStatus.underReview => colors.onSecondaryContainer,
      SubmissionStatus.correctionRequested => colors.onErrorContainer,
      SubmissionStatus.approved => colors.onTertiaryContainer,
    };
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({
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

class _SectionBanner extends StatelessWidget {
  const _SectionBanner({
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
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: foregroundColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: foregroundColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDateTime(DateTime dateTime) {
  final local = dateTime.toLocal();
  final d = local.day.toString().padLeft(2, '0');
  final m = local.month.toString().padLeft(2, '0');
  final y = local.year.toString().padLeft(4, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$d/$m/$y $hh:$mm';
}
