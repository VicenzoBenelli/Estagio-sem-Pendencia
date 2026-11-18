import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:estagio_sem_pendencia/features/processes/data/supabase_document_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/data/supabase_process_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/document_models.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/process_models.dart';

Uint8List _buildMinimalValidPdfBytes(String label) {
  final safeLabel = label.replaceAll(RegExp(r'[()\\]'), ' ');
  final stream = 'BT\n/F1 12 Tf\n72 720 Td\n($safeLabel) Tj\nET\n';
  final objects = <String>[
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n',
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n',
    '4 0 obj\n<< /Length ${latin1.encode(stream).length} >>\nstream\n$stream'
        'endstream\nendobj\n',
    '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
  ];

  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  var offset = latin1.encode('%PDF-1.4\n').length;
  for (final obj in objects) {
    offsets.add(offset);
    buffer.write(obj);
    offset += latin1.encode(obj).length;
  }
  final xrefOffset = offset;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (var i = 1; i < offsets.length; i++) {
    buffer.write('${offsets[i].toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF\n',
  );
  return Uint8List.fromList(latin1.encode(buffer.toString()));
}

Map<String, String> _readLocalSupabaseStatus() {
  final result = Process.runSync(
    Platform.isWindows ? 'npx.cmd' : 'npx',
    const <String>['supabase', 'status', '-o', 'json'],
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Supabase local precisa estar em execução para o teste de integração real.',
    );
  }
  final raw = result.stdout.toString();
  final idx = raw.indexOf('{');
  if (idx == -1) {
    throw StateError('Saída inesperada de supabase status -o json.');
  }
  final decoded = jsonDecode(raw.substring(idx)) as Map<String, dynamic>;
  return <String, String>{
    'apiUrl': (decoded['API_URL'] as String).replaceAll(RegExp(r'/$'), ''),
    'anonKey': decoded['ANON_KEY'] as String,
    'serviceRoleKey': decoded['SERVICE_ROLE_KEY'] as String,
  };
}

void main() {
  test('Integração real Flutter SDK -> GoTrue, create_internship_process, Edge submit-requirement-pdf e Storage privado', () async {
    final env = _readLocalSupabaseStatus();
    final apiUrl = env['apiUrl']!;
    final anonKey = env['anonKey']!;
    final serviceRoleKey = env['serviceRoleKey']!;
    final runTag = DateTime.now().microsecondsSinceEpoch.toString();
    final email = 'flutter.int.l3.$runTag@demo.local';
    final password = 'DemoFlutter!$runTag';

    // Provisiona apenas a fixture isolada do usuário no backend local de teste
    final createRes = await http.post(
      Uri.parse('$apiUrl/auth/v1/admin/users'),
      headers: <String, String>{
        'apikey': serviceRoleKey,
        'Authorization': 'Bearer $serviceRoleKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'email': email,
        'password': password,
        'email_confirm': true,
        'user_metadata': const <String, dynamic>{
          'full_name': 'Estudante Integracao Flutter L3',
        },
      }),
    );
    expect(createRes.statusCode, 200);

    // Cliente SDK real utilizando exclusivamente a chave pública (nunca service_role)
    final client = SupabaseClient(apiUrl, anonKey);
    addTearDown(client.dispose);

    final signIn = await client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    expect(signIn.session?.accessToken, isNotEmpty);

    final processRepo = SupabaseProcessRepository(client);
    final documentRepo = SupabaseDocumentRepository(client);

    final catalog = await processRepo.fetchActiveCatalog();
    final targetModality = catalog.firstWhere((m) => m.hasPublishedTemplate);

    final createdProcess = await processRepo.createProcess(
      courseModalityId: targetModality.id,
    );
    final detailBefore = await processRepo.fetchProcessDetail(
      processId: createdProcess.id,
    );
    expect(detailBefore, isNotNull);
    expect(detailBefore!.requirements, isNotEmpty);
    final targetReq = detailBefore.requirements.first;
    expect(targetReq.status, RequirementStatus.notSubmitted);

    final pdfBytes = _buildMinimalValidPdfBytes('Integracao Flutter $runTag');
    final idemKey = generateUuidV4();
    final selected = SelectedPdfFile(
      name: 'termo_integracao_flutter.pdf',
      bytes: pdfBytes,
    );

    // 1) Envio real para Edge Function submit-requirement-pdf
    final outcome1 = await documentRepo.submitRequirementPdf(
      processRequirementId: targetReq.id,
      file: selected,
      idempotencyKey: idemKey,
    );
    expect(outcome1.idempotentReplay, isFalse);
    expect(outcome1.submission.version, 1);
    expect(outcome1.submission.status, SubmissionStatus.underReview);
    expect(outcome1.requirementStatus, RequirementStatus.underReview);
    expect(outcome1.currentVersion, 1);
    expect(outcome1.currentSubmissionId, outcome1.submission.id);
    expect(outcome1.submission.storageBucket, kPrivateDocumentsBucket);

    // 2) Retry idempotente real retorna 200 replay sem criar v2
    final outcomeReplay = await documentRepo.submitRequirementPdf(
      processRequirementId: targetReq.id,
      file: selected,
      idempotencyKey: idemKey,
    );
    expect(outcomeReplay.idempotentReplay, isTrue);
    expect(outcomeReplay.submission.id, outcome1.submission.id);
    expect(outcomeReplay.submission.version, 1);

    // 3) Consulta via RLS por idempotency_key + histórico de versões
    final foundByKey = await documentRepo.findSubmissionByIdempotencyKey(
      processRequirementId: targetReq.id,
      idempotencyKey: idemKey,
    );
    expect(foundByKey?.id, outcome1.submission.id);

    final history = await documentRepo.fetchRequirementSubmissions(
      processRequirementId: targetReq.id,
    );
    expect(history.length, 1);
    expect(history.single.id, outcome1.submission.id);

    // 4) Download privado real via storage.from('internship-documents').download(...)
    final downloadedBytes = await documentRepo.downloadSubmissionBytes(
      storageBucket: outcome1.submission.storageBucket,
      storagePath: outcome1.submission.storagePath,
    );
    expect(downloadedBytes, equals(pdfBytes));

    // 5) Após logout, download e novo upload falham com erro autorizado seguro
    await client.auth.signOut();
    await expectLater(
      documentRepo.downloadSubmissionBytes(
        storageBucket: outcome1.submission.storageBucket,
        storagePath: outcome1.submission.storagePath,
      ),
      throwsA(isA<DocumentFailure>()),
    );
  });
}
