import 'package:flutter/material.dart';

import '../features/auth/application/auth_controller.dart';
import '../features/auth/presentation/auth_gate.dart';
import '../features/processes/domain/document_repository.dart';
import '../features/processes/domain/process_repository.dart';
import '../features/review/data/pdf_document_renderer.dart';
import '../features/review/domain/review_repository.dart';
import 'app_theme.dart';

class EstagioSemPendenciaApp extends StatefulWidget {
  const EstagioSemPendenciaApp({
    this.authController,
    this.processRepository,
    this.documentRepository,
    this.pdfPickerGateway,
    this.reviewRepository,
    this.pdfRendererGateway,
    super.key,
  });

  final AuthController? authController;
  final ProcessRepository? processRepository;
  final DocumentRepository? documentRepository;
  final PdfPickerGateway? pdfPickerGateway;
  final ReviewRepository? reviewRepository;
  final PdfRendererGateway? pdfRendererGateway;

  @override
  State<EstagioSemPendenciaApp> createState() => _EstagioSemPendenciaAppState();
}

class _EstagioSemPendenciaAppState extends State<EstagioSemPendenciaApp> {
  late final AuthController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    if (widget.authController != null) {
      _controller = widget.authController!;
      _ownsController = false;
    } else {
      _controller = AuthController(gateway: null)..initialize();
      _ownsController = true;
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Estágio sem Pendência',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: AuthGate(
        controller: _controller,
        processRepository: widget.processRepository,
        documentRepository: widget.documentRepository,
        pdfPickerGateway: widget.pdfPickerGateway,
        reviewRepository: widget.reviewRepository,
        pdfRendererGateway: widget.pdfRendererGateway,
      ),
    );
  }
}
