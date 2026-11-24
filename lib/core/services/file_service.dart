import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Device file operations used by backup, restore and CSV export.
/// Everything works offline: files are written to local storage and the
/// system share sheet / file picker is used to move them.
class FileService {
  const FileService();

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// Lets the user choose where to save [content]. Returns the saved path,
  /// or null if the user cancelled.
  Future<String?> saveToDevice({
    required String fileName,
    required String content,
    required String extension,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save $fileName',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [extension],
      bytes: bytes,
    );
    if (path == null) return null;
    if (!_isMobile) {
      // Desktop pickers only return a path; write the file ourselves.
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return path;
  }

  /// Writes [content] to a temporary file and opens the share sheet.
  Future<void> share({
    required String fileName,
    required String content,
    String? subject,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, fileName));
    await file.writeAsString(content, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: subject, title: subject),
    );
  }

  /// Stores a copy in the app's private documents folder (used for the
  /// automatic safety backup before a restore).
  Future<String> writeInternal({
    required String folder,
    required String fileName,
    required String content,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, folder));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, fileName));
    await file.writeAsString(content, flush: true);
    return file.path;
  }

  /// Lets the user pick a JSON file and returns its text, or null if
  /// cancelled.
  Future<String?> pickJsonFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choose a MoneyMate backup',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.single;
    final bytes =
        picked.bytes ??
        (picked.path != null ? await File(picked.path!).readAsBytes() : null);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: false);
  }
}
