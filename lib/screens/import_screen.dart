import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';     // ✅ Fixes base64Decode
import 'dart:typed_data';  // ✅ Fixes Uint8List

import '../auth.dart';
import '../export_import.dart';
import '../storage.dart';
import '../sync.dart';
import '../utils.dart';
import 'pin_gate.dart';
import '../crypto.dart';
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _selectedFile;
  String? _error;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['vltx', 'csv'],
      );

      if (result != null && result.files.single.path != null) {
        setState(() {
          _selectedFile = result.files.single.path;
          _error = null;
        });
      }
    } catch (e) {
      setState(() => _error = 'Failed to pick file: $e');
    }
  }

  Future<void> _import() async {
    if (_selectedFile == null) { setState(() => _error = 'Please select a file first'); return; }

    final isVltx = _selectedFile!.toLowerCase().endsWith('.vltx');
    if (isVltx && _passwordCtrl.text.isEmpty) { setState(() => _error = 'Export password is required for .vltx files'); return; }

    setState(() { _loading = true; _error = null; });

    try {
      // ✅ ALWAYS ask for PIN (needed for both vltx and csv to encrypt passwords)
      final pin = await PinGateScreen.show(context);
      if (pin == null || !mounted) { setState(() => _loading = false); return; }

      final secure = SecureStorageService();
      final saltB64 = await secure.read(SecureKeys.vaultKeySalt);
      if (!mounted) return;
      if (saltB64 == null) throw StorageException('Vault key salt missing.');

      final currentVaultKey = await CryptoService.derivePinKey(pin, base64Decode(saltB64));
      if (!mounted) return;

      final auth = context.read<AuthService>();
      final db = AppDatabase();
      final userId = auth.user!.id;
      final sync = SyncService(db: db, secure: secure, userId: userId);
      final masterSalt = auth.user!.userMetadata?['master_salt'] as String? ?? '';

      final service = ExportImportService(db: db, sync: sync, masterSalt: masterSalt, sessionKey: auth.sessionKey);

      int importedCount;
      if (isVltx) {
        importedCount = await service.importEncryptedBackup(_selectedFile!, _passwordCtrl.text, currentVaultKey);
      } else {
        // ✅ Pass vaultKey to CSV import
        importedCount = await service.importPlaintextCSV(_selectedFile!, currentVaultKey);
      }

      CryptoService.zeroMemory(currentVaultKey);

      if (!mounted) return;
      Navigator.pop(context);
      _showSuccessDialog('Import Successful', 'Successfully imported $importedCount entries into your vault.');
    } catch (e) {
      if (mounted) setState(() { _error = 'Import failed: $e'; _loading = false; });
    }
  }
  void _showSuccessDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isVltx = _selectedFile?.toLowerCase().endsWith('.vltx') ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Import Vault')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Select Backup File',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    const Text(
                      'Supported formats:\n'
                          '• .vltx (Encrypted VaultX backup)\n'
                          '• .csv (Plaintext CSV from other password managers)',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : _pickFile,
                      icon: const Icon(Icons.folder_open),
                      label: Text(_selectedFile == null
                          ? 'Choose File'
                          : 'Change File'),
                    ),
                    if (_selectedFile != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isVltx ? Icons.lock : Icons.table_chart,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _selectedFile!.split(Platform.pathSeparator).last,
                                style: const TextStyle(fontWeight: FontWeight.w500),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            if (isVltx) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Export Password',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 8),
                      const Text(
                        'Enter the password you used when creating this backup.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _obscure,
                        decoration: InputDecoration(
                          labelText: 'Export Password',
                          prefixIcon: const Icon(Icons.key),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],

            FilledButton.icon(
              onPressed: (_loading || _selectedFile == null) ? null : _import,
              icon: _loading
                  ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
                  : const Icon(Icons.upload_file),
              label: Text(_loading ? 'Importing...' : 'Import'),
            ),

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error, color: Colors.red.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info, color: Colors.blue.shade700, size: 20),
                        const SizedBox(width: 8),
                        Text('About Import',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade700)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '• Imported entries will be added to your existing vault\n'
                          '• Duplicate entries (same site name + username) may be created\n'
                          '• All imported data is encrypted with your current master password\n'
                          '• Imported entries will sync to Supabase automatically',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}