import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../auth.dart';
import '../crypto.dart';
import '../models.dart';
import '../platform.dart';
import '../storage.dart';
import '../sync.dart';
import '../utils.dart';
import 'pin_gate.dart';
import 'reveal.dart';

class VaultListScreen extends StatefulWidget {
  const VaultListScreen({super.key});

  @override
  State<VaultListScreen> createState() => _VaultListScreenState();
}

class _VaultListScreenState extends State<VaultListScreen>
    with WidgetsBindingObserver {
  final _searchCtrl = TextEditingController();
  final _db         = AppDatabase();
  final _secure     = SecureStorageService();

  List<EncryptedEntry> _all      = [];
  List<EncryptedEntry> _filtered = [];
  // Add this field alongside _all and _filtered:
  Map<String, String> _siteNames = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAndSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Auto-lock ──────────────────────────────────────────────────────────────

  @override
  // Replace didChangeAppLifecycleState — don't manually navigate,
// GoRouter's refreshListenable handles redirect automatically after lock()
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (PlatformService.shouldAutoLock(state)) {
      context.read<AuthService>().lock();
      // No context.go here — router redirect fires automatically
    }
  }

  // ── Load & sync ────────────────────────────────────────────────────────────

  Future<void> _loadAndSync() async {
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthService>();
      final uid  = auth.user?.id;
      if (uid != null) {
        final sync = SyncService(db: _db, secure: _secure, userId: uid);
        await sync.syncOnLogin();
      }
      await _loadEntries();
    } catch (e) {
      log.w('Sync error on load: $e');
      await _loadEntries();
    }
  }

  // Replace _loadEntries:
  Future<void> _loadEntries() async {
    try {
      final entries = await _db.getAllEntries();
      if (!mounted) return;

      final sessionKey = context.read<AuthService>().sessionKey;
      final names = <String, String>{};
      for (final entry in entries) {
        try {
          final bytes = await CryptoService.decrypt(
              entry.siteNameCipher, entry.siteNameNonce, sessionKey);
          names[entry.id] = utf8.decode(bytes);
        } catch (e) {
          // ✅ ADDED LOGGING: This will tell us exactly why it's failing
          log.e('Decrypt site name failed for ${entry.id}: $e');
          names[entry.id] = 'Entry ${entry.id.substring(0, 8)}';
        }
      }

      if (!mounted) return;
      setState(() {
        _all       = entries;
        _filtered  = entries;
        _siteNames = names;
        _loading   = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      log.e('Load entries error: $e');
    }
  }

  void _onSearch(String query) {
    if (query.isEmpty) {
      setState(() => _filtered = _all);
      return;
    }

    final lowerQuery = query.toLowerCase();

    setState(() {
      _filtered = _all.where((entry) {
        // Get the already-decrypted site name from RAM
        final siteName = _siteNames[entry.id]?.toLowerCase() ?? '';

        // 1. Standard search: match against the decrypted site name
        if (siteName.contains(lowerQuery)) return true;

        // 2. Keep the legacy keyword filters just in case
        if (lowerQuery == 'breached' && entry.isBreached) return true;
        if ((lowerQuery == 'favourite' || lowerQuery == 'favorite') && entry.isFavourite) return true;

        return false;
      }).toList();
    });
  }

  // ── Reveal flow ────────────────────────────────────────────────────────────

  Future<void> _revealPassword(EncryptedEntry entry) async {
    // Single PIN entry — verified AND returned by PinGateScreen.
    final pin = await PinGateScreen.show(context);
    if (pin == null || !mounted) return;

    final saltB64 = await _secure.read(SecureKeys.vaultKeySalt);
    if (saltB64 == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vault key salt missing. Re-setup PIN.')),
        );
      }
      return;
    }

    Uint8List vaultKey;
    try {
      vaultKey = await CryptoService.derivePinKey(pin, base64Decode(saltB64));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Key derivation failed: $e')));
      }
      return;
    }

    if (!mounted) {
      CryptoService.zeroMemory(vaultKey);
      return;
    }

    // vaultKey is zeroed inside RevealScreen.dispose()
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RevealScreen(
          passwordNonce:  entry.passwordNonce,
          passwordCipher: entry.passwordCipher,
          vaultKey:       vaultKey,
        ),
      ),
    );
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

  Future<void> _deleteEntry(EncryptedEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   const Text('Delete Entry'),
        content: const Text('This will delete the entry from this device and Supabase.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _db.softDeleteEntry(entry.id);
    final uid = context.read<AuthService>().user?.id;
    if (uid != null) {
      final sync = SyncService(db: _db, secure: _secure, userId: uid);
      await sync.uploadDelete(entry.id);
    }
    await _loadEntries();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VaultX'),
        actions: [
          IconButton(
            icon:    const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
          IconButton(
            icon:    const Icon(Icons.lock_outline),
            tooltip: 'Lock vault',
            onPressed: () {
              context.read<AuthService>().lock();
              context.go('/login');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              onChanged:  _onSearch,
              decoration: const InputDecoration(
                hintText:    'Search by site name...', // ✅ UPDATED
                prefixIcon:  Icon(Icons.search),
                border:      OutlineInputBorder(),
                isDense:     true,
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.lock_outline, size: 64,
                                color: Colors.grey),
                            const SizedBox(height: 16),
                            Text(
                              _all.isEmpty
                                  ? 'No entries yet.\nTap + to add your first password.'
                                  : 'No entries match your filter.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: _filtered.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1),
              // Update the itemBuilder to pass siteName:
              itemBuilder: (_, i) => _EntryTile(
                entry:    _filtered[i],
                siteName: _siteNames[_filtered[i].id] ?? 'Entry ${_filtered[i].id.substring(0, 8)}',
                index:    i,
                onReveal: () => _revealPassword(_filtered[i]),
                onEdit:   () => context
                    .push('/edit/${_filtered[i].id}')
                    .then((_) => _loadEntries()),
                onDelete: () => _deleteEntry(_filtered[i]),
              ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            context.push('/add').then((_) => _loadEntries()),
        icon:  const Icon(Icons.add),
        label: const Text('Add entry'),
      ),
    );
  }
}

// ── Entry tile ────────────────────────────────────────────────────────────────

// Update _EntryTile to accept and show siteName:
class _EntryTile extends StatelessWidget {
  final EncryptedEntry entry;
  final String         siteName; // ← add this
  final int            index;
  final VoidCallback   onReveal;
  final VoidCallback   onEdit;
  final VoidCallback   onDelete;

  const _EntryTile({
    required this.entry,
    required this.siteName, // ← add this
    required this.index,
    required this.onReveal,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: entry.isBreached
            ? Colors.red.shade100
            : Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          siteName.isNotEmpty ? siteName[0].toUpperCase() : '?',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: entry.isBreached
                ? Colors.red
                : Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ),
      title: Row(
        children: [
          Text(siteName), // ← show real name
          if (entry.isFavourite) ...[
            const SizedBox(width: 6),
            const Icon(Icons.star, size: 14, color: Colors.amber),
          ],
        ],
      ),
      // rest unchanged...
      subtitle: entry.isBreached
          ? const Text('⚠️ Found in data breach',
              style: TextStyle(color: Colors.red, fontSize: 12))
          : Text(
              'Modified ${_formatDate(entry.modifiedAt)}',
              style: const TextStyle(fontSize: 12),
            ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'reveal') onReveal();
          if (v == 'edit')   onEdit();
          if (v == 'delete') onDelete();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'reveal', child: Text('View password')),
          PopupMenuItem(value: 'edit',   child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: onReveal,
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
