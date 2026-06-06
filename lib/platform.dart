import 'dart:io';

import 'package:flutter/widgets.dart';
export 'package:flutter/widgets.dart' show AppLifecycleState;

import 'package:flutter/services.dart';
import 'package:flutter_windowmanager_plus/flutter_windowmanager_plus.dart';
import 'package:flutter_jailbreak_detection/flutter_jailbreak_detection.dart';

import 'utils.dart';

class PlatformService {
  // ── Screenshot blocking ─────────────────────────────────────────────────────

  /// Prevents screenshots and screen recording on the current screen.
  ///
  /// Android: FLAG_SECURE via flutter_windowmanager.
  /// Windows: Best-effort only — Win32 SetWindowDisplayAffinity is partial.
  /// Call on PIN gate, reveal screen, and any screen showing decrypted data.
  static Future<void> blockScreenshots() async {
    if (Platform.isAndroid) {
      try {
        await FlutterWindowManagerPlus.addFlags(FlutterWindowManagerPlus.FLAG_SECURE);
      } catch (e) {
        log.w('Screenshot block failed on Android: $e');
      }
    }
    // Windows: no reliable cross-GPU solution via Flutter.
    // Document this limitation — do not claim screenshot protection on Windows.
  }

  /// Removes screenshot prevention. Call when navigating away from secure screens.
  static Future<void> unblockScreenshots() async {
    if (Platform.isAndroid) {
      try {
        await FlutterWindowManagerPlus.clearFlags(FlutterWindowManagerPlus.FLAG_SECURE);
      } catch (e) {
        log.w('Screenshot unblock failed: $e');
      }
    }
  }

  // ── Root / jailbreak detection ──────────────────────────────────────────────

  /// Soft root detection — shows a warning to the user but does NOT block.
  ///
  /// Only called on Android. NEVER call on Windows.
  /// Returns true if root indicators are detected.
  static Future<bool> isRooted() async {
    if (!Platform.isAndroid) {
      // Explicit guard — root_detect must not be called on Windows.
      return false;
    }
    try {
      return await FlutterJailbreakDetection.jailbroken;
    } catch (e) {
      log.w('Root detection error: $e');
      return false;
    }
  }

  // ── App lifecycle auto-lock ─────────────────────────────────────────────────

  // ── App lifecycle auto-lock ─────────────────────────────────────────────────

  // ── App lifecycle auto-lock ─────────────────────────────────────────────────

  /// Returns true if the given [state] should trigger auto-lock.
  /// We ignore `paused` and `inactive` (phone calls, notification shade, app switcher)
  /// and only lock when the app is truly hidden or detached.
  static bool shouldAutoLock(AppLifecycleState state) {
    return state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
  }

  // ── Platform info ───────────────────────────────────────────────────────────

  /// Human-readable current platform name.
  static String get platformName {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isWindows) return 'Windows';
    return 'Unknown';
  }

  /// Returns true if biometric unlock is supported on this platform.
  /// Only Android and Windows are supported.
  static bool get supportsBiometrics {
    return Platform.isAndroid || Platform.isWindows;
  }
}
