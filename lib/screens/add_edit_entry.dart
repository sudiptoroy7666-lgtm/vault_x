import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../crypto.dart';
import '../generator.dart';
import '../models.dart';
import '../storage.dart';
import '../sync.dart';
import '../utils.dart';
import 'pin_gate.dart'; // Required for secure PIN entry

class AddEditEntryScreen extends StatefulWidget {
  final String? entryId;
  const AddEditEntryScreen({super.key, this.entryId});

  @override
  State<AddEditEntryScreen> createState() => _AddEditEntryScreenState();
}

class _AddEditEntryScreenState extends State<AddEditEntryScreen> {
  final _formKey      = GlobalKey<FormState>();
  final _siteCtrl     = TextEditingController();
  final _urlCtrl      = TextEditingController();
  final _userCtrl     = TextEditingController();
  final _passCtrl     = TextEditingController();
  final _notesCtrl    = TextEditingController();
  final _categoryCtrl = TextEditingController();

  final _db     = AppDatabase();
  final _secure = SecureStorageService();

  bool _loading      = false;
  bool _obscurePass  = true;
  bool _isFavourite  = false;
  bool _isBreached   = false;
  bool _hibpChecking = false;
  int  _strength     = 0;
  String? _hibpStatus;

  EncryptedEntry? _existing;
  Uint8List?      _vaultKey; // zeroed in dispose

  bool get _isEdit => widget.entryId != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) _loadExisting();
  }

  @override
  void dispose() {
    if (_vaultKey != null) CryptoService.zeroMemory(_vaultKey!);
    _siteCtrl.dispose();
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _notesCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  // ── Derive Vault Key (Secure PIN Gate) ─────────────────────────────────────

  Future<Uint8List?> _deriveVaultKey() async {
    final saltB64 = await _secure.read(SecureKeys.vaultKeySalt);
    if (saltB64 == null) {
      _showError('Vault key salt missing. Please re-setup your PIN.');
      return null;
    }

    // Use the official PinGateScreen (enforces 10-attempt wipe, cooldown, screenshots)
    final pin = await PinGateScreen.show(context);
    if (pin == null || !mounted) return null;

    try {
      return await CryptoService.derivePinKey(pin, base64Decode(saltB64));
    } catch (e) {
      if (mounted) _showError('Key derivation failed: $e');
      return null;
    }
  }

  // ── Load existing (edit mode) ──────────────────────────────────────────────

  Future<void> _loadExisting() async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final entry = await _db.getEntry(widget.entryId!);
      if (!mounted) return;

      if (entry == null) {
        context.pop();
        return;
      }
      _existing = entry;

      // Guard against auto-lock happening while the app was backgrounded
      final auth = context.read<AuthService>();
      if (!auth.vaultUnlocked) {
        if (mounted) context.pop();
        return;
      }

      // Session key for all fields except password — no PIN needed
      final sessionKey = auth.sessionKey;

      // Vault key (PIN) only for password
      final key = await _deriveVaultKey();
      if (key == null || !mounted) {
        if (mounted) context.pop();
        return;
      }
      _vaultKey = key;

      Future<String> decS(Uint8List c, Uint8List n) async =>
          utf8.decode(await CryptoService.decrypt(c, n, sessionKey));
      Future<String> decV(Uint8List c, Uint8List n) async =>
          utf8.decode(await CryptoService.decrypt(c, n, key));

      _siteCtrl.text     = await decS(entry.siteNameCipher,  entry.siteNameNonce);
      _urlCtrl.text      = await decS(entry.siteUrlCipher,   entry.siteUrlNonce);
      _userCtrl.text     = await decS(entry.usernameCipher,  entry.usernameNonce);
      _passCtrl.text     = await decV(entry.passwordCipher,  entry.passwordNonce);
      _notesCtrl.text    = await decS(entry.notesCipher,     entry.notesNonce);
      _categoryCtrl.text = await decS(entry.categoryCipher,  entry.categoryNonce);

      if (mounted) {
        setState(() {
          _isFavourite = entry.isFavourite;
          _isBreached  = entry.isBreached;
          _strength    = PasswordGenerator.scorePassword(_passCtrl.text).score;
          _loading     = false;
        });
      }
    } catch (e) {
      log.e('Load for edit failed: $e');
      if (mounted) context.pop();
    }
  }

  // ── HIBP check ─────────────────────────────────────────────────────────────

  Future<void> _checkBreach() async {
    if (_passCtrl.text.isEmpty) return;
    setState(() { _hibpChecking = true; _hibpStatus = null; });
    try {
      final breached = await PasswordGenerator.checkBreach(_passCtrl.text);
      if (mounted) {
        setState(() {
          _isBreached   = breached;
          _hibpStatus   = breached
              ? '⚠️ Found in a known breach!'
              : '✓ Not found in known breaches';
          _hibpChecking = false;
        });
      }
    } on NetworkException {
      if (mounted) {
        setState(() {
          _hibpStatus   = 'HIBP check skipped (offline)';
          _hibpChecking = false;
        });
      }
    }
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    final auth = context.read<AuthService>();

    // Guard against vault locking in the background
    if (!auth.vaultUnlocked) {
      _showError('Vault is locked. Please unlock and try again.');
      if (mounted) setState(() => _loading = false);
      return;
    }

    final sessionKey = auth.sessionKey;
    final uid        = auth.user?.id;

    try {
      Uint8List vaultKey;
      if (_vaultKey != null) {
        vaultKey = _vaultKey!;
      } else {
        final key = await _deriveVaultKey();
        if (key == null || !mounted) {
          if (mounted) setState(() => _loading = false);
          return;
        }
        vaultKey = key;
      }

      await _checkBreach();

      // Session key for metadata — readable in vault list without PIN
      Future<EncryptedData> encS(String v) =>
          CryptoService.encrypt(_b(v), sessionKey);
      // Vault key (PIN) for password only
      Future<EncryptedData> encV(String v) =>
          CryptoService.encrypt(_b(v), vaultKey);

      final siteEnc  = await encS(_siteCtrl.text.trim());
      final urlEnc   = await encS(_urlCtrl.text.trim());
      final userEnc  = await encS(_userCtrl.text.trim());
      final passEnc  = await encV(_passCtrl.text);
      final notesEnc = await encS(_notesCtrl.text.trim());
      final catEnc   = await encS(_categoryCtrl.text.trim());

      CryptoService.zeroMemory(vaultKey);
      _vaultKey = null;

      final deviceId = await AuthService.getDeviceId();
      final now      = DateTime.now();
      final id       = _existing?.id ?? const Uuid().v4();

      final entry = EncryptedEntry(
        id:             id,
        siteNameNonce:  siteEnc.nonce,   siteNameCipher:  siteEnc.ciphertext,
        siteUrlNonce:   urlEnc.nonce,    siteUrlCipher:   urlEnc.ciphertext,
        usernameNonce:  userEnc.nonce,   usernameCipher:  userEnc.ciphertext,
        passwordNonce:  passEnc.nonce,   passwordCipher:  passEnc.ciphertext,
        notesNonce:     notesEnc.nonce,  notesCipher:     notesEnc.ciphertext,
        categoryNonce:  catEnc.nonce,    categoryCipher:  catEnc.ciphertext,
        isFavourite:    _isFavourite,
        isBreached:     _isBreached,
        createdAt:      _existing?.createdAt ?? now,
        modifiedAt:     now,
        deviceId:       deviceId,
        syncPending:    true,
      );

      if (_existing == null) {
        await _db.insertEntry(entry);
      } else {
        await _db.updateEntry(entry);
      }

      if (uid != null) {
        try {
          final sync = SyncService(db: _db, secure: _secure, userId: uid);
          await sync.uploadEntry(entry);
          await _db.markSynced(id);
        } catch (e) {
          log.w('Sync after save failed: $e');
        }
      }

      if (mounted) context.pop();
    } on ValidationException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('Save failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  // ── Generator ──────────────────────────────────────────────────────────────

  void _generate(String tier) {
    final pw = tier == 'maximum'
        ? PasswordGenerator.generateMaximum()
        : tier == 'very_strong'
        ? PasswordGenerator.generateVeryStrong()
        : PasswordGenerator.generateStrong();
    setState(() {
      _passCtrl.text = pw;
      _strength      = PasswordGenerator.scorePassword(pw).score;
      _hibpStatus    = null;
      _isBreached    = false;
    });
  }

  Color _strengthColor() {
    switch (_strength) {
      case 0: case 1: return Colors.red;
      case 2:         return Colors.orange;
      case 3:         return Colors.blue;
      case 4:         return Colors.green;
      default:        return Colors.grey;
    }
  }

  Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Entry' : 'Add Entry'),
        actions: [
          _loading
              ? const Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(
              child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          )
              : TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: (_loading && _isEdit)
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Site Name
              TextFormField(
                controller: _siteCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Site Name *',
                  prefixIcon: Icon(Icons.web),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 14),

              // URL
              TextFormField(
                controller: _urlCtrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  prefixIcon: Icon(Icons.link),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),

              // Username
              TextFormField(
                controller: _userCtrl,
                decoration: const InputDecoration(
                  labelText: 'Username / Email *',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 14),

              // Password + strength
              TextFormField(
                controller: _passCtrl,
                obscureText: _obscurePass,
                onChanged: (v) => setState(() {
                  _strength   = PasswordGenerator.scorePassword(v).score;
                  _hibpStatus = null;
                }),
                decoration: InputDecoration(
                  labelText: 'Password *',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePass
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass),
                  ),
                ),
                validator: (v) =>
                (v == null || v.isEmpty) ? 'Required' : null,
              ),

              if (_passCtrl.text.isNotEmpty) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: (_strength + 1) / 5,
                  color: _strengthColor(),
                  backgroundColor: Colors.grey.shade200,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      PasswordGenerator.scorePassword(_passCtrl.text).label,
                      style:
                      TextStyle(color: _strengthColor(), fontSize: 12),
                    ),
                    if (_hibpChecking)
                      const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5))
                    else if (_hibpStatus != null)
                      Text(_hibpStatus!,
                          style: TextStyle(
                              fontSize: 11,
                              color: _isBreached
                                  ? Colors.red
                                  : Colors.green)),
                  ],
                ),
              ],
              const SizedBox(height: 10),

              // Inline generator
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Generate Password',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _generate('strong'),
                            child: const Text('Strong\n15 chars',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 11)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _generate('very_strong'),
                            child: const Text('Very Strong\n20 chars',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 11)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _generate('maximum'),
                            child: const Text('Maximum\n24 chars',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 11)),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Category
              TextFormField(
                controller: _categoryCtrl,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  prefixIcon: Icon(Icons.folder_outlined),
                  border: OutlineInputBorder(),
                  hintText: 'e.g. Social, Work, Banking',
                ),
              ),
              const SizedBox(height: 14),

              // Notes
              TextFormField(
                controller: _notesCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  prefixIcon: Icon(Icons.notes),
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 14),

              // Favourite
              SwitchListTile(
                title:     const Text('Mark as Favourite'),
                secondary: const Icon(Icons.star_outline),
                value:     _isFavourite,
                onChanged: (v) => setState(() => _isFavourite = v),
              ),
              const SizedBox(height: 24),

              FilledButton(
                onPressed: _loading ? null : _save,
                child: Text(_isEdit ? 'Update Entry' : 'Save Entry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}