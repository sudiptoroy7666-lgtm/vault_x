import 'dart:io';

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

class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key});

  static Future<void> show(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => const ExportDialog(),
    );
  }

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _exportEncrypted() async {
    if (_passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Export password is required');
      return;
    }
    if (_passwordCtrl.text.length < 15) {
      setState(() => _error = 'Export password must be at least 15 characters');
      return;
    }
    if (_passwordCtrl.text != _confirmCtrl.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 1. Ask for Vault PIN to decrypt passwords
      final pin = await PinGateScreen.show(context);
      if (pin == null || !mounted) {
        setState(() => _loading = false);
        return;
      }

      final secure = SecureStorageService();
      final saltB64 = await secure.read(SecureKeys.vaultKeySalt);

      // ✅ FIX: Check mounted after async gap
      if (!mounted) return;

      if (saltB64 == null) throw StorageException('Vault key salt missing.');

      final vaultKey = await CryptoService.derivePinKey(pin, base64Decode(saltB64));

      // ✅ FIX: Check mounted after crypto async gap
      if (!mounted) return;

      // Now it is safe to use context.read
      final auth = context.read<AuthService>();
      final db = AppDatabase();
      final userId = auth.user!.id;
      final sync = SyncService(db: db, secure: secure, userId: userId);
      final masterSalt = auth.user!.userMetadata?['master_salt'] as String? ?? '';

      final service = ExportImportService(
        db: db,
        sync: sync,
        masterSalt: masterSalt,
        sessionKey: auth.sessionKey,
      );

      final filePath = await service.exportEncryptedBackup(_passwordCtrl.text, vaultKey);
      CryptoService.zeroMemory(vaultKey);

      if (!mounted) return;
      Navigator.pop(context);
      _showSuccessDialog(
          'Encrypted Backup Exported',
          'Your vault has been securely saved to:\n\n$filePath\n\nThis file is completely portable and independent of your Supabase account.');

    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Export failed: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _exportCSV() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ Security Warning'),
        content: const Text('This will create a PLAINTEXT CSV file containing all your passwords. Anyone with access to this file can read your passwords.\n\nOnly use this for migrating to another password manager. Delete the file immediately after use.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: Colors.orange), child: const Text('I Understand')),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() => _loading = true);

    try {
      // ✅ Ask for PIN to decrypt passwords for CSV
      final pin = await PinGateScreen.show(context);
      if (pin == null || !mounted) { setState(() => _loading = false); return; }

      final secure = SecureStorageService();
      final saltB64 = await secure.read(SecureKeys.vaultKeySalt);
      if (!mounted) return;
      if (saltB64 == null) throw StorageException('Vault key salt missing.');

      final vaultKey = await CryptoService.derivePinKey(pin, base64Decode(saltB64));
      if (!mounted) return;

      final auth = context.read<AuthService>();
      final db = AppDatabase();
      final userId = auth.user!.id;
      final sync = SyncService(db: db, secure: secure, userId: userId);
      final masterSalt = auth.user!.userMetadata?['master_salt'] as String? ?? '';

      final service = ExportImportService(db: db, sync: sync, masterSalt: masterSalt, sessionKey: auth.sessionKey);

      // ✅ Pass vaultKey
      final filePath = await service.exportPlaintextCSV(vaultKey);
      CryptoService.zeroMemory(vaultKey);

      if (!mounted) return;
      Navigator.pop(context);
      _showSuccessDialog(
          'CSV Exported',
          'Your vault has been exported to:\n\n$filePath\n\n⚠️ DELETE THIS FILE AFTER USE!');
    } catch (e) {
      if (mounted) setState(() { _error = 'Export failed: $e'; _loading = false; });
    }
  }

  void _showSuccessDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(message),
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
    return AlertDialog(
      title: const Text('Export Vault'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Choose an export format:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.lock, color: Colors.green, size: 20),
                        const SizedBox(width: 8),
                        const Text('Encrypted Backup (.vltx)',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Secure backup file encrypted with a password you choose. '
                          'Can only be restored in VaultX.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordCtrl,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: 'Export Password (15+ chars)',
                        isDense: true,
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _confirmCtrl,
                      obscureText: _obscure,
                      decoration: const InputDecoration(
                        labelText: 'Confirm Password',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _loading ? null : _exportEncrypted,
                      icon: const Icon(Icons.download),
                      label: const Text('Export Encrypted'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.warning, color: Colors.orange, size: 20),
                        const SizedBox(width: 8),
                        const Text('Plaintext CSV',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Unencrypted CSV file. Use for migrating to other password managers. '
                          '⚠️ DELETE AFTER USE!',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : _exportCSV,
                      icon: const Icon(Icons.table_chart),
                      label: const Text('Export CSV'),
                    ),
                  ],
                ),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}