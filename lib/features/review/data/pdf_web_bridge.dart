import 'dart:typed_data';

class PdfWebSessionHandle {
  PdfWebSessionHandle({
    required this.sessionId,
    required this.viewType,
    required this.objectUrl,
    required this.submissionId,
    required this.submissionVersion,
    this.currentPage = 1,
  });

  final String sessionId;
  final String viewType;
  final String objectUrl;
  final String submissionId;
  final int submissionVersion;
  int currentPage;
  bool isRevoked = false;
  int openTabCalls = 0;
}

abstract interface class PdfWebBridge {
  bool get isSupported;

  PdfWebSessionHandle? createSession({
    required Uint8List bytes,
    required String submissionId,
    required int submissionVersion,
    int initialPage = 1,
  });

  void navigateToPage(PdfWebSessionHandle? handle, int pageNumber);

  bool openInBrowserTab(PdfWebSessionHandle? handle, {int? pageNumber});

  void revokeSession(PdfWebSessionHandle? handle);

  void revokeAllSessions();
}
