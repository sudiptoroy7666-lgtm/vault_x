import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;

import 'crypto.dart';
import 'storage.dart';
import 'utils.dart';

class AuthService extends ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;
  final SecureStorageService _secure = SecureStorageService();
  final LocalAuthentication _localAuth = LocalAuthentication();
  static const String _redirectUrl = 'https://sudiptoroy7666-lgtm.github.io/vaultx-auth/';

  // Session key lives in RAM only. Zeroed on lock/logout.
  Uint8List? _sessionKey;
  bool _isLoggedIn = false;
  bool _vaultUnlocked = false;
  User? _user;
  bool _needsPinSetup = false;

  bool get isLoggedIn => _isLoggedIn;
  bool get vaultUnlocked => _vaultUnlocked;
  User? get user => _user;
  bool get needsPinSetup => _needsPinSetup;

  /// Returns the active session key.
  Uint8List get sessionKey {
    if (_sessionKey == null) {
      throw const AuthenticationException('Vault is locked.');
    }
    return _sessionKey!;
  }

  AuthService() {
    final existing = _supabase.auth.currentSession;
    if (existing != null && existing.user != null) {
      _user = existing.user;
      _isLoggedIn = true;
    }

    _supabase.auth.onAuthStateChange.listen((data) {
      final event = data.event;
      if (event == AuthChangeEvent.signedIn) {
        final newUser = data.session?.user;
        final newLoggedIn = newUser != null;
        if (newLoggedIn != _isLoggedIn || newUser?.id != _user?.id) {
          _user = newUser;
          _isLoggedIn = newLoggedIn;
          notifyListeners();
        }
      } else if (event == AuthChangeEvent.signedOut ||
          (event == AuthChangeEvent.tokenRefreshed && data.session == null)) {
        _isLoggedIn = false;
        _user = null;
        notifyListeners();
      } else if (event == AuthChangeEvent.tokenRefreshed && data.session != null) {
        _user = data.session?.user;
      }
    });
  }

  // ── Registration ────────────────────────────────────────────────────────────

  Future<bool> register(String email, String password) async {
    try {
      final res = await _supabase.auth.signUp(
        email: email,
        password: password,
        emailRedirectTo: _redirectUrl,
      );

      if (res.user == null) {
        throw const AuthException('Registration failed. Check your email and password.');
      }

      if (res.session == null) {
        _user = res.user;
        _isLoggedIn = false;
        notifyListeners();
        return false;
      }

      _user = res.user;
      _isLoggedIn = true;
      notifyListeners();
      return true;
    } on AuthException {
      rethrow;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('User already registered') || msg.contains('already been registered')) {
        throw const AuthException('An account with this email already exists. Please sign in.');
      }
      throw AuthException('Registration error: $msg');
    }
  }

  // ── Login ───────────────────────────────────────────────────────────────────

  Future<void> login(String email, String password) async {
    try {
      final res = await _supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (res.session == null || res.user == null) {
        throw const AuthException('Invalid email or password.');
      }

      await _supabase.auth.refreshSession();
      _user = _supabase.auth.currentUser;
      _isLoggedIn = true;
      notifyListeners();
    } catch (e) {
      throw AuthException('Login failed: $e');
    }
  }

  // ── Email OTP 2FA ───────────────────────────────────────────────────────────

  Future<void> requestEmailOtp(String email) async {
    await _supabase.auth.signInWithOtp(email: email);
  }

  Future<void> verifyEmailOtp(String email, String token) async {
    final res = await _supabase.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.email,
    );
    if (res.user == null) {
      throw const AuthException('Invalid or expired verification code.');
    }
    _user = res.user;
    _isLoggedIn = true;
    notifyListeners();
  }

  // ── Master password setup ───────────────────────────────────────────────────

  Future<void> setupMasterPassword(String masterPassword) async {
    final salt = CryptoService.generateSalt();
    final masterKey = await CryptoService.deriveKey(masterPassword, salt);
    final sessionId = _user!.id;
    final newSessionKey = await CryptoService.deriveSessionKey(masterKey, sessionId);
    CryptoService.zeroMemory(masterKey);

    await _supabase.auth.updateUser(
      UserAttributes(data: {'master_salt': base64Encode(salt)}),
    );

    _sessionKey = newSessionKey;
    _vaultUnlocked = true;
    notifyListeners();
  }

  // ── Master password unlock ──────────────────────────────────────────────────

  // ── Master password unlock ──────────────────────────────────────────────────

  Future<void> unlockWithMasterPassword(String masterPassword) async {
    User? freshUser;

    // 1. Try to get a fresh user from the network
    try {
      final res = await _supabase.auth.refreshSession();
      freshUser = res.session?.user;
    } catch (e) {
      // 2. ✅ FIX: If offline or network fails, fall back to the locally cached user
      log.w('Network refresh failed (offline?), falling back to cached user: $e');
      freshUser = _supabase.auth.currentUser;
    }

    if (freshUser == null) {
      throw const AuthException('Session expired. Please connect to the internet and login again.');
    }

    _user = freshUser;
    final meta = freshUser.userMetadata ?? {};

    final saltBase64 = meta['master_salt'] as String?;
    if (saltBase64 == null) {
      throw const AuthException('Master salt not found locally. Please connect to the internet and try again.');
    }
    final salt = base64Decode(saltBase64);

    final masterKey = await CryptoService.deriveKey(masterPassword, salt);
    final sessionId = freshUser.id;
    final newSessionKey = await CryptoService.deriveSessionKey(masterKey, sessionId);
    CryptoService.zeroMemory(masterKey);

    _sessionKey = newSessionKey;
    _vaultUnlocked = true;

    // ✅ THE "BOTH" ARCHITECTURE: Check if local PIN data exists. If wiped, restore from Supabase cache.
    final localVaultSalt = await _secure.read(SecureKeys.vaultKeySalt);

    if (localVaultSalt == null && meta['enc_vault_key_salt_cipher'] != null) {
      try {
        // Decrypt PIN data using the newly derived sessionKey
        final pinSalt = await CryptoService.decrypt(
            base64Decode(meta['enc_pin_salt_cipher'] as String),
            base64Decode(meta['enc_pin_salt_nonce'] as String),
            newSessionKey);

        final vaultKeySalt = await CryptoService.decrypt(
            base64Decode(meta['enc_vault_key_salt_cipher'] as String),
            base64Decode(meta['enc_vault_key_salt_nonce'] as String),
            newSessionKey);

        final pinHash = await CryptoService.decrypt(
            base64Decode(meta['enc_pin_hash_cipher'] as String),
            base64Decode(meta['enc_pin_hash_nonce'] as String),
            newSessionKey);

        // Restore to local hardware-backed storage
        await _secure.write(SecureKeys.pinSalt, base64Encode(pinSalt));
        await _secure.write(SecureKeys.vaultKeySalt, base64Encode(vaultKeySalt));
        await _secure.write(SecureKeys.pinHash, base64Encode(pinHash));
        await _secure.write(SecureKeys.pinFailCount, '0');

        CryptoService.zeroMemory(pinSalt);
        CryptoService.zeroMemory(vaultKeySalt);
        CryptoService.zeroMemory(pinHash);

        _needsPinSetup = false;
      } catch (e) {
        log.w('Failed to restore PIN data from cache: $e');
        _needsPinSetup = true;
      }
    } else {
      _needsPinSetup = (localVaultSalt == null);
    }

    notifyListeners();
  }
  // ── Vault PIN setup ─────────────────────────────────────────────────────────

  Future<void> setupVaultPin(String pin) async {
    if (pin.length < 6) {
      throw const ValidationException('PIN must be at least 6 digits.');
    }

    final pinSalt = CryptoService.generateSalt();
    final vaultKeySalt = CryptoService.generateSalt();
    final pinHash = await CryptoService.derivePinKey(pin, pinSalt);

    // 1. Store locally in hardware-backed storage
    await _secure.write(SecureKeys.pinHash, base64Encode(pinHash));
    await _secure.write(SecureKeys.pinSalt, base64Encode(pinSalt));
    await _secure.write(SecureKeys.vaultKeySalt, base64Encode(vaultKeySalt));
    await _secure.write(SecureKeys.pinFailCount, '0');

    // 2. ✅ THE "BOTH" ARCHITECTURE: Encrypt PIN data with sessionKey and sync to Supabase
    // This allows restoring the PIN on a new device or after a Deep Clean
    if (_sessionKey != null) {
      try {
        final encPinSalt = await CryptoService.encrypt(pinSalt, _sessionKey!);
        final encVaultKeySalt = await CryptoService.encrypt(vaultKeySalt, _sessionKey!);
        final encPinHash = await CryptoService.encrypt(pinHash, _sessionKey!);

        await _supabase.auth.updateUser(
          UserAttributes(
            data: {
              'enc_pin_salt_nonce': base64Encode(encPinSalt.nonce),
              'enc_pin_salt_cipher': base64Encode(encPinSalt.ciphertext),
              'enc_vault_key_salt_nonce': base64Encode(encVaultKeySalt.nonce),
              'enc_vault_key_salt_cipher': base64Encode(encVaultKeySalt.ciphertext),
              'enc_pin_hash_nonce': base64Encode(encPinHash.nonce),
              'enc_pin_hash_cipher': base64Encode(encPinHash.ciphertext),
            },
          ),
        );
      } catch (e) {
        log.w('Failed to backup PIN data to Supabase: $e');
        // Non-fatal: local PIN still works, just won't restore on other devices
      }
    }

    CryptoService.zeroMemory(pinHash);
    CryptoService.zeroMemory(pinSalt);
    CryptoService.zeroMemory(vaultKeySalt);

    _needsPinSetup = false;
    notifyListeners();
  }

  // ── Biometric unlock ────────────────────────────────────────────────────────

  Future<bool> authenticateBiometric() async {
    if (!Platform.isAndroid && !Platform.isWindows) return false;
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      if (!canCheck || !isSupported) return false;
      return await _localAuth.authenticate(
        localizedReason: 'Authenticate to unlock VaultX',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (e) {
      log.w('Biometric auth error: $e');
      return false;
    }
  }

  // ── Lock ────────────────────────────────────────────────────────────────────

  void lock() {
    if (_sessionKey != null) {
      CryptoService.zeroMemory(_sessionKey!);
      _sessionKey = null;
    }
    _vaultUnlocked = false;
    notifyListeners();
  }

  // ── Logout ──────────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    lock();
    await _secure.delete(SecureKeys.lastSyncTime);
    await _supabase.auth.signOut();
    _isLoggedIn = false;
    _user = null;
    notifyListeners();
  }

  // ── Email Verification ─────────────────────────────────────────────────────

  Future<void> resendVerificationEmail(String email) async {
    try {
      await _supabase.auth.resend(
        type: OtpType.signup,
        email: email,
        emailRedirectTo: _redirectUrl,
      );
    } catch (e) {
      log.w('Resend verification failed: $e');
      throw AuthException('Could not resend email. Please try again later.');
    }
  }

  // ── Password Reset ─────────────────────────────────────────────────────────

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _supabase.auth.resetPasswordForEmail(email, redirectTo: _redirectUrl);
    } catch (e) {
      log.w('Password reset request failed: $e');
      throw AuthException('Could not send reset email. Check the address and try again.');
    }
  }

  // ── Device ID ───────────────────────────────────────────────────────────────

  static Future<String> getDeviceId() async {
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        return info.id;
      } else if (Platform.isWindows) {
        final info = await plugin.windowsInfo;
        return info.deviceId;
      }
    } catch (e) {
      log.w('Could not get device ID: $e');
    }
    return Supabase.instance.client.auth.currentUser?.id ?? 'unknown';
  }

  // ── PIN vault setup check ────────────────────────────────────────────────────

  Future<bool> isPinSetup() async {
    final hash = await _secure.read(SecureKeys.pinHash);
    return hash != null;
  }

  Future<bool> isMasterSetup() async {
    final user = Supabase.instance.client.auth.currentUser;
    final salt = user?.userMetadata?['master_salt'];
    return salt != null;
  }
}