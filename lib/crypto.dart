import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cry;
import 'package:ffi/ffi.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/random/fortuna_random.dart';

import 'utils.dart';

class EncryptedData {
  final Uint8List nonce;
  final Uint8List ciphertext;
  const EncryptedData(this.nonce, this.ciphertext);
}

class _ArgonArgs {
  final List<int> inputBytes;
  final List<int> salt;
  final int       memKb;
  const _ArgonArgs(this.inputBytes, this.salt, this.memKb);
}

class CryptoService {
  static final _aesGcm = cry.AesGcm.with256bits();
  static FortunaRandom? _rng;

  static FortunaRandom get _fortuna {
    if (_rng == null) {
      final src  = Random.secure();
      final seed = Uint8List(32);
      for (int i = 0; i < 32; i++) seed[i] = src.nextInt(256);
      _rng = FortunaRandom()..seed(KeyParameter(seed));
    }
    return _rng!;
  }

  static Uint8List generateNonce() => _fortuna.nextBytes(12);
  static Uint8List generateSalt() => _fortuna.nextBytes(16);

  static Future<Uint8List> deriveKey(String password, Uint8List salt) async {
    if (password.length < 15) throw const ValidationException('Password must be at least 15 characters.');
    if (password.length > 128) throw const ValidationException('Password must be at most 128 characters.');
    return _runArgon2id(utf8.encode(password), salt);
  }

  static Future<Uint8List> derivePinKey(String pin, Uint8List salt) async {
    return _runArgon2id(utf8.encode(pin), salt);
  }

  static Future<Uint8List> _runArgon2id(List<int> inputBytes, Uint8List salt) async {
    final maxKb = await _memoryTierKb();
    final tiers = _buildTiers(maxKb);
    Exception? lastErr;
    for (final kb in tiers) {
      try {
        final args = _ArgonArgs(inputBytes, salt.toList(), kb);
        return await Isolate.run(() => _argonIsolate(args));
      } catch (e) {
        lastErr = e is Exception ? e : Exception(e.toString());
      }
    }
    throw CryptoException('Insufficient device memory for key derivation. ($lastErr)');
  }

  static Future<Uint8List> _argonIsolate(_ArgonArgs args) async {
    final algo = cry.Argon2id(parallelism: 4, memory: args.memKb, iterations: 3, hashLength: 32);
    final derived = await algo.deriveKey(
      secretKey: cry.SecretKey(args.inputBytes),
      nonce:     Uint8List.fromList(args.salt),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  static List<int> _buildTiers(int maxKb) {
    final all = [65536, 49152, 32768];
    final filtered = all.where((k) => k <= maxKb).toList();
    if (!filtered.contains(32768)) filtered.add(32768);
    return filtered;
  }

  static Future<int> _memoryTierKb() async {

    return 32768;
  }

  static Future<Uint8List> deriveSessionKey(Uint8List masterKey, String sessionId) async {
    final hkdf = cry.Hkdf(hmac: cry.Hmac.sha256(), outputLength: 32);
    final sk   = await hkdf.deriveKey(
      secretKey: cry.SecretKey(masterKey),
      info:      Uint8List.fromList(utf8.encode('vaultx-session-v1')),
      nonce:     Uint8List.fromList(utf8.encode(sessionId)),
    );
    return Uint8List.fromList(await sk.extractBytes());
  }

  // ── BULLETPROOF AES-256-GCM ──────────────────────────────────────────────────

  static Future<EncryptedData> encrypt(Uint8List plaintext, Uint8List key) async {
    assert(key.length == 32, 'AES-256 requires 32-byte key, got ${key.length}');

    final keyCopy = Uint8List.fromList(key);
    final nonce = generateNonce();
    final secretKey = cry.SecretKeyData(keyCopy);

    try {
      final box = await _aesGcm.encrypt(
        plaintext,
        secretKey: secretKey,
        nonce:     nonce,
      );

      // ✅ THE CRITICAL FIX: Only concatenate cipherText + MAC.
      // DO NOT use box.concatenation() because it includes the nonce!
      final ciphertextWithMac = Uint8List.fromList([
        ...box.cipherText,
        ...box.mac.bytes
      ]);

      return EncryptedData(nonce, ciphertextWithMac);
    } finally {
      secretKey.destroy();
      zeroMemory(keyCopy);
    }
  }

  static Future<Uint8List> decrypt(Uint8List ciphertext, Uint8List nonce, Uint8List key) async {
    assert(key.length == 32, 'AES-256 requires 32-byte key, got ${key.length}');
    if (nonce.length != 12) throw const CorruptVaultException('Invalid nonce length.');
    if (ciphertext.length < 16) throw const CorruptVaultException('Ciphertext too short.');

    final keyCopy = Uint8List.fromList(key);
    final secretKey = cry.SecretKeyData(keyCopy);

    try {
      const macLen = 16;
      final body   = ciphertext.sublist(0, ciphertext.length - macLen);
      final mac    = cry.Mac(ciphertext.sublist(ciphertext.length - macLen));
      final box    = cry.SecretBox(body, nonce: nonce, mac: mac);

      final result = await _aesGcm.decrypt(box, secretKey: secretKey);
      return Uint8List.fromList(result);
    } on cry.SecretBoxAuthenticationError {
      throw const AuthenticationException('GCM authentication tag verification failed.');
    } catch (e) {
      throw CorruptVaultException('Decryption error: $e');
    } finally {
      secretKey.destroy();
      zeroMemory(keyCopy);
    }
  }

  static bool constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
    return diff == 0;
  }

  static void zeroMemory(Uint8List buffer) {
    if (buffer.isEmpty) return;
    final ptr = calloc<Uint8>(buffer.length);
    try {
      for (int i = 0; i < buffer.length; i++) buffer[i] = ptr[i];
    } finally {
      calloc.free(ptr);
    }
  }
}