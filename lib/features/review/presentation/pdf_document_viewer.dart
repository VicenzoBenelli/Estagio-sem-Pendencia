import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/responsive/app_breakpoints.dart';
import '../data/pdf_document_renderer.dart';
import '../domain/review_models.dart';

class PdfDocumentViewer extends StatefulWidget {
  const PdfDocumentViewer({
    required this.payload,
    required this.currentPage,
    required this.zoomScale,
    required this.onPreviousPage,
    required this.onNextPage,
    required this.onSelectPage,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onResetZoom,
    required this.onOpenFallbackViewer,
    this.isFullScreenModal = false,
    super.key,
  });

  final VerifiedPdfPayload payload;
  final int currentPage;
  final double zoomScale;
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;
  final ValueChanged<int> onSelectPage;
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;
  final VoidCallback? onResetZoom;
  final VoidCallback onOpenFallbackViewer;
  final bool isFullScreenModal;

  @override
  State<PdfDocumentViewer> createState() => _PdfDocumentViewerState();
}

class _PdfDocumentViewerState extends State<PdfDocumentViewer> {
  late final TransformationController _transformController;

  @override
  void initState() {
    super.initState();
    _transformController = TransformationController();
    _applyScale(widget.zoomScale);
  }

  @override
  void didUpdateWidget(covariant PdfDocumentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoomScale != widget.zoomScale ||
        oldWidget.currentPage != widget.currentPage ||
        oldWidget.payload.submissionId != widget.payload.submissionId) {
      _applyScale(widget.zoomScale);
    }
  }

  void _applyScale(double scale) {
    _transformController.value = Matrix4.identity()
      ..scaleByDouble(scale, scale, 1.0, 1.0);
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final doc = widget.payload.renderedDocument;
    if (doc == null || !doc.isViewable || widget.payload.isWiped) {
      return const SizedBox.shrink();
    }

    final hasValidatedPages = doc.hasValidatedPageCount;
    final totalPages = doc.pageCount;
    final safeCurrentPage = hasValidatedPages
        ? widget.currentPage.clamp(1, totalPages)
        : 1;
    final activePage = doc.pageAtOrNull(safeCurrentPage);
    final zoomPct = (widget.zoomScale * 100).round();

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < AppBreakpoints.compact;
        final defaultHeight = compact ? 340.0 : 460.0;
        final maxAllowedHeight = widget.isFullScreenModal
            ? 860.0
            : defaultHeight;
        final viewportHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight - 310.0).clamp(160.0, maxAllowedHeight)
            : (widget.isFullScreenModal ? 520.0 : defaultHeight);

        return DecoratedBox(
          key: Key(
            widget.isFullScreenModal
                ? 'pdf_document_viewer_fullscreen'
                : 'reviewer_pdf_viewer_card',
          ),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.primary, width: 1.4),
          ),
          child: Padding(
            padding: EdgeInsets.all(compact ? 10 : 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Cabeçalho de identificação do documento, requisito e versão vigente
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.picture_as_pdf_outlined,
                          size: 20,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Visualizador de PDF: ${widget.payload.originalFilename} • Versão v${widget.payload.submissionVersion}',
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (!widget.isFullScreenModal)
                      FilledButton.tonalIcon(
                        key: const Key('reviewer_open_external_pdf_button'),
                        onPressed: widget.onOpenFallbackViewer,
                        icon: const Icon(Icons.open_in_full_outlined, size: 16),
                        label: Text(
                          doc.renderMode == PdfRenderMode.webBrowser || kIsWeb
                              ? 'Abrir em nova aba / tela cheia'
                              : 'Abrir leitor em tela cheia',
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Requisito: ${widget.payload.requirementTitle} (${widget.payload.requirementCode}) • Estudante: ${widget.payload.studentName} • Submissão: ${widget.payload.submissionId} (${widget.payload.formattedSize})',
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),

                // 2. Barra de controles: paginação validada (Android PdfRenderer) ou leitor nativo do navegador (Web)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (hasValidatedPages)
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              IconButton(
                                key: const Key('pdf_viewer_prev_page_button'),
                                tooltip: 'Página anterior',
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.onPreviousPage,
                                icon: const Icon(Icons.chevron_left),
                              ),
                              Text(
                                'Página $safeCurrentPage de $totalPages',
                                key: const Key('pdf_viewer_page_indicator'),
                                style: textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              IconButton(
                                key: const Key('pdf_viewer_next_page_button'),
                                tooltip: 'Próxima página',
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.onNextPage,
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          )
                        else
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.web_asset_outlined,
                                size: 18,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Leitor PDF nativo do navegador (paginação integrada ao documento)',
                                  key: const Key('pdf_viewer_web_mode_label'),
                                  style: textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            IconButton(
                              key: const Key('pdf_viewer_zoom_out_button'),
                              tooltip: 'Reduzir zoom',
                              visualDensity: VisualDensity.compact,
                              onPressed: widget.onZoomOut,
                              icon: const Icon(Icons.zoom_out, size: 20),
                            ),
                            Text(
                              '$zoomPct%',
                              key: const Key('pdf_viewer_zoom_label'),
                              style: textTheme.labelMedium,
                            ),
                            IconButton(
                              key: const Key('pdf_viewer_zoom_in_button'),
                              tooltip: 'Ampliar zoom',
                              visualDensity: VisualDensity.compact,
                              onPressed: widget.onZoomIn,
                              icon: const Icon(Icons.zoom_in, size: 20),
                            ),
                            TextButton(
                              key: const Key('pdf_viewer_zoom_reset_button'),
                              onPressed: widget.onResetZoom,
                              child: const Text('100%'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                if (hasValidatedPages && totalPages > 1) ...[
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (
                          var pageIdx = 1;
                          pageIdx <= totalPages;
                          pageIdx++
                        ) ...[
                          ChoiceChip(
                            key: Key('pdf_viewer_page_chip_$pageIdx'),
                            label: Text('Pág. $pageIdx'),
                            selected: pageIdx == safeCurrentPage,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => widget.onSelectPage(pageIdx),
                          ),
                          const SizedBox(width: 6),
                        ],
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 10),

                // 3. Superfície real de renderização visual (Bitmap do PdfRenderer no Android ou Blob iframe na Web)
                SizedBox(
                  key: const Key('pdf_viewer_viewport'),
                  height: viewportHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(
                        alpha: 0.55,
                      ),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: _buildViewportContent(
                        context: context,
                        doc: doc,
                        page: activePage,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildViewportContent({
    required BuildContext context,
    required RenderedPdfDocument doc,
    required RenderedPdfPage? page,
  }) {
    if (doc.renderMode == PdfRenderMode.webBrowser && doc.hasActiveWebSession) {
      final session = doc.webSession!;
      return InteractiveViewer(
        key: const Key('pdf_viewer_web_surface'),
        transformationController: _transformController,
        minScale: 0.75,
        maxScale: 3.0,
        child: kIsWeb
            ? HtmlElementView(
                key: Key('pdf_viewer_web_iframe_${session.sessionId}'),
                viewType: session.viewType,
              )
            : DecoratedBox(
                key: Key('pdf_viewer_web_iframe_${session.sessionId}'),
                decoration: const BoxDecoration(color: Colors.white),
                child: Center(
                  child: Text(
                    'Sessão Web Blob ativa: ${session.viewType}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
      );
    }

    if (page == null || !page.hasRasterImage) {
      return const SizedBox.shrink();
    }

    return InteractiveViewer(
      key: Key('pdf_viewer_page_surface_p${page.pageNumber}'),
      transformationController: _transformController,
      minScale: 0.75,
      maxScale: 3.0,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: AspectRatio(
            aspectRatio: page.aspectRatio,
            child: DecoratedBox(
              key: Key('pdf_viewer_page_canvas_p${page.pageNumber}'),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Image.memory(
                page.rasterPngBytes!,
                key: Key('pdf_viewer_raster_image_p${page.pageNumber}'),
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
