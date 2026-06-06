import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../auth.dart';
import '../platform.dart';
import '../utils.dart';

/// Shown after Supabase login to derive the session key from the master password.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen>
    with WidgetsBindingObserver {
  final _ctrl    = TextEditingController();
  bool _loading  = false;
  bool _obscure  = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // ✅ ADD THIS: Block screenshots/recording while Master Password is visible
    PlatformService.blockScreenshots();
    WidgetsBinding.instance.addObserver(this);
    _tryBiometric();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.dispose();
    // ✅ ADD THIS: Unblock when leaving the screen
    PlatformService.unblockScreenshots();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (PlatformService.shouldAutoLock(state)) {
      context.read<AuthService>().lock();
    }
  }

  Future<void> _tryBiometric() async {
    if (!PlatformService.supportsBiometrics) return;
    final auth = context.read<AuthService>();
    final ok   = await auth.authenticateBiometric();
    if (ok && mounted) {
      // Biometric verified — check if session key is cached in secure storage.
      // In v1.0 biometric simply confirms identity; user still enters master
      // password once per session. In v2.0 we cache the session key.
      // Nothing to do here — user proceeds to master password entry.
    }
  }

  Future<void> _unlock() async {
    if (_ctrl.text.isEmpty) return;
    setState(() { _loading = true; _error = null; });
    try {
      await context.read<AuthService>().unlockWithMasterPassword(_ctrl.text);
      if (mounted) context.go('/vault');
    } on ValidationException catch (e) {
      setState(() => _error = e.message);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Unlock failed. Check your master password.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              const Icon(Icons.lock, size: 64),
              const SizedBox(height: 16),
              Text(
                'Unlock Vault',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                context.read<AuthService>().user?.email ?? '',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 40),
              TextFormField(
                controller: _ctrl,
                obscureText: _obscure,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Master Password',
                  prefixIcon: const Icon(Icons.key),
                  border: const OutlineInputBorder(),
                  errorText: _error,
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onFieldSubmitted: (_) => _unlock(),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _loading ? null : _unlock,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Unlock'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () async {
                  await context.read<AuthService>().signOut();
                  if (mounted) context.go('/login');
                },
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
