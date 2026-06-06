import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'export_dialog.dart';
import 'import_screen.dart';
import '../auth.dart';
import '../platform.dart';
import '../storage.dart';
import '../utils.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _secure    = SecureStorageService();
  bool _otpEnabled = false;
  bool _loadingOtp = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final otp = await _secure.read(SecureKeys.emailOtpEnabled);
    setState(() => _otpEnabled = otp == 'true');
  }

  Future<void> _toggleOtp(bool val) async {
    setState(() => _loadingOtp = true);
    await _secure.write(SecureKeys.emailOtpEnabled, val ? 'true' : 'false');
    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(data: {'otp_enabled': val}),
      );
    } catch (e) {
      log.w('Could not update OTP preference: $e');
    }
    setState(() {
      _otpEnabled  = val;
      _loadingOtp  = false;
    });
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text(
            'Your vault data stays encrypted on this device and in the cloud.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sign Out')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<AuthService>().signOut();
      if (mounted) context.go('/login');
    }
  }

  Future<void> _deepClean() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Deep Clean (Wipe All Local Data)'),
        content: const Text(
            'This will permanently delete your local SQLite database, '
                'wipe your PIN from the OS Credential Manager/Keystore, and log you out. '
                'Your encrypted data in Supabase will remain intact.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange),
              child: const Text('Wipe Everything')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final secure = SecureStorageService();
    await secure.deleteAll(); // ✅ Wipes OS Credential Manager / Keystore

    final db = AppDatabase();
    await db.wipeAll(); // ✅ Wipes SQLite DB

    await context.read<AuthService>().signOut(); // ✅ Wipes Supabase session
    if (mounted) context.go('/login');
  }
  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ Delete Account & All Data'),
        content: const Text(
            'This will PERMANENTLY delete all your encrypted passwords from the Supabase server, '
                'wipe your Master Password salt, and delete your local data.\n\n'
                'This action CANNOT be undone. You will need to register again to use VaultX.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade900),
              child: const Text('Delete Everything')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _loadingOtp = true); // Reuse loading state or add a new one

    try {
      final auth = context.read<AuthService>();
      final userId = auth.user!.id;
      final supabase = Supabase.instance.client;

      // 1. Delete all entries from the server
      await supabase.from('vault_entries').delete().eq('user_id', userId);

      // 2. Wipe Master Salt and PIN backups from server metadata
      await supabase.auth.updateUser(
        UserAttributes(
          data: {
            'master_salt': null,
            'enc_pin_salt_nonce': null,
            'enc_pin_salt_cipher': null,
            'enc_vault_key_salt_nonce': null,
            'enc_vault_key_salt_cipher': null,
            'enc_pin_hash_nonce': null,
            'enc_pin_hash_cipher': null,
          },
        ),
      );

      // 3. Wipe local device data
      final secure = SecureStorageService();
      await secure.deleteAll();

      final db = AppDatabase();
      await db.wipeAll();

      // 4. Sign out
      await auth.signOut();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account data permanently deleted.'), backgroundColor: Colors.red),
        );
        context.go('/login');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete account: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingOtp = false);
    }
  }
  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize:       11,
            fontWeight:     FontWeight.bold,
            color:          Theme.of(context).colorScheme.primary,
            letterSpacing:  1.2,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [

          // ── Account ──────────────────────────────────────────────────
          _sectionHeader('Account'),
          ListTile(
            leading:  const Icon(Icons.email_outlined),
            title:    const Text('Email'),
            subtitle: Text(auth.user?.email ?? '—'),
          ),

          // ── Security ─────────────────────────────────────────────────
          _sectionHeader('Security'),

          if (PlatformService.supportsBiometrics)
            const ListTile(
              leading:  Icon(Icons.fingerprint),
              title:    Text('Biometric unlock'),
              subtitle: Text(
                  'Use fingerprint or Windows Hello to confirm identity'),
              trailing: Icon(Icons.check_circle, color: Colors.green),
            ),

          _loadingOtp
              ? const ListTile(
                  leading:  Icon(Icons.email),
                  title:    Text('Email OTP 2FA'),
                  trailing: SizedBox(
                      width:  24,
                      height: 24,
                      child:  CircularProgressIndicator(strokeWidth: 2)),
                )
              : SwitchListTile(
                  secondary: const Icon(Icons.email),
                  title:     const Text('Email OTP 2FA'),
                  subtitle:  const Text(
                      'Send a 6-digit code to your email on every login'),
                  value:     _otpEnabled,
                  onChanged: _toggleOtp,
                ),

          const ListTile(
            leading:  Icon(Icons.lock_clock),
            title:    Text('Auto-lock'),
            subtitle: Text('Vault locks when app goes to background'),
            trailing: Text('Always on',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),

          const ListTile(
            leading:  Icon(Icons.content_paste_off),
            title:    Text('Clipboard clear'),
            subtitle: Text('Copied passwords cleared after 30 seconds'),
            trailing: Text('30 s',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
          // ── Data ─────────────────────────────────────────────────
          _sectionHeader('Data'),

          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Export Vault'),
            subtitle: const Text('Backup your passwords to a file'),
            onTap: () => ExportDialog.show(context),
          ),

          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Import Vault'),
            subtitle: const Text('Restore from backup or import CSV'),
            onTap: () => context.push('/import'),
          ),
          // ── Platform ─────────────────────────────────────────────────
          _sectionHeader('Platform'),
          ListTile(
            leading: const Icon(Icons.devices),
            title:   const Text('Current platform'),
            trailing: Text(
              PlatformService.platformName,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          if (PlatformService.platformName == 'Windows')
            const ListTile(
              leading:  Icon(Icons.screenshot_monitor),
              title:    Text('Screenshot protection'),
              subtitle: Text(
                  'Partial on Windows — external capture tools may '
                  'bypass this limitation.'),
              trailing: Icon(Icons.warning_amber_rounded,
                  color: Colors.orange),
            ),

          // ── About ────────────────────────────────────────────────────
          _sectionHeader('About'),
          const ListTile(
            leading:  Icon(Icons.info_outline),
            title:    Text('VaultX'),
            subtitle: Text('v1.0.0 — Zero-Knowledge Password Manager'),
          ),
          const ListTile(
            leading:  Icon(Icons.security),
            title:    Text('Security model'),
            subtitle: Text(
                'AES-256-GCM per-field encryption. Argon2id KDF. '
                'Zero-knowledge: Supabase never receives plaintext.'),
          ),
          const ListTile(
            leading:  Icon(Icons.warning_amber_rounded),
            title:    Text('No recovery path'),
            subtitle: Text(
                'Loss of Master Password = permanent data loss by design. '
                'Keep a secure offline backup of your Master Password.'),
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.deepOrange),
            title: const Text('Deep Clean (Wipe All Local Data)',
                style: TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.bold)),
            subtitle: const Text('Deletes SQLite DB, Secure Storage, and logs out.'),
            onTap: _deepClean,
          ),
          const SizedBox(height: 24),
          ListTile(
            leading: const Icon(Icons.person_remove, color: Colors.red),
            title: const Text('Delete Account & Server Data',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            subtitle: const Text('Permanently wipes all data from Supabase and this device.'),
            onTap: _deleteAccount,
          ),
          ListTile(
            leading:  const Icon(Icons.logout, color: Colors.red),
            title:    const Text('Sign Out',
                style: TextStyle(color: Colors.red)),
            onTap:    _confirmSignOut,
          ),

          const SizedBox(height: 24),
        ],

      ),
    );
  }
}
