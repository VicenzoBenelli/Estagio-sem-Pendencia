import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../processes/domain/document_models.dart';
import '../domain/review_models.dart';
import 'pdf_web_bridge.dart';
import 'pdf_web_bridge_stub.dart'
    if (dart.library.js_interop) 'pdf_web_bridge_web.dart';

const int kDefaultMaxPdfBitmapDimension = 1280;
const int kMinPdfBitmapDimension = 480;
const int kMaxPdfBitmapDimension = 2048;

enum PdfRenderMode { androidRaster, webBrowser }

/// Calcula as dimensões do bitmap de página PDF preservando a proporção
/// e limitando a maior dimensão sem upscale desnecessário:
/// `scale = min(1.0, maxDimension / maiorDimensao)`.
abstract final class PdfBitmapScaleCalculator {
  static ({int width, int height, double scale}) computeTargetDimensions({
    required int widthPt,
    required int heightPt,
    int maxDimension = kDefaultMaxPdfBitmapDimension,
  }) {
    final safeW = widthPt < 1 ? 1 : widthPt;
    final safeH = heightPt < 1 ? 1 : heightPt;
    final safeMax = maxDimension.clamp(
      kMinPdfBitmapDimension,
      kMaxPdfBitmapDimension,
    );
    final largest = math.max(safeW, safeH);
    final scale = math.min(1.0, safeMax.toDouble() / largest.toDouble());
    final targetW = (safeW.toDouble() * scale).floor().clamp(1, safeMax);
    final targetH = (safeH.toDouble() * scale).floor().clamp(1, safeMax);
    return (width: targetW, height: targetH, scale: scale);
  }
}

/// Validação preliminar mínima e segura dos bytes recebidos antes de delegar
/// ao renderizador nativo (`android.graphics.pdf.PdfRenderer` ou `Blob` do navegador).
/// Nunca utiliza expressões regulares para interpretar objetos, `/Count`,
/// `/Type /Pages`, `/MediaBox` ou texto da página (C4-FE-01).
abstract final class PdfPreliminaryCheck {
  static void validateReceivedBytes(
    Uint8List bytes, {
    int maxBytes = kMaxPdfSizeBytes,
  }) {
    if (bytes.isEmpty) {
      throw const ReviewFailure(
        'O arquivo PDF retornado pelo armazenamento privado está vazio.',
        code: 'empty_downloaded_file',
      );
    }
    if (bytes.lengthInBytes > maxBytes) {
      throw const ReviewFailure(
        'O arquivo PDF excede o limite máximo permitido de 5 MiB.',
        code: 'file_too_large',
      );
    }
    if (!PdfPreliminaryValidation.hasPdfHeader(bytes)) {
      throw const ReviewFailure(
        'Os bytes retornados não possuem assinatura válida de documento PDF (%PDF-).',
        code: 'invalid_pdf_signature',
      );
    }
  }
}

class RenderedPdfPage {
  RenderedPdfPage({
    required this.pageNumber,
    required this.widthPoints,
    required this.heightPoints,
    required Uint8List rasterPngBytes,
    int? bitmapWidth,
    int? bitmapHeight,
  }) : _rasterPngBytes = Uint8List.fromList(rasterPngBytes),
       bitmapWidth = bitmapWidth ?? widthPoints.round().clamp(1, 4096),
       bitmapHeight = bitmapHeight ?? heightPoints.round().clamp(1, 4096);

  final int pageNumber;
  final double widthPoints;
  final double heightPoints;
  final int bitmapWidth;
  final int bitmapHeight;
  final Uint8List _rasterPngBytes;

  bool _isWiped = false;

  bool get isWiped => _isWiped;

  Uint8List? get rasterPngBytes => _isWiped ? null : _rasterPngBytes;

  bool get hasRasterImage => !_isWiped && _rasterPngBytes.isNotEmpty;

  double get aspectRatio {
    if (widthPoints <= 0 || heightPoints <= 0) {
      return 595.0 / 842.0;
    }
    return (widthPoints / heightPoints).clamp(0.35, 3.0);
  }

  void wipe() {
    if (_rasterPngBytes.isNotEmpty) {
      _rasterPngBytes.fillRange(0, _rasterPngBytes.length, 0);
    }
    _isWiped = true;
  }
}

class RenderedPdfDocument {
  RenderedPdfDocument.androidRaster({
    required this.submissionId,
    required this.submissionVersion,
    required List<RenderedPdfPage> pages,
  }) : renderMode = PdfRenderMode.androidRaster,
       hasValidatedPageCount = true,
       pages = List<RenderedPdfPage>.unmodifiable(pages),
       webSession = null,
       webBridge = null;

  RenderedPdfDocument.webBrowser({
    required this.submissionId,
    required this.submissionVersion,
    required PdfWebSessionHandle this.webSession,
    required PdfWebBridge this.webBridge,
  }) : renderMode = PdfRenderMode.webBrowser,
       hasValidatedPageCount = false,
       pages = const <RenderedPdfPage>[];

  final String submissionId;
  final int submissionVersion;
  final PdfRenderMode renderMode;

  /// `true` apenas quando a contagem de páginas foi determinada por um
  /// renderizador real (`android.graphics.pdf.PdfRenderer`).
  /// Na Web (`PdfRenderMode.webBrowser`), permanece `false` para não exibir
  /// paginação fictícia.
  final bool hasValidatedPageCount;
  final List<RenderedPdfPage> pages;
  final PdfWebSessionHandle? webSession;
  final PdfWebBridge? webBridge;

  bool _isWiped = false;

  int get pageCount => hasValidatedPageCount ? pages.length : 0;
  bool get isWiped => _isWiped;
  bool get isWebBrowserMode => renderMode == PdfRenderMode.webBrowser;

  bool get hasActiveWebSession =>
      !_isWiped && webSession != null && !webSession!.isRevoked;

  bool get isViewable =>
      !_isWiped &&
      ((renderMode == PdfRenderMode.androidRaster &&
              pages.isNotEmpty &&
              pages.every((p) => p.hasRasterImage)) ||
          (renderMode == PdfRenderMode.webBrowser && hasActiveWebSession));

  RenderedPdfPage? pageAtOrNull(int oneBasedPage) {
    if (!hasValidatedPageCount || pages.isEmpty) {
      return null;
    }
    final index = (oneBasedPage - 1).clamp(0, pages.length - 1);
    return pages[index];
  }

  void navigateToPage(int oneBasedPage) {
    if (_isWiped) return;
    webBridge?.navigateToPage(webSession, oneBasedPage);
  }

  bool openInBrowserTab({int? pageNumber}) {
    if (_isWiped) return false;
    return webBridge?.openInBrowserTab(webSession, pageNumber: pageNumber) ??
        false;
  }

  void wipe() {
    for (final page in pages) {
      page.wipe();
    }
    if (webSession != null) {
      if (webBridge != null) {
        webBridge!.revokeSession(webSession);
      } else {
        webSession!.isRevoked = true;
      }
    }
    _isWiped = true;
  }
}

abstract interface class PdfRendererGateway {
  Future<RenderedPdfDocument> renderDocument({
    required Uint8List bytes,
    required String submissionId,
    required int submissionVersion,
    required String documentTitle,
    int maxDimension = kDefaultMaxPdfBitmapDimension,
  });

  Future<void> clearTemporaryResources(RenderedPdfDocument? document);
}

class PlatformPdfRendererGateway implements PdfRendererGateway {
  PlatformPdfRendererGateway({
    PdfWebBridge? webBridge,
    MethodChannel? channel,
    bool? useAndroidNativeChannel,
  }) : _webBridge = webBridge ?? createPlatformPdfWebBridge(),
       _channel =
           channel ?? const MethodChannel('estagio_sem_pendencia/pdf_renderer'),
       _useAndroidNativeChannel =
           useAndroidNativeChannel ?? (!kIsWeb && isNativeAndroidRuntime());

  final PdfWebBridge _webBridge;
  final MethodChannel _channel;
  final bool _useAndroidNativeChannel;

  @override
  Future<RenderedPdfDocument> renderDocument({
    required Uint8List bytes,
    required String submissionId,
    required int submissionVersion,
    required String documentTitle,
    int maxDimension = kDefaultMaxPdfBitmapDimension,
  }) async {
    PdfPreliminaryCheck.validateReceivedBytes(bytes);

    final safeMaxDimension = maxDimension.clamp(
      kMinPdfBitmapDimension,
      kMaxPdfBitmapDimension,
    );

    if (_webBridge.isSupported && !_useAndroidNativeChannel) {
      final webSession = _webBridge.createSession(
        bytes: bytes,
        submissionId: submissionId,
        submissionVersion: submissionVersion,
        initialPage: 1,
      );
      if (webSession == null) {
        throw const ReviewFailure(
          'Não foi possível inicializar o visualizador de PDF no navegador.',
          code: 'web_viewer_init_failed',
        );
      }
      return RenderedPdfDocument.webBrowser(
        submissionId: submissionId,
        submissionVersion: submissionVersion,
        webSession: webSession,
        webBridge: _webBridge,
      );
    }

    try {
      final rawResponse = await _channel.invokeMethod<dynamic>(
        'renderPdfDocument',
        <String, dynamic>{
          'bytes': bytes,
          'maxDimension': safeMaxDimension,
          'submissionId': submissionId,
          'version': submissionVersion,
        },
      );

      if (rawResponse is! Map) {
        throw const ReviewFailure(
          'Não foi possível renderizar as páginas do documento PDF.',
          code: 'corrupted_pdf',
        );
      }

      final rawPages = rawResponse['pages'];
      if (rawPages is! List || rawPages.isEmpty) {
        throw const ReviewFailure(
          'O documento PDF não contém páginas renderizáveis.',
          code: 'empty_pdf_pages',
        );
      }

      final rasterPages = <RenderedPdfPage>[];
      for (var i = 0; i < rawPages.length; i++) {
        final entry = rawPages[i];
        if (entry is! Map) continue;
        final pageNum = _asInt(entry['pageNumber'], fallback: i + 1);
        final wPt = _asDouble(entry['widthPt'], fallback: 595.0);
        final hPt = _asDouble(entry['heightPt'], fallback: 842.0);
        final bmpW = _asInt(
          entry['bitmapWidth'],
          fallback: wPt.round().clamp(1, safeMaxDimension),
        );
        final bmpH = _asInt(
          entry['bitmapHeight'],
          fallback: hPt.round().clamp(1, safeMaxDimension),
        );
        final png = entry['pngBytes'];
        final pngBytes = png is Uint8List
            ? png
            : (png is List<int> ? Uint8List.fromList(png) : null);

        if (pngBytes == null || pngBytes.isEmpty) {
          throw const ReviewFailure(
            'Falha ao rasterizar página do documento PDF.',
            code: 'corrupted_pdf',
          );
        }

        rasterPages.add(
          RenderedPdfPage(
            pageNumber: pageNum,
            widthPoints: wPt,
            heightPoints: hPt,
            bitmapWidth: bmpW,
            bitmapHeight: bmpH,
            rasterPngBytes: pngBytes,
          ),
        );
      }

      if (rasterPages.isEmpty) {
        throw const ReviewFailure(
          'O documento PDF não contém páginas renderizáveis.',
          code: 'empty_pdf_pages',
        );
      }

      return RenderedPdfDocument.androidRaster(
        submissionId: submissionId,
        submissionVersion: submissionVersion,
        pages: rasterPages,
      );
    } on PlatformException catch (error) {
      throw ReviewFailure(
        error.message ??
            'O arquivo PDF está corrompido ou não pôde ser renderizado.',
        code: (error.code).toLowerCase(),
      );
    } on MissingPluginException {
      throw const ReviewFailure(
        'Renderizador nativo de PDF indisponível neste ambiente.',
        code: 'pdf_renderer_unavailable',
      );
    }
  }

  @override
  Future<void> clearTemporaryResources(RenderedPdfDocument? document) async {
    document?.wipe();
    if (_webBridge.isSupported) {
      _webBridge.revokeAllSessions();
    }
    if (_useAndroidNativeChannel || !_webBridge.isSupported) {
      try {
        await _channel.invokeMethod<dynamic>('clearTemporaryPdfs');
      } on MissingPluginException {
        // Ignorado quando o canal nativo não está registrado.
      } catch (_) {}
    }
  }
}

int _asInt(Object? raw, {int fallback = 0}) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? fallback;
  return fallback;
}

double _asDouble(Object? raw, {double fallback = 0.0}) {
  if (raw is double) return raw;
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw) ?? fallback;
  return fallback;
}
