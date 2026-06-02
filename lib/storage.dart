import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqlite3/sqlite3.dart';

import 'models.dart';
import 'utils.dart';

part 'storage.g.dart';

// ── Drift Table Definition ────────────────────────────────────────────────────

class VaultEntries extends Table {
  // Non-sensitive metadata (plaintext)
  TextColumn get id => text()();
  BoolColumn get isFavourite => boolean().withDefault(const Constant(false))();
  BoolColumn get isBreached => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get modifiedAt => dateTime()();
  TextColumn get deviceId => text()();
  BoolColumn get syncPending => boolean().withDefault(const Constant(true))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  // Encrypted fields — nonce + cipher pair per sensitive field
  BlobColumn get siteNameNonce => blob()();
  BlobColumn get siteNameCipher => blob()();
  BlobColumn get siteUrlNonce => blob()();
  BlobColumn get siteUrlCipher => blob()();
  BlobColumn get usernameNonce => blob()();
  BlobColumn get usernameCipher => blob()();
  BlobColumn get passwordNonce => blob()();
  BlobColumn get passwordCipher => blob()();
  BlobColumn get notesNonce => blob()();
  BlobColumn get notesCipher => blob()();
  BlobColumn get categoryNonce => blob()();
  BlobColumn get categoryCipher => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

// ── Database ──────────────────────────────────────────────────────────────────

@DriftDatabase(tables: [VaultEntries])
class AppDatabase extends _$AppDatabase {
  // Singleton — one connection for the entire app lifetime.
  static AppDatabase? _instance;

  factory AppDatabase() {
    _instance ??= AppDatabase._internal();
    return _instance!;
  }

  AppDatabase._internal() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'vaultx');
  }

// ... rest of the class unchanged


  // ── SQLite version check ────────────────────────────────────────────────────

  /// Verifies bundled SQLite is >= 3.50.2 (CVE-2025-6965).
  /// Throws [StorageException] if the version is too old.
  /// Call this from main() before opening the vault.
  static void verifySqliteVersion() {
    // sqlite3.version is the correct API — it returns the library version,
    // not the schema version. versionNumber is an int like 3050200.
    final version = sqlite3.version;
    // 3.50.2 = 3 * 1000000 + 50 * 1000 + 2 = 3050002
    const minimumVersion = 3050002;
    if (version.versionNumber < minimumVersion) {
      throw StorageException(
        'Please update the app to fix a security issue. '
        'SQLite ${version.sourceId} is below the required version 3.50.2.',
      );
    }
  }

  // ── CRUD ───────────────────────────────────────────────────────────────────

  /// Returns all non-deleted entries.
  Future<List<EncryptedEntry>> getAllEntries() async {
    final rows = await (select(vaultEntries)
          ..where((t) => t.deleted.equals(false)))
        .get();
    return rows.map(_rowToModel).toList();
  }

  /// Returns a single entry by [id], or null if not found / deleted.
  Future<EncryptedEntry?> getEntry(String id) async {
    final row = await (select(vaultEntries)
          ..where((t) => t.id.equals(id) & t.deleted.equals(false)))
        .getSingleOrNull();
    return row == null ? null : _rowToModel(row);
  }
// ✅ ADD THIS METHOD RIGHT HERE
  /// Returns a single entry by [id], including soft-deleted entries (used by sync engine).
  Future<EncryptedEntry?> getEntryIncludingDeleted(String id) async {
    final row = await (select(vaultEntries)
      ..where((t) => t.id.equals(id))) // Notice: no .deleted.equals(false) filter
        .getSingleOrNull();
    return row == null ? null : _rowToModel(row);
  }
  /// Inserts a new entry. Throws if id already exists.
  Future<void> insertEntry(EncryptedEntry entry) async {
    await into(vaultEntries).insert(_modelToCompanion(entry));
  }

  /// Updates an existing entry. Returns true if a row was updated.
  Future<bool> updateEntry(EncryptedEntry entry) async {
    return update(vaultEntries).replace(_modelToCompanion(entry));
  }

  /// Soft-deletes an entry (sets deleted = true, syncPending = true).
  Future<void> softDeleteEntry(String id) async {
    await (update(vaultEntries)..where((t) => t.id.equals(id))).write(
      const VaultEntriesCompanion(
        deleted: Value(true),
        syncPending: Value(true),
      ),
    );
  }

  /// Returns entries with syncPending = true (for upload queue).
  Future<List<EncryptedEntry>> getPendingEntries() async {
    final rows = await (select(vaultEntries)
          ..where((t) => t.syncPending.equals(true)))
        .get();
    return rows.map(_rowToModel).toList();
  }

  /// Marks an entry as synced (syncPending = false).
  Future<void> markSynced(String id) async {
    await (update(vaultEntries)..where((t) => t.id.equals(id))).write(
      const VaultEntriesCompanion(syncPending: Value(false)),
    );
  }

  /// Hard-deletes everything. Called during vault wipe.
  Future<void> wipeAll() async {
    await delete(vaultEntries).go();
  }

  // ── Mapping helpers ─────────────────────────────────────────────────────────

  EncryptedEntry _rowToModel(VaultEntry row) {
    return EncryptedEntry(
      id: row.id,
      siteNameNonce: row.siteNameNonce,
      siteNameCipher: row.siteNameCipher,
      siteUrlNonce: row.siteUrlNonce,
      siteUrlCipher: row.siteUrlCipher,
      usernameNonce: row.usernameNonce,
      usernameCipher: row.usernameCipher,
      passwordNonce: row.passwordNonce,
      passwordCipher: row.passwordCipher,
      notesNonce: row.notesNonce,
      notesCipher: row.notesCipher,
      categoryNonce: row.categoryNonce,
      categoryCipher: row.categoryCipher,
      isFavourite: row.isFavourite,
      isBreached: row.isBreached,
      createdAt: row.createdAt,
      modifiedAt: row.modifiedAt,
      deviceId: row.deviceId,
      syncPending: row.syncPending,
      deleted: row.deleted, // ✅ MAKE SURE THIS IS HERE
    );
  }

  VaultEntriesCompanion _modelToCompanion(EncryptedEntry e) {
    return VaultEntriesCompanion(
      id: Value(e.id),
      siteNameNonce: Value(e.siteNameNonce),
      siteNameCipher: Value(e.siteNameCipher),
      siteUrlNonce: Value(e.siteUrlNonce),
      siteUrlCipher: Value(e.siteUrlCipher),
      usernameNonce: Value(e.usernameNonce),
      usernameCipher: Value(e.usernameCipher),
      passwordNonce: Value(e.passwordNonce),
      passwordCipher: Value(e.passwordCipher),
      notesNonce: Value(e.notesNonce),
      notesCipher: Value(e.notesCipher),
      categoryNonce: Value(e.categoryNonce),
      categoryCipher: Value(e.categoryCipher),
      isFavourite: Value(e.isFavourite),
      isBreached: Value(e.isBreached),
      createdAt: Value(e.createdAt),
      modifiedAt: Value(e.modifiedAt),
      deviceId: Value(e.deviceId),
      syncPending: Value(e.syncPending),
      deleted: Value(e.deleted), // ✅ FIX: Use model's flag instead of hardcoded false
    );
  }
}

// ── SecureStorageService ──────────────────────────────────────────────────────

/// Hardware-backed secure key storage.
/// Android -> StrongBox HSM (with Keystore fallback).
/// Windows -> Windows Credential Manager (+ TPM 2.0 where available).
class SecureStorageService {
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: false,
    ),
    wOptions: WindowsOptions(),
  );

  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  Future<String?> read(String key) async {
    return _storage.read(key: key);
  }

  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }

  /// Clears all secure storage. Called during vault wipe and logout.
  Future<void> deleteAll() async {
    await _storage.deleteAll();
  }
}

// ── Key names for SecureStorageService ───────────────────────────────────────
// Use these constants everywhere — never hardcode key strings.

class SecureKeys {
  static const String pinHash = 'vaultx_pin_hash';
  static const String pinSalt = 'vaultx_pin_salt';
  static const String vaultKeySalt = 'vaultx_vault_key_salt';
  static const String pinFailCount = 'vaultx_pin_fail_count';
  static const String masterSalt = 'vaultx_master_salt';
  static const String sessionKey = 'vaultx_session_key';
  static const String lastSyncTime = 'vaultx_last_sync_time';
  static const String emailOtpEnabled = 'vaultx_otp_enabled';
}
