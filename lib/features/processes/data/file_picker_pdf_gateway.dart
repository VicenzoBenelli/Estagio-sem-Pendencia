import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../domain/document_models.dart';
import '../domain/document_repository.dart';

class FilePickerPdfGateway implements PdfPickerGateway {
  const FilePickerPdfGateway();

  @override
  Future<SelectedPdfFile?> pickPdf() async {
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: 'Selecionar documento PDF',
        type: FileType.custom,
        allowedExtensions: const <String>['pdf'],
      );
      if (picked == null) {
        return null;
      }

      final safeName = extractSanitizedBasename(picked.name);
      final reportedSize = picked.lengthSync() ?? await picked.length();

      // Evita carregar arquivos gigantes em memória no Android/Web antes de reportar erro.
      if (reportedSize != null && reportedSize > kMaxPdfSizeBytes) {
        return SelectedPdfFile(
          name: safeName.isEmpty ? picked.name : safeName,
          bytes: Uint8List(0),
          sizeBytes: reportedSize,
        );
      }

      final bytes = await picked.readAsBytes();
      return SelectedPdfFile(
        name: safeName.isEmpty ? picked.name : safeName,
        bytes: bytes,
        sizeBytes: reportedSize ?? bytes.lengthInBytes,
      );
    } on DocumentFailure {
      rethrow;
    } catch (_) {
      throw const DocumentFailure(
        'Não foi possível acessar o arquivo selecionado no dispositivo.',
        code: 'file_pick_failed',
      );
    }
  }

  @override
  Future<bool> savePdf({
    required String filename,
    required Uint8List bytes,
  }) async {
    final safeName = extractSanitizedBasename(filename);
    final targetName = safeName.toLowerCase().endsWith('.pdf')
        ? safeName
        : 'documento_estagio.pdf';

    try {
      final uri = await FilePicker.saveFile(
        fileName: targetName,
        bytes: bytes,
        mimeType: 'application/pdf',
        dialogTitle: 'Salvar documento PDF',
      );
      // Na Web, FilePicker.saveFile dispara o download direto no navegador e retorna null.
      // Em plataformas nativas com diálogo SAF, null significa cancelamento pelo usuário.
      return uri != null || kIsWeb;
    } catch (_) {
      throw const DocumentFailure(
        'Não foi possível salvar o documento PDF no dispositivo.',
        code: 'file_save_failed',
      );
    }
  }
}
