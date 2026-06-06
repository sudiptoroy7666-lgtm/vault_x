import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

// ── Logger ────────────────────────────────────────────────────────────────────
// Use this everywhere. Never use print() or debugPrint().
final log = Logger(
  printer: PrettyPrinter(methodCount: 0, noBoxingByDefault: true),
  level: Level.debug, // TODO: Change to Level.warning for production
);

// ── Exception types ───────────────────────────────────────────────────────────

/// Password length outside 15–128 chars, or other input validation failure.
class ValidationException implements Exception {
  final String message;
  const ValidationException(this.message);
  @override
  String toString() => 'ValidationException: $message';
}

/// GCM tag failure (wrong PIN or tampered data) or biometric auth failure.
class AuthenticationException implements Exception {
  final String message;
  const AuthenticationException([this.message = 'Authentication failed']);
  @override
  String toString() => 'AuthenticationException: $message';
}

/// Triggered after 10th PIN failure — vault data wiped.
class VaultWipeException implements Exception {
  const VaultWipeException();
}

/// GCM tag invalid on a stored vault entry — data may be corrupted.
class CorruptVaultException implements Exception {
  final String message;
  const CorruptVaultException([this.message = 'Vault data corrupted']);
  @override
  String toString() => 'CorruptVaultException: $message';
}

/// Argon2id OOM at all three memory tiers.
class CryptoException implements Exception {
  final String message;
  const CryptoException([this.message = 'Crypto operation failed']);
  @override
  String toString() => 'CryptoException: $message';
}

/// Network unavailable or Supabase offline.
class NetworkException implements Exception {
  final String message;
  const NetworkException([this.message = 'Network error']);
  @override
  String toString() => 'NetworkException: $message';
}

/// Supabase write or read failure during sync.
class SyncException implements Exception {
  final String message;
  const SyncException([this.message = 'Sync failed']);
  @override
  String toString() => 'SyncException: $message';
}

/// SQLite version too old, or other storage-level failure.
class StorageException implements Exception {
  final String message;
  const StorageException(this.message);
  @override
  String toString() => 'StorageException: $message';
}

/// Certificate pin mismatch or TLS failure.
class SecurityException implements Exception {
  final String message;
  const SecurityException([this.message = 'Network security error']);
  @override
  String toString() => 'SecurityException: $message';
}

/// Supabase Auth operation failed (login, register, OTP).
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);
  @override
  String toString() => 'AuthException: $message';
}

// ── Clipboard helper ──────────────────────────────────────────────────────────

/// Copies [text] to clipboard and clears it after [seconds] seconds.
/// Clipboard clearing is best-effort — external clipboard managers on Windows
/// may retain history outside VaultX control. Inform users of this limitation.
class ClipboardHelper {
  static Timer? _timer;

  static void copyWithTimeout(String text, {int seconds = 30}) {
    Clipboard.setData(ClipboardData(text: text));
    _timer?.cancel();
    _timer = Timer(Duration(seconds: seconds), () {
      Clipboard.setData(const ClipboardData(text: ''));
    });
  }

  static void clear() {
    _timer?.cancel();
    Clipboard.setData(const ClipboardData(text: ''));
  }

  static void cancelTimer() {
    _timer?.cancel();
  }
}

// ── Hex helpers ───────────────────────────────────────────────────────────────

String bytesToHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List hexToBytes(String hex) {
  if (hex.length % 2 != 0) throw const FormatException('Odd-length hex string');
  final bytes = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}
