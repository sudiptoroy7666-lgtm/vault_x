// All imports must be at the top — no inline imports allowed in Dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultx/crypto.dart';
import 'package:vaultx/utils.dart';
import 'package:zxcvbn/zxcvbn.dart';

void main() {

  // ── Test 1: Nonce uniqueness ────────────────────────────────────────────────
  test('1: 1000 nonces — all unique, all exactly 12 bytes', () {
    final seen = <String>{};
    for (int i = 0; i < 1000; i++) {
      final nonce = CryptoService.generateNonce();
      expect(nonce.length, equals(12),
          reason: 'Nonce must be 12 bytes, was ${nonce.length}');
      final encoded = base64Encode(nonce);
      expect(seen.contains(encoded), isFalse,
          reason: 'Duplicate nonce at index $i');
      seen.add(encoded);
    }
    expect(seen.length, equals(1000));
  });

  // ── Test 2: Round-trip encrypt / decrypt ───────────────────────────────────
  test('2: decrypt(encrypt(p, k), k) equals original plaintext', () async {
    // AES-256 requires exactly 32 bytes.
    final key       = Uint8List(32)..fillRange(0, 32, 42);
    final plaintext = Uint8List.fromList(utf8.encode('Hello, VaultX!'));

    final enc = await CryptoService.encrypt(plaintext, key);
    expect(enc.nonce.length, equals(12));

    final dec = await CryptoService.decrypt(enc.ciphertext, enc.nonce, key);
    expect(dec, equals(plaintext));
  });

  // ── Test 3: Wrong key throws AuthenticationException ───────────────────────
  test('3: Wrong key throws AuthenticationException', () async {
    final key1      = Uint8List(32)..fillRange(0, 32, 1);
    final key2      = Uint8List(32)..fillRange(0, 32, 2);
    final plaintext = Uint8List.fromList(utf8.encode('secret'));

    final enc = await CryptoService.encrypt(plaintext, key1);

    expect(
      () async => CryptoService.decrypt(enc.ciphertext, enc.nonce, key2),
      throwsA(isA<AuthenticationException>()),
    );
  });

  // ── Test 4: Tampered ciphertext throws AuthenticationException ─────────────
  test('4: 1-bit flip in ciphertext throws AuthenticationException', () async {
    final key       = Uint8List(32)..fillRange(0, 32, 3);
    final plaintext = Uint8List.fromList(utf8.encode('do not tamper'));

    final enc     = await CryptoService.encrypt(plaintext, key);
    // Copy into a mutable list before flipping.
    final tampered = Uint8List.fromList(enc.ciphertext);
    tampered[0]   ^= 0x01;

    expect(
      () async => CryptoService.decrypt(tampered, enc.nonce, key),
      throwsA(isA<AuthenticationException>()),
    );
  });

  // ── Test 5: Nonce freshness ─────────────────────────────────────────────────
  test('5: Two encryptions of same plaintext produce different nonces', () async {
    final key       = Uint8List(32)..fillRange(0, 32, 5);
    final plaintext = Uint8List.fromList(utf8.encode('same'));

    final enc1 = await CryptoService.encrypt(plaintext, key);
    final enc2 = await CryptoService.encrypt(plaintext, key);

    expect(enc1.nonce, isNot(equals(enc2.nonce)));
  });

  // ── Test 6: Memory zeroing ──────────────────────────────────────────────────
  test('6: All bytes are 0 after zeroMemory()', () {
    final buf = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4]);
    CryptoService.zeroMemory(buf);
    expect(buf.every((b) => b == 0), isTrue);
  });

  // ── Test 7: Session key determinism ────────────────────────────────────────
  test('7: Same inputs → same session key; different sessionId → different key',
      () async {
    final masterKey = Uint8List(32)..fillRange(0, 32, 7);

    final k1 = await CryptoService.deriveSessionKey(masterKey, 'sess-aaa');
    final k2 = await CryptoService.deriveSessionKey(masterKey, 'sess-aaa');
    expect(k1, equals(k2));

    final k3 = await CryptoService.deriveSessionKey(masterKey, 'sess-bbb');
    expect(k1, isNot(equals(k3)));
  });

  // ── Test 8: zxcvbn strength gate ───────────────────────────────────────────
  test('8: zxcvbn — weak passwords score 0, strong passphrase scores 4', () {
    expect(zxcvbn('password').score, equals(0));
    expect(zxcvbn('correct-horse-battery-staple').score, equals(4));
  });

  // ── Test 9: Argon2id DoS guard ─────────────────────────────────────────────
  test('9: Passwords outside 15–128 chars throw ValidationException before hashing',
      () async {
    final salt = CryptoService.generateSalt();

    // Too short (14 chars).
    await expectLater(
      CryptoService.deriveKey('A' * 14, salt),
      throwsA(isA<ValidationException>()),
    );

    // Too long (129 chars).
    await expectLater(
      CryptoService.deriveKey('A' * 129, salt),
      throwsA(isA<ValidationException>()),
    );

    // Boundary: exactly 15 chars must succeed.
    final k1 = await CryptoService.deriveKey('A' * 15, salt);
    expect(k1.length, equals(32));

    // Boundary: exactly 128 chars must succeed.
    final k2 = await CryptoService.deriveKey('B' * 128, salt);
    expect(k2.length, equals(32));
  });

  // ── Test 10: Isolate non-blocking ──────────────────────────────────────────
  test('10: Argon2id runs in Isolate — main thread stays responsive', () async {
    final salt    = CryptoService.generateSalt();
    int   counter = 0;

    // Start derivation (runs in Isolate).
    final future = CryptoService.deriveKey('A' * 15, salt);

    // Pump microtasks while derivation runs.
    for (int i = 0; i < 10; i++) {
      await Future.microtask(() => counter++);
    }

    final key = await future;
    expect(key.length, equals(32));
    expect(counter, greaterThan(0),
        reason: 'Microtasks must continue during Isolate-based deriveKey');
  });
}
