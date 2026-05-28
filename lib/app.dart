import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'screens/verify_email.dart';      // ✅ ADD THIS
import 'auth.dart';
import 'screens/add_edit_entry.dart';
import 'screens/login.dart';
import 'screens/pin_gate.dart';
import 'screens/register.dart';
import 'screens/reveal.dart';
import 'screens/settings.dart';
import 'screens/setup_master.dart';
import 'screens/setup_pin.dart';
import 'screens/unlock.dart';
import 'screens/vault_list.dart';
import 'screens/forgot_password.dart';   // ✅ ADD THIS
// ── Router ────────────────────────────────────────────────────────────────────

GoRouter buildRouter(AuthService auth) {
  return GoRouter(
      initialLocation: '/login',
      refreshListenable: auth,
      redirect: (context, state) {
        final loggedIn      = auth.isLoggedIn;
        final vaultUnlocked = auth.vaultUnlocked;
        final path          = state.matchedLocation;

        final isLogin         = path == '/login';
        final isRegister      = path == '/register';
        final isForgotPw      = path == '/forgot-password';
        final isVerifyEmail   = path.startsWith('/verify-email');

        // ✅ UPDATED: Allow verify-email and forgot-password for unauthenticated users
        final isPublic        = isLogin || isRegister || isForgotPw || isVerifyEmail;

        // 1️⃣ Not logged in → allow public routes (login & register), block everything else
        if (!loggedIn) {
          return isPublic ? null : '/login'; // ✅ FIXED
        }

        // 2️⃣ Logged in → always allow setup routes
        if (path == '/setup-master' || path == '/setup-pin') {
          return null;
        }

        // 3️⃣ Logged in but vault locked → check if setup is done first
        if (!vaultUnlocked) {
          final masterSetup =
              auth.user?.userMetadata?['master_salt'] != null;

          if (!masterSetup) {
            // First-time user — master password not set up yet
            return path == '/setup-master' ? null : '/setup-master';
          }

          // Returning user — master password exists but vault is locked
          return path == '/unlock' ? null : '/unlock';
        }

        // 4️⃣ Logged in + vault unlocked → send public routes to vault
        if (isPublic) {
          return '/vault';
        }

        return null;
      },
  // ... your routes remain exactly the same ...
    routes: [
      GoRoute(path: '/login',        builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register',     builder: (_, __) => const RegisterScreen()),
      GoRoute(
        path: '/verify-email',
        builder: (_, state) => VerifyEmailScreen(
          email: state.uri.queryParameters['email'] ?? '',
        ),
      ),
      GoRoute(path: '/forgot-password', builder: (_, __) => const ForgotPasswordScreen()),
      GoRoute(path: '/unlock',       builder: (_, __) => const UnlockScreen()),
      GoRoute(path: '/setup-master', builder: (_, __) => const SetupMasterScreen()),
      GoRoute(path: '/setup-pin',    builder: (_, __) => const SetupPinScreen()),
      GoRoute(path: '/vault',        builder: (_, __) => const VaultListScreen()),
      GoRoute(path: '/add',          builder: (_, __) => const AddEditEntryScreen()),
      GoRoute(
        path: '/edit/:id',
        builder: (_, state) =>
            AddEditEntryScreen(entryId: state.pathParameters['id']),
      ),
      GoRoute(path: '/settings',     builder: (_, __) => const SettingsScreen()),
    ],
  );
}

// ── App ───────────────────────────────────────────────────────────────────────

// ── App ───────────────────────────────────────────────────────────────────────

// Change to StatefulWidget so the router is created ONCE, not on every rebuild.
class VaultXApp extends StatefulWidget {
  const VaultXApp({super.key});

  @override
  State<VaultXApp> createState() => _VaultXAppState();
}

class _VaultXAppState extends State<VaultXApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    // Read auth once — GoRouter's refreshListenable handles re-evaluation
    // of redirect() whenever auth notifies. No need to watch here.
    _router = buildRouter(context.read<AuthService>());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title:         'VaultX',
      debugShowCheckedModeBanner: false,
      theme:         _theme(Brightness.light),
      darkTheme:     _theme(Brightness.dark),
      themeMode:     ThemeMode.system,
      routerConfig:  _router,
    );
  }

  ThemeData _theme(Brightness brightness) {
    const primary = Color(0xFF1E3A5F);
    return ThemeData(
      useMaterial3:    true,
      brightness:      brightness,
      colorSchemeSeed: primary,
      fontFamily:      'Roboto',
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(),
      ),
    );
  }
}
