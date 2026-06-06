import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';
import 'storage.dart';
import 'utils.dart';

class SyncService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final AppDatabase _db;
  final SecureStorageService _secure;
  final String userId;

  SyncService({
    required AppDatabase db,
    required SecureStorageService secure,
    required this.userId,
  })  : _db = db,
        _secure = secure;

  // ── Sync on login ───────────────────────────────────────────────────────────

  /// Downloads remote changes and merges them locally using last-write-wins.
  /// Also uploads any locally pending entries.
  Future<void> syncOnLogin() async {
    final connected = await _isConnected();
    if (!connected) {
      log.i('Sync skipped — offline');
      return;
    }

    try {
      await _downloadRemoteChanges();
      await _uploadPendingEntries();
      await _secure.write(
        SecureKeys.lastSyncTime,
        DateTime.now().toIso8601String(),
      );
    } catch (e) {
      log.w('Sync error: $e');
      // Do not rethrow — sync failure is non-fatal. App works offline.
    }
  }

  // ── Download remote changes ─────────────────────────────────────────────────

  Future<void> _downloadRemoteChanges() async {
    final lastSyncStr = await _secure.read(SecureKeys.lastSyncTime);
    // If no last sync, fetch everything from the beginning.
    final lastSync = lastSyncStr != null
        ? DateTime.parse(lastSyncStr)
        : DateTime(2000);

    final response = await _supabase
        .from('vault_entries')
        .select()
        .eq('user_id', userId)
        .gte('modified_at', lastSync.toIso8601String())
        .order('modified_at');

    for (final row in response as List<dynamic>) {
      await _mergeRow(row as Map<String, dynamic>);
    }
  }

  Future<void> _mergeRow(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final remoteModifiedAt = DateTime.parse(row['modified_at'] as String);
    final isDeleted = row['deleted'] as bool? ?? false;

    final local = await _db.getEntryIncludingDeleted(id);

    if (isDeleted) {
      if (local != null && !local.deleted) {
        await _db.softDeleteEntry(id);
      }
      return;
    }

    if (local == null) {
      await _db.insertEntry(_rowToModel(row));
    } else if (remoteModifiedAt.isAfter(local.modifiedAt)) {
      // ✅ FIX: Only overwrite if remote is STRICTLY newer.
      // If timestamps are equal, trust the local SQLite entry.
      await _db.updateEntry(_rowToModel(row));
    }
  }

  // ── Upload pending entries ──────────────────────────────────────────────────

  Future<void> _uploadPendingEntries() async {
    final pending = await _db.getPendingEntries();
    for (final entry in pending) {
      try {
        await uploadEntry(entry);
        await _db.markSynced(entry.id);
      } catch (e) {
        log.w('Failed to upload entry ${entry.id}: $e');
        // Leave syncPending = true — will retry on next sync.
      }
    }
  }

  // ── Upload single entry ─────────────────────────────────────────────────────

  /// Uploads a single [EncryptedEntry] to Supabase.
  /// All sensitive fields are hex-encoded blobs — Supabase never sees plaintext.
  Future<void> uploadEntry(EncryptedEntry entry) async {
    try {
      await _supabase.from('vault_entries').upsert({
        'id': entry.id,
        'user_id': userId,
        'site_name_nonce': bytesToHex(entry.siteNameNonce),
        'site_name_cipher': bytesToHex(entry.siteNameCipher),
        'site_url_nonce': bytesToHex(entry.siteUrlNonce),
        'site_url_cipher': bytesToHex(entry.siteUrlCipher),
        'username_nonce': bytesToHex(entry.usernameNonce),
        'username_cipher': bytesToHex(entry.usernameCipher),
        'password_nonce': bytesToHex(entry.passwordNonce),
        'password_cipher': bytesToHex(entry.passwordCipher),
        'notes_nonce': bytesToHex(entry.notesNonce),
        'notes_cipher': bytesToHex(entry.notesCipher),
        'category_nonce': bytesToHex(entry.categoryNonce),
        'category_cipher': bytesToHex(entry.categoryCipher),
        'is_favourite': entry.isFavourite,
        'is_breached': entry.isBreached,
        'created_at': entry.createdAt.toIso8601String(),
        'modified_at': entry.modifiedAt.toIso8601String(),
        'device_id': entry.deviceId,
        'deleted': entry.deleted, // ✅ FIXED: Use the model's actual deleted flag
      });
    } catch (e) {
      throw SyncException('Upload failed for ${entry.id}: $e');
    }
  }

  /// Marks an entry as deleted in Supabase.
  Future<void> uploadDelete(String entryId) async {
    final connected = await _isConnected();
    if (!connected) return; // Will be picked up on next sync via syncPending.

    try {
      await _supabase
          .from('vault_entries')
          .update({
            'deleted': true,
            'modified_at': DateTime.now().toIso8601String(),
          })
          .eq('id', entryId)
          .eq('user_id', userId);
    } catch (e) {
      log.w('Failed to upload delete for $entryId: $e');
    }
  }

  // ── Connectivity check ──────────────────────────────────────────────────────

  Future<bool> _isConnected() async {
    final results = await Connectivity().checkConnectivity();
    return results.isNotEmpty && !results.contains(ConnectivityResult.none);
  }

  // ── Row → Model conversion ──────────────────────────────────────────────────

  EncryptedEntry _rowToModel(Map<String, dynamic> row) {
    return EncryptedEntry(
      id: row['id'] as String,
      siteNameNonce: hexToBytes(row['site_name_nonce'] as String),
      siteNameCipher: hexToBytes(row['site_name_cipher'] as String),
      siteUrlNonce: hexToBytes(row['site_url_nonce'] as String),
      siteUrlCipher: hexToBytes(row['site_url_cipher'] as String),
      usernameNonce: hexToBytes(row['username_nonce'] as String),
      usernameCipher: hexToBytes(row['username_cipher'] as String),
      passwordNonce: hexToBytes(row['password_nonce'] as String),
      passwordCipher: hexToBytes(row['password_cipher'] as String),
      notesNonce: hexToBytes(row['notes_nonce'] as String),
      notesCipher: hexToBytes(row['notes_cipher'] as String),
      categoryNonce: hexToBytes(row['category_nonce'] as String),
      categoryCipher: hexToBytes(row['category_cipher'] as String),
      isFavourite: row['is_favourite'] as bool? ?? false,
      isBreached: row['is_breached'] as bool? ?? false,
      createdAt: DateTime.parse(row['created_at'] as String),
      modifiedAt: DateTime.parse(row['modified_at'] as String),
      deviceId: row['device_id'] as String? ?? '',
      syncPending: false,
    );
  }
}
