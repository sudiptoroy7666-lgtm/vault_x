import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// Alias to avoid naming conflict with local 'sha1' variable.
import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:http/http.dart' as http;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:zxcvbn/zxcvbn.dart';

import 'utils.dart';

class PasswordGenerator {
  // Seeded FortunaRandom — separate instance from CryptoService.
  static final FortunaRandom _rng = _buildRng();

  static int _nextInt(int max) {
    return _rng.nextUint32() % max;
  }

  static FortunaRandom _buildRng() {
    final src  = Random.secure();
    final seed = Uint8List(32);
    for (int i = 0; i < 32; i++) seed[i] = src.nextInt(256);
    return FortunaRandom()..seed(KeyParameter(seed));
  }

  // Ambiguous chars removed (0/O, l/1/I).
  static const _upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  static const _lower   = 'abcdefghjkmnpqrstuvwxyz';
  static const _digits  = '23456789';
  static const _symbols = r'!@#$%^&*()_+-=[]{}|;:,.<>?';

  // Last 10 generated passwords — session memory only, never persisted.
  static final List<String> _history = [];
  static List<String> get history => List.unmodifiable(_history);

  // ── Generation ──────────────────────────────────────────────────────────

  static String generate({
    required int length,
    required int minScore,
    int minPerClass = 2,
  }) {
    final charset = _upper + _lower + _digits + _symbols;
    String password;
    int attempts = 0;

    do {
      if (attempts++ > 200) {
        throw const CryptoException(
            'Password generation failed after 200 attempts.');
      }

      final chars = List<String>.generate(
          length, (_) => charset[_nextInt(charset.length)]);

      // ✅ FIX: Manual Fisher-Yates shuffle using FortunaRandom
      final positions = List<int>.generate(length, (i) => i);
      for (int i = positions.length - 1; i > 0; i--) {
        final j = _nextInt(i + 1);
        final temp = positions[i];
        positions[i] = positions[j];
        positions[j] = temp;
      }

      int pos = 0;
      for (int i = 0; i < minPerClass; i++) {
        chars[positions[pos++]] = _upper[_nextInt(_upper.length)];
        chars[positions[pos++]] = _lower[_nextInt(_lower.length)];
        chars[positions[pos++]] = _digits[_nextInt(_digits.length)];
        chars[positions[pos++]] = _symbols[_nextInt(_symbols.length)];
      }

      password = chars.join();
    } while ((Zxcvbn().evaluate(password).score ?? 0) < minScore);

    _history.insert(0, password);
    if (_history.length > 10) _history.removeLast();
    return password;
  }

  static String generateStrong()     => generate(length: 15, minScore: 2, minPerClass: 2);
  static String generateVeryStrong() => generate(length: 20, minScore: 3, minPerClass: 2);
  static String generateMaximum()    => generate(length: 24, minScore: 4, minPerClass: 3);

  // ── HIBP breach check ────────────────────────────────────────────────────

  /// Checks password against HaveIBeenPwned using k-anonymous SHA-1 prefix.
  /// Sends only the first 5 hex chars — never the full hash.
  static Future<bool> checkBreach(String password) async {
    // Use aliased package to avoid naming conflict.
    final digest  = crypto_pkg.sha1.convert(utf8.encode(password));
    final fullHex = digest.toString().toUpperCase();
    final prefix  = fullHex.substring(0, 5);
    final suffix  = fullHex.substring(5);

    try {
      final response = await http
          .get(Uri.parse('https://api.pwnedpasswords.com/range/$prefix'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw NetworkException('HIBP returned ${response.statusCode}');
      }

      return response.body
          .split('\n')
          .any((line) => line.trim().startsWith(suffix));
    } on NetworkException {
      rethrow;
    } catch (e) {
      throw NetworkException('HIBP check failed: $e');
    }
  }

  // ── Strength scoring ─────────────────────────────────────────────────────

  static ({int score, String label}) scorePassword(String password) {
    if (password.isEmpty) return (score: 0, label: '');
    final score = (Zxcvbn().evaluate(password).score ?? 0).toInt();
    const labels = ['Very Weak', 'Weak', 'Fair', 'Strong', 'Very Strong'];
    return (score: score, label: labels[score]);
  }
}
