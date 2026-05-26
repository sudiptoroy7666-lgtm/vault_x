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

  // Session key lives in RAM only. Zeroed on lock/logout.
  Uint8List? _sessionKey;
  bool _isLoggedIn = false;
  bool _vaultUnlocked = false;
  User? _user;

  AuthService() {
    // Restore existing Supabase session if one exists (e.g. app restart).
    // Vault remains locked — user must still enter master password.
    final existing = _supabase.auth.currentSession;
    if (existing != null && existing.user != null) {
      _user = existing.user;
      _isLoggedIn = true;
      // vaultUnlocked stays false — router will redirect to /unlock.
    }

    // Listen for future auth state changes (token refresh, sign-out etc.).
    _supabase.auth.onAuthStateChange.listen((data) {
      final event = data.event;

      if (event == AuthChangeEvent.signedIn) {
        final newUser      = data.session?.user;
        final newLoggedIn  = newUser != null;
        // Token refreshes also fire signedIn — only notify if state actually changed.
        if (newLoggedIn != _isLoggedIn || newUser?.id != _user?.id) {
          _user      = newUser;
          _isLoggedIn = newLoggedIn;
          notifyListeners();
        }
      } else if (event == AuthChangeEvent.signedOut ||
          (event == AuthChangeEvent.tokenRefreshed && data.session == null)) {
        _isLoggedIn = false;
        _user       = null;
        notifyListeners();
      } else if (event == AuthChangeEvent.tokenRefreshed && data.session != null) {
        // Silent update — no navigation change, do NOT notify GoRouter.
        _user = data.session?.user;
      }
    });
  }

  bool get isLoggedIn => _isLoggedIn;

  bool get vaultUnlocked => _vaultUnlocked;

  User? get user => _user;

  /// Returns the active session key.
  /// Throws [AuthenticationException] if vault is not unlocked.
  Uint8List get sessionKey {
    if (_sessionKey == null) {
      throw const AuthenticationException('Vault is locked.');
    }
    return _sessionKey!;
  }

  // ── Registration ────────────────────────────────────────────────────────────

  /// Registers a new user with Supabase Auth.
  /// Does NOT set master password or PIN — those are set in setup screens.
  Future<bool> register(String email, String password) async {
    try {
      final res = await _supabase.auth.signUp(
        email: email,
        password: password,
      );

      if (res.user == null) {
        throw const AuthException(
          'Registration failed. Check your email and password.',
        );
      }

      // ❗ Email verification required
      if (res.session == null) {
        // DO NOT log user in
        _user = res.user;
        _isLoggedIn = false;
        notifyListeners();

        return false;
      }

      // ✅ Auto-login case (no email verification required)
      _user = res.user;
      _isLoggedIn = true;
      notifyListeners();

      return true;
    } on AuthException {
      rethrow;
    } catch (e) {
      final msg = e.toString();

      if (msg.contains('User already registered') ||
          msg.contains('already been registered')) {
        throw const AuthException(
          'An account with this email already exists. Please sign in.',
        );
      }

      throw AuthException('Registration error: $msg');
    }
  }


  // ── Login ───────────────────────────────────────────────────────────────────

  /// Signs in with email and password.
  /// If email OTP is enabled, caller must follow up with [verifyEmailOtp].
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

  /// Requests a 6-digit OTP sent to the user's email via Supabase.
  Future<void> requestEmailOtp(String email) async {
    await _supabase.auth.signInWithOtp(email: email);
  }

  /// Verifies the 6-digit email OTP.
  /// Throws [AuthException] on failure.
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

  /// Derives and stores the master password salt.
  /// Called once during initial setup. Salt stored in Supabase user metadata.
  Future<void> setupMasterPassword(String masterPassword) async {
    final salt = CryptoService.generateSalt();

    // Derive master key — runs in Isolate.
    final masterKey = await CryptoService.deriveKey(masterPassword, salt);

    // Derive session key from master key.
    final sessionId = _user!.id;
    final newSessionKey = await CryptoService.deriveSessionKey(
        masterKey, sessionId);

    // Zero master key immediately — it must not linger in RAM.
    CryptoService.zeroMemory(masterKey);

    // Store salt in Supabase user metadata (not in device Keychain).
    await _supabase.auth.updateUser(
      UserAttributes(
        data: {'master_salt': base64Encode(salt)},
      ),
    );

    // Store session key in RAM.
    _sessionKey = newSessionKey;
    _vaultUnlocked = true;
    notifyListeners();
  }

  // ── Master password unlock ──────────────────────────────────────────────────

  /// Unlocks the vault with the master password.
  /// Derives session key and stores it in RAM.
  Future<void> unlockWithMasterPassword(String masterPassword) async {
    final saltBase64 = _user?.userMetadata?['master_salt'] as String?;
    if (saltBase64 == null) {
      throw const AuthException('Master salt not found. Please re-register.');
    }
    final salt = base64Decode(saltBase64);

    // Derive master key in Isolate.
    final masterKey = await CryptoService.deriveKey(masterPassword, salt);

    // Derive session key.
    final sessionId = _user!.id;
    final newSessionKey = await CryptoService.deriveSessionKey(
        masterKey, sessionId);

    // Zero master key immediately.
    CryptoService.zeroMemory(masterKey);

    _sessionKey = newSessionKey;
    _vaultUnlocked = true;
    notifyListeners();
  }

  // ── Vault PIN setup ─────────────────────────────────────────────────────────

  /// Sets up the vault PIN. Called once after master password setup.
  /// PIN is immutable after this — no change path, no reset path.
  Future<void> setupVaultPin(String pin) async {
    if (pin.length < 6) {
      throw const ValidationException('PIN must be at least 6 digits.');
    }

    // Salt for PIN hash verification.
    final pinSalt = CryptoService.generateSalt();
    // Salt for deriving vault_key (used during reveals).
    final vaultKeySalt = CryptoService.generateSalt();

    // Derive PIN hash for verification.
    final pinHash = await CryptoService.derivePinKey(pin, pinSalt);

    // Store everything in hardware-backed secure storage.
    await _secure.write(SecureKeys.pinHash, base64Encode(pinHash));
    await _secure.write(SecureKeys.pinSalt, base64Encode(pinSalt));
    await _secure.write(SecureKeys.vaultKeySalt, base64Encode(vaultKeySalt));
    await _secure.write(SecureKeys.pinFailCount, '0');

    // Zero PIN hash after storing.
    CryptoService.zeroMemory(pinHash);
  }

  // ── Biometric unlock ────────────────────────────────────────────────────────

  /// Attempts biometric authentication.
  /// Returns true on success, false if unavailable or failed.
  /// Only called on Android and Windows — never on other platforms.
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

  /// Locks the vault — zeros session key in RAM.
  void lock() {
    if (_sessionKey != null) {
      CryptoService.zeroMemory(_sessionKey!);
      _sessionKey = null;
    }
    _vaultUnlocked = false;
    ClipboardHelper.clear();
    notifyListeners();
  }

  // ── Logout ──────────────────────────────────────────────────────────────────

  /// Full logout: zeros session key, clears secure storage, signs out Supabase.
  Future<void> signOut() async {
    lock(); // zeros session key and clears clipboard

    // Clear all hardware-backed storage.
    await _secure.deleteAll();

    // Supabase signOut also revokes the refresh token server-side.
    await _supabase.auth.signOut();

    _isLoggedIn = false;
    _user = null;
    notifyListeners();
  }

  // ── Device ID ───────────────────────────────────────────────────────────────

  /// Returns a stable device identifier for sync conflict resolution.
  /// Platform-specific — never call a platform API without a guard.
  static Future<String> getDeviceId() async {
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        return info.id; // Android hardware ID
      } else if (Platform.isWindows) {
        final info = await plugin.windowsInfo;
        return info.deviceId; // Windows machine GUID
      }
    } catch (e) {
      log.w('Could not get device ID: $e');
    }
    // Fallback: use user ID as device identifier.
    return Supabase.instance.client.auth.currentUser?.id ?? 'unknown';
  }

  // ── PIN vault setup check ────────────────────────────────────────────────────

  /// Returns true if the vault PIN has been set up.
  Future<bool> isPinSetup() async {
    final hash = await _secure.read(SecureKeys.pinHash);
    return hash != null;
  }

  /// Returns true if the master password has been set up.
  Future<bool> isMasterSetup() async {
    final user = Supabase.instance.client.auth.currentUser;
    final salt = user?.userMetadata?['master_salt'];
    return salt != null;
  }
}
