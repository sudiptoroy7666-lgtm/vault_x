import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../crypto.dart';
import '../platform.dart';
import '../storage.dart';
import '../utils.dart';

/// Shows a decrypted password for 30 seconds, then auto-hides.
/// Screenshot blocking is active for the duration of this screen.
class RevealScreen extends StatefulWidget {
  /// The encrypted password nonce and ciphertext to reveal.
  final Uint8List passwordNonce;
  final Uint8List passwordCipher;

  /// The vault key derived from the PIN — will be zeroed immediately after use.
  final Uint8List vaultKey;

  const RevealScreen({
    super.key,
    required this.passwordNonce,
    required this.passwordCipher,
    required this.vaultKey,
  });

  @override
  State<RevealScreen> createState() => _RevealScreenState();
}

class _RevealScreenState extends State<RevealScreen> {
  String? _password;
  bool _obscure = true;
  int _secondsLeft = 30;
  Timer? _countdown;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    PlatformService.blockScreenshots();
    _decryptAndShow();
  }

  @override
  void dispose() {
    _countdown?.cancel();
    PlatformService.unblockScreenshots();

    // Cancel the timer but DO NOT force clear here.
    // Let the 30s timer handle it, or let the user paste it elsewhere.
    ClipboardHelper.cancelTimer();

    // Zero the vault key immediately — it must not linger.
    CryptoService.zeroMemory(widget.vaultKey);
    super.dispose();
  }

  Future<void> _decryptAndShow() async {
    try {
      final plainBytes = await CryptoService.decrypt(
        widget.passwordCipher,
        widget.passwordNonce,
        widget.vaultKey,
      );
      // Zero vault key as soon as decrypt is done.
      CryptoService.zeroMemory(widget.vaultKey);

      setState(() => _password = utf8.decode(plainBytes));
      _startCountdown();
    } on AuthenticationException {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Decryption failed. Incorrect PIN or corrupted data.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _startCountdown() {
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        timer.cancel();
        if (mounted) Navigator.of(context).pop();
      }
    });
  }

  void _copy() {
    if (_password == null) return;
    ClipboardHelper.copyWithTimeout(_password!, seconds: 30);
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // ✅ FIX: Use onPopInvokedWithResult to prevent premature clipboard wiping
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          ClipboardHelper.clear();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Password'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${_secondsLeft}s',
                  style: TextStyle(
                    color: _secondsLeft <= 10 ? Colors.red : null,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(28),
          child: _password == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Countdown bar
                    LinearProgressIndicator(
                      value: _secondsLeft / 30,
                      color: _secondsLeft <= 10 ? Colors.red : Colors.blue,
                      backgroundColor: Colors.grey.shade200,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Hides in $_secondsLeft second${_secondsLeft == 1 ? "" : "s"}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 32),
                    // Password field
                    GestureDetector(
                      onTap: () => setState(() => _obscure = !_obscure),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _obscure
                            ? const Center(child: Text('Tap to reveal'))
                            : SelectableText(
                                _password!,
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 18),
                              ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _copy,
                      icon: Icon(_copied ? Icons.check : Icons.copy),
                      label: Text(_copied ? 'Copied!' : 'Copy to Clipboard'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Clipboard will be cleared in 30 seconds.\n'
                      'Note: external clipboard managers may retain history.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
