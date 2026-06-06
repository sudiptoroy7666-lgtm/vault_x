import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide StorageException;

import 'app.dart';
import 'auth.dart';
import 'storage.dart';
import 'utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 1. SQLite version check ───────────────────────────────────────────────
  // Must happen before anything touches the database.
  // Throws StorageException if SQLite < 3.50.2 (CVE-2025-6965).
  try {
    AppDatabase.verifySqliteVersion();
  } on StorageException catch (e) {
    runApp(_ErrorApp(message: e.message));
    return;
  }

  // ── 2. Load .env (runtime fallback) ──────────────────────────────────────
  // --dart-define values take priority; .env is the fallback for local dev.
  await dotenv.load(fileName: '.env');

  // ── 3. Supabase init ──────────────────────────────────────────────────────
  const buildUrl     = String.fromEnvironment('SUPABASE_URL');
  const buildAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  final supabaseUrl     = buildUrl.isNotEmpty
      ? buildUrl
      : dotenv.get('SUPABASE_URL', fallback: '');
  final supabaseAnonKey = buildAnonKey.isNotEmpty
      ? buildAnonKey
      : dotenv.get('SUPABASE_ANON_KEY', fallback: '');

  log.i('Supabase URL: $supabaseUrl');
  log.i('Supabase key length: ${supabaseAnonKey.length}');

  if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
    runApp(const _ErrorApp(
      message:
          'Supabase credentials not configured.\n\n'
          'Add SUPABASE_URL and SUPABASE_ANON_KEY to your .env file\n'
          'or pass them via --dart-define.',
    ));
    return;
  }

  await Supabase.initialize(
    url:     supabaseUrl,
    anonKey: supabaseAnonKey,
    // ✅ ADD THIS: Forces Supabase to send tokens in the URL instead of PKCE codes
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.implicit,
    ),
  );


  // ── 3. Run app ────────────────────────────────────────────────────────────
  runApp(
    ChangeNotifierProvider(
      create: (_) => AuthService(),
      child: const VaultXApp(),
    ),
  );
}

// ── Error app ─────────────────────────────────────────────────────────────────
// Shown when a fatal startup error occurs (bad SQLite version, missing config).

class _ErrorApp extends StatelessWidget {
  final String message;
  const _ErrorApp({required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 24),
                const Text(
                  'VaultX could not start',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
