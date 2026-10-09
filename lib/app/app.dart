import 'package:flutter/material.dart';

import '../features/home/presentation/home_page.dart';
import 'app_theme.dart';

class EstagioSemPendenciaApp extends StatelessWidget {
  const EstagioSemPendenciaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Estágio sem Pendência',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    home: const HomePage(),
  );
}
