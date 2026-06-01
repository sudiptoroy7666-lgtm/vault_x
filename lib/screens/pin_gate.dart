import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../auth.dart';
import '../crypto.dart';
import '../platform.dart';
import '../storage.dart';
import '../utils.dart';

// ── PinGateScreen ─────────────────────────────────────────────────────────────

/// Modal PIN entry screen shown before every password reveal.
/// Cannot be dismissed without a correct PIN or explicit Cancel.
/// Returns true if PIN verified, false if cancelled.
class PinGateScreen extends StatefulWidget {
  const PinGateScreen({super.key});

  // Change 1: return String? instead of bool
  static Future<String?> show(BuildContext context) async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const PinGateScreen(),
        fullscreenDialog: true,
      ),
    );
    return result; // the PIN itself, or null if cancelled
  }

  @override
  State<PinGateScreen> createState() => _PinGateScreenState();
}

class _PinGateScreenState extends State<PinGateScreen> {
  final _pinCtrl  = TextEditingController();
  final _secure   = SecureStorageService();
  bool  _loading  = false;
  bool  _cooldown = false;
  int   _failCount   = 0;
  int   _remaining   = 10;
  String? _error;

  @override
  void initState() {
    super.initState();
    PlatformService.blockScreenshots();
    _loadFailCount();
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    PlatformService.unblockScreenshots();
    super.dispose();
  }

  Future<void> _loadFailCount() async {
    final stored = await _secure.read(SecureKeys.pinFailCount);
    final count  = int.tryParse(stored ?? '0') ?? 0;
    if (!mounted) return;
    setState(() {
      _failCount = count;
      _remaining = 10 - count;
    });
    if (count >= 10) _triggerVaultWipe();
  }

  Future<void> _verifyPin() async {
    final pin = _pinCtrl.text.trim();
    if (pin.isEmpty || _cooldown || _loading) return;

    setState(() { _loading = true; _error = null; });

    try {
      final hashB64 = await _secure.read(SecureKeys.pinHash);
      final saltB64 = await _secure.read(SecureKeys.pinSalt);

      if (hashB64 == null || saltB64 == null) {
        setState(() => _error = 'PIN not found. Please restart the app.');
        return;
      }

      final storedHash  = base64Decode(hashB64);
      final salt        = base64Decode(saltB64);

      // Use derivePinKey — no length restriction (PINs are short by design).
      final derivedHash = await CryptoService.derivePinKey(pin, salt);
      final correct     = CryptoService.constantTimeEquals(derivedHash, storedHash);
      CryptoService.zeroMemory(derivedHash);

      // Change 2: pop with the PIN string, not 'true'
      if (correct) {
        await _secure.write(SecureKeys.pinFailCount, '0');
        if (mounted) Navigator.of(context).pop(pin); // ← pin, not true
      } else {
        await _handleFailure();
      }
    } catch (e) {
      setState(() => _error = 'Verification error. Try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleFailure() async {
    _failCount++;
    _remaining = 10 - _failCount;
    await _secure.write(SecureKeys.pinFailCount, _failCount.toString());

    if (_failCount >= 10) {
      _triggerVaultWipe();
      return;
    }

    setState(() {
      _error    = 'Incorrect PIN. $_remaining attempt${_remaining == 1 ? "" : "s"} remaining.';
      _cooldown = true;
    });

    Timer(const Duration(seconds: 30), () {
      if (mounted) setState(() { _cooldown = false; });
    });
  }

  void _triggerVaultWipe() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const VaultWipeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Enter Vault PIN'),
          automaticallyImplyLeading: false,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock, size: 48),
              const SizedBox(height: 16),
              Text(
                '$_remaining attempt${_remaining == 1 ? "" : "s"} remaining',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color:      _remaining <= 3 ? Colors.red : null,
                  fontWeight: _remaining <= 3 ? FontWeight.bold : null,
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller:      _pinCtrl,
                obscureText:     true,
                keyboardType:    TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                enabled:         !_cooldown && !_loading,
                autofocus:       true,
                decoration: InputDecoration(
                  labelText: 'Vault PIN',
                  border:    const OutlineInputBorder(),
                  errorText: _error,
                ),
                onSubmitted: (_) => _verifyPin(),
              ),
              if (_cooldown) ...[
                const SizedBox(height: 12),
                const Text(
                  'Too many attempts. Wait 30 seconds.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.orange),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: (_loading || _cooldown) ? null : _verifyPin,
                child: _loading
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── VaultWipeScreen ───────────────────────────────────────────────────────────

class VaultWipeScreen extends StatefulWidget {
  const VaultWipeScreen({super.key});

  @override
  State<VaultWipeScreen> createState() => _VaultWipeScreenState();
}

class _VaultWipeScreenState extends State<VaultWipeScreen> {
  @override
  void initState() {
    super.initState();
    _wipe();
  }

  Future<void> _wipe() async {
    try {
      final secure = SecureStorageService();
      await secure.deleteAll();
      await context.read<AuthService>().signOut();
    } catch (e) {
      log.e('Vault wipe error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment:  MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.no_encryption, size: 72, color: Colors.red),
              const SizedBox(height: 24),
              const Text(
                'Vault Wiped',
                textAlign:  TextAlign.center,
                style: TextStyle(
                    fontSize: 28, fontWeight: FontWeight.bold, color: Colors.red),
              ),
              const SizedBox(height: 16),
              const Text(
                'Too many incorrect PIN attempts. '
                'Your vault has been permanently deleted from this device. '
                'Encrypted data may still exist in Supabase if you had synced.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () async {
                  await context.read<AuthService>().signOut();
                },
                child: const Text('Back to Login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
