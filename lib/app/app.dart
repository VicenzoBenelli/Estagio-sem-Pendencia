import 'package:flutter/material.dart';

import '../features/auth/application/auth_controller.dart';
import '../features/auth/presentation/auth_gate.dart';
import 'app_theme.dart';

class EstagioSemPendenciaApp extends StatefulWidget {
  const EstagioSemPendenciaApp({this.authController, super.key});

  final AuthController? authController;

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
      home: AuthGate(controller: _controller),
    );
  }
}
