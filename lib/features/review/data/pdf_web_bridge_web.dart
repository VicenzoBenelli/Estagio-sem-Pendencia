import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import 'pdf_web_bridge.dart';

bool isNativeAndroidRuntime() => false;

class _BrowserPdfWebBridge implements PdfWebBridge {
  _BrowserPdfWebBridge();

  int _counter = 0;
  final Map<String, PdfWebSessionHandle> _activeHandles =
      <String, PdfWebSessionHandle>{};
  final Map<String, web.HTMLIFrameElement> _activeIframes =
      <String, web.HTMLIFrameElement>{};

  @override
  bool get isSupported => true;

  @override
  PdfWebSessionHandle? createSession({
    required Uint8List bytes,
    required String submissionId,
    required int submissionVersion,
    int initialPage = 1,
  }) {
    if (bytes.isEmpty) {
      return null;
    }

    final sessionId =
        'pdf_${DateTime.now().microsecondsSinceEpoch}_${++_counter}';
    final viewType = 'estagio-pdf-viewer-$sessionId';
    final safeCopy = Uint8List.fromList(bytes);
    final blobParts = <JSAny>[safeCopy.toJS].toJS;
    final blob = web.Blob(
      blobParts,
      web.BlobPropertyBag(type: 'application/pdf'),
    );
    final objectUrl = web.URL.createObjectURL(blob);

    final handle = PdfWebSessionHandle(
      sessionId: sessionId,
      viewType: viewType,
      objectUrl: objectUrl,
      submissionId: submissionId,
      submissionVersion: submissionVersion,
      currentPage: initialPage < 1 ? 1 : initialPage,
    );
    _activeHandles[sessionId] = handle;

    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final iframe =
          web.document.createElement('iframe') as web.HTMLIFrameElement;
      iframe.style.border = 'none';
      iframe.style.width = '100%';
      iframe.style.height = '100%';
      iframe.style.backgroundColor = '#ffffff';
      iframe.setAttribute('type', 'application/pdf');
      iframe.setAttribute(
        'title',
        'Documento PDF autenticado v$submissionVersion ($submissionId)',
      );
      if (handle.isRevoked) {
        iframe.src = 'about:blank';
      } else {
        iframe.src =
            '${handle.objectUrl}#page=${handle.currentPage}&view=FitH&toolbar=1';
        _activeIframes[sessionId] = iframe;
      }
      return iframe;
    });

    return handle;
  }

  @override
  void navigateToPage(PdfWebSessionHandle? handle, int pageNumber) {
    if (handle == null || handle.isRevoked) {
      return;
    }
    final safePage = pageNumber < 1 ? 1 : pageNumber;
    handle.currentPage = safePage;
    final iframe = _activeIframes[handle.sessionId];
    if (iframe != null) {
      iframe.src = '${handle.objectUrl}#page=$safePage&view=FitH&toolbar=1';
    }
  }

  @override
  bool openInBrowserTab(PdfWebSessionHandle? handle, {int? pageNumber}) {
    if (handle == null || handle.isRevoked) {
      return false;
    }
    final targetPage = pageNumber ?? handle.currentPage;
    final url = '${handle.objectUrl}#page=$targetPage&view=FitH';
    final opened = web.window.open(url, '_blank', 'noopener,noreferrer');
    handle.openTabCalls++;
    return opened != null;
  }

  @override
  void revokeSession(PdfWebSessionHandle? handle) {
    if (handle == null) {
      return;
    }
    _activeHandles.remove(handle.sessionId);
    final iframe = _activeIframes.remove(handle.sessionId);
    if (iframe != null) {
      try {
        iframe.src = 'about:blank';
        iframe.remove();
      } catch (_) {}
    }
    if (!handle.isRevoked) {
      handle.isRevoked = true;
      try {
        web.URL.revokeObjectURL(handle.objectUrl);
      } catch (_) {}
    }
  }

  @override
  void revokeAllSessions() {
    final all = _activeHandles.values.toList(growable: false);
    for (final handle in all) {
      revokeSession(handle);
    }
    _activeHandles.clear();
    _activeIframes.clear();
  }
}

PdfWebBridge createPlatformPdfWebBridge() => _BrowserPdfWebBridge();
