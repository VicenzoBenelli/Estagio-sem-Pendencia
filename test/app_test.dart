import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:estagio_sem_pendencia/app/app.dart';

void main() {
  testWidgets('exibe a fundação em largura compacta', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const EstagioSemPendenciaApp());

    expect(find.text('Estágio sem Pendência'), findsOneWidget);
    expect(find.text('MVP acadêmico em desenvolvimento'), findsOneWidget);
    expect(
      find.textContaining('não representa autorização institucional'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('exibe a fundação em largura ampla', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const EstagioSemPendenciaApp());

    expect(find.text('Estágio sem Pendência'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
