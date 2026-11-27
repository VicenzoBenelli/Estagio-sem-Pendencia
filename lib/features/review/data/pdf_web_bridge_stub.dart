import 'dart:io' show Platform;
import 'dart:typed_data';

import 'pdf_web_bridge.dart';

bool isNativeAndroidRuntime() => Platform.isAndroid;

class _StubPdfWebBridge implements PdfWebBridge {
  const _StubPdfWebBridge();

  @override
  bool get isSupported => false;

  @override
  PdfWebSessionHandle? createSession({
    required Uint8List bytes,
    required String submissionId,
    required int submissionVersion,
    int initialPage = 1,
  }) {
    return null;
  }

  @override
  void navigateToPage(PdfWebSessionHandle? handle, int pageNumber) {
    if (handle != null && !handle.isRevoked) {
      handle.currentPage = pageNumber;
    }
  }

  @override
  bool openInBrowserTab(PdfWebSessionHandle? handle, {int? pageNumber}) {
    return false;
  }

  @override
  void revokeSession(PdfWebSessionHandle? handle) {
    if (handle != null) {
      handle.isRevoked = true;
    }
  }

  @override
  void revokeAllSessions() {}
}

PdfWebBridge createPlatformPdfWebBridge() => const _StubPdfWebBridge();
