import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'crypto.dart';
import 'models.dart';
import 'storage.dart';
import 'sync.dart';
import 'utils.dart';

/// Export/Import service for vault data backup and migration.
class ExportImportService {
  final AppDatabase _db;
  final SyncService _sync;
  final String _masterSalt;
  final Uint8List _sessionKey;

  ExportImportService({
    required AppDatabase db,
    required SyncService sync,
    required String masterSalt,
    required Uint8List sessionKey,
  })  : _db = db,
        _sync = sync,
        _masterSalt = masterSalt,
        _sessionKey = sessionKey;

  // ── Native Save As Helper (Fixes Android 13+ Scoped Storage) ───────────────

  Future<String> _saveExportFile(String extension, String content) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'vaultx_backup_$timestamp.$extension';
    final bytes = Uint8List.fromList(utf8.encode(content));

    // Opens the native OS "Save As" dialog.
    // On Android 13+, this uses SAF to let the user pick Downloads, Drive, etc.
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Vault Backup',
      fileName: fileName,
      // On Android, the plugin handles writing the bytes to the SAF URI.
      // On Windows, the plugin just returns the path, so we pass null here.
      bytes: Platform.isAndroid ? bytes : null,
    );

    if (path == null) {
      throw StorageException('Export cancelled by user.');
    }

    // On Windows, we must write the file manually to the returned path.
    if (!Platform.isAndroid) {
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
    }

    return path;
  }

  // ── Export Encrypted Backup (.vltx) ─────────────────────────────────────────

  Future<String> exportEncryptedBackup(String exportPassword, Uint8List vaultKey) async {
    final entries = await _db.getAllEntries();
    final exportSalt = CryptoService.generateSalt();
    final exportKey = await CryptoService.deriveKey(exportPassword, exportSalt);
    final exportedEntries = <Map<String, dynamic>>[];

    // ... (Keep all your decryption and re-encryption logic exactly as is) ...

    final exportData = {
      'version': '2.0',
      'format': 'vltx_portable',
      'exported_at': DateTime.now().toIso8601String(),
      'export_salt': base64Encode(exportSalt),
      'entries': exportedEntries,
    };

    final jsonStr = jsonEncode(exportData);

    // ✅ FIX: Use native Save As dialog
    final filePath = await _saveExportFile('vltx', jsonStr);

    CryptoService.zeroMemory(exportKey);
    return filePath;
  }

  // ── Export Plaintext CSV ────────────────────────────────────────────────────

  Future<String> exportPlaintextCSV(Uint8List vaultKey) async {
    final entries = await _db.getAllEntries();
    final decryptedEntries = <Map<String, String>>[];

    // ... (Keep all your CSV generation logic exactly as is) ...

    final buffer = StringBuffer();
    buffer.writeln('site_name,site_url,username,password,notes,category,is_favourite,created_at,modified_at');
    // ... (Keep the CSV row building logic exactly as is) ...

    final csvContent = buffer.toString();

    // ✅ FIX: Use native Save As dialog
    final filePath = await _saveExportFile('csv', csvContent);

    return filePath;
  }


  // ── Import from .vltx ───────────────────────────────────────────────────────

  Future<int> importEncryptedBackup(String filePath, String exportPassword, Uint8List currentVaultKey) async {
    final file = File(filePath);
    if (!await file.exists()) throw StorageException('Backup file not found.');

    final jsonStr = await file.readAsString();
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;

    if (data['format'] != 'vltx_portable') throw ValidationException('Invalid or unsupported backup file format.');

    final exportSalt = base64Decode(data['export_salt'] as String);
    final exportKey = await CryptoService.deriveKey(exportPassword, exportSalt);

    try {
      final entries = data['entries'] as List<dynamic>;
      int importedCount = 0;

      for (final entryData in entries) {
        try {
          final map = entryData as Map<String, dynamic>;

          final siteName = utf8.decode(await CryptoService.decrypt(base64Decode(map['site_name']['cipher']), base64Decode(map['site_name']['nonce']), exportKey));
          final siteUrl = utf8.decode(await CryptoService.decrypt(base64Decode(map['site_url']['cipher']), base64Decode(map['site_url']['nonce']), exportKey));
          final username = utf8.decode(await CryptoService.decrypt(base64Decode(map['username']['cipher']), base64Decode(map['username']['nonce']), exportKey));
          final password = utf8.decode(await CryptoService.decrypt(base64Decode(map['password']['cipher']), base64Decode(map['password']['nonce']), exportKey));
          final notes = utf8.decode(await CryptoService.decrypt(base64Decode(map['notes']['cipher']), base64Decode(map['notes']['nonce']), exportKey));
          final category = utf8.decode(await CryptoService.decrypt(base64Decode(map['category']['cipher']), base64Decode(map['category']['nonce']), exportKey));

          final encSiteName = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(siteName)), _sessionKey);
          final encSiteUrl = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(siteUrl)), _sessionKey);
          final encUsername = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(username)), _sessionKey);
          final encNotes = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(notes)), _sessionKey);
          final encCategory = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(category)), _sessionKey);

          // ✅ Password encrypted with currentVaultKey
          final encPassword = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(password)), currentVaultKey);

          final newEntry = EncryptedEntry(
            id: const Uuid().v4(),
            siteNameNonce: encSiteName.nonce, siteNameCipher: encSiteName.ciphertext,
            siteUrlNonce: encSiteUrl.nonce, siteUrlCipher: encSiteUrl.ciphertext,
            usernameNonce: encUsername.nonce, usernameCipher: encUsername.ciphertext,
            passwordNonce: encPassword.nonce, passwordCipher: encPassword.ciphertext,
            notesNonce: encNotes.nonce, notesCipher: encNotes.ciphertext,
            categoryNonce: encCategory.nonce, categoryCipher: encCategory.ciphertext,
            isFavourite: map['is_favourite'] as bool? ?? false,
            isBreached: false,
            createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
            modifiedAt: DateTime.now(),
            deviceId: await AuthService.getDeviceId(),
            syncPending: true,
            deleted: false,
          );

          await _db.insertEntry(newEntry);
          await _sync.uploadEntry(newEntry);
          importedCount++;
        } catch (e) {
          log.w('Failed to import entry: $e');
        }
      }
      return importedCount;
    } finally {
      CryptoService.zeroMemory(exportKey);
    }
  }

  // ── Import from CSV ─────────────────────────────────────────────────────────

  Future<int> importPlaintextCSV(String filePath, Uint8List currentVaultKey) async {
    final file = File(filePath);
    if (!await file.exists()) throw StorageException('CSV file not found.');

    final content = await file.readAsString();
    final lines = content.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) throw ValidationException('CSV file is empty.');

    final header = lines.first.split(',');
    final dataLines = lines.skip(1).toList();
    int importedCount = 0;

    for (final line in dataLines) {
      try {
        final values = _parseCSVLine(line);
        if (values.length < header.length) continue;

        final entry = await _importCSVRow(header, values, currentVaultKey);
        await _db.insertEntry(entry);
        await _sync.uploadEntry(entry);
        importedCount++;
      } catch (e) {
        log.w('Failed to import CSV row: $e');
      }
    }
    return importedCount;
  }

  List<String> _parseCSVLine(String line) {
    final result = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') { buffer.write('"'); i++; }
        else { inQuotes = !inQuotes; }
      } else if (char == ',' && !inQuotes) { result.add(buffer.toString()); buffer.clear(); }
      else { buffer.write(char); }
    }
    result.add(buffer.toString());
    return result;
  }

  Future<EncryptedEntry> _importCSVRow(List<String> header, List<String> values, Uint8List currentVaultKey) async {
    final data = <String, String>{};
    for (int i = 0; i < header.length && i < values.length; i++) {
      data[header[i].trim()] = values[i].trim();
    }

    final now = DateTime.now();
    final id = const Uuid().v4();
    final deviceId = await AuthService.getDeviceId();

    final siteName = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(data['site_name'] ?? '')), _sessionKey);
    final siteUrl = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(data['site_url'] ?? '')), _sessionKey);
    final username = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(data['username'] ?? '')), _sessionKey);
    final notes = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(data['notes'] ?? '')), _sessionKey);
    final category = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(data['category'] ?? '')), _sessionKey);

    // ✅ FIX: Password must be encrypted with currentVaultKey
    final password = await CryptoService.encrypt(Uint8List.fromList(utf8.encode(data['password'] ?? '')), currentVaultKey);

    return EncryptedEntry(
      id: id,
      siteNameNonce: siteName.nonce, siteNameCipher: siteName.ciphertext,
      siteUrlNonce: siteUrl.nonce, siteUrlCipher: siteUrl.ciphertext,
      usernameNonce: username.nonce, usernameCipher: username.ciphertext,
      passwordNonce: password.nonce, passwordCipher: password.ciphertext,
      notesNonce: notes.nonce, notesCipher: notes.ciphertext,
      categoryNonce: category.nonce, categoryCipher: category.ciphertext,
      isFavourite: data['is_favourite']?.toLowerCase() == 'true',
      isBreached: false,
      createdAt: DateTime.tryParse(data['created_at'] ?? '') ?? now,
      modifiedAt: now,
      deviceId: deviceId,
      syncPending: true,
      deleted: false,
    );
  }
}