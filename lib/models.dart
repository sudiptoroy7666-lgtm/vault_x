import 'dart:typed_data';

// ── VaultEntry (plaintext) ────────────────────────────────────────────────────
// Exists in RAM only during reveal. NEVER write to disk or cloud in plaintext.

class VaultEntry {
  final String id; // UUID v4
  final String siteName;
  final String siteUrl;
  final String username;
  final String password;
  final String notes;
  final String category;
  final bool isFavourite;
  final bool isBreached;
  final DateTime createdAt;
  final DateTime modifiedAt;


  const VaultEntry({
    required this.id,
    required this.siteName,
    required this.siteUrl,
    required this.username,
    required this.password,
    required this.notes,
    required this.category,
    this.isFavourite = false,
    this.isBreached = false,
    required this.createdAt,
    required this.modifiedAt,
  });

  VaultEntry copyWith({
    String? siteName,
    String? siteUrl,
    String? username,
    String? password,
    String? notes,
    String? category,
    bool? isFavourite,
    bool? isBreached,
    DateTime? modifiedAt,
  }) {
    return VaultEntry(
      id: id,
      siteName: siteName ?? this.siteName,
      siteUrl: siteUrl ?? this.siteUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      notes: notes ?? this.notes,
      category: category ?? this.category,
      isFavourite: isFavourite ?? this.isFavourite,
      isBreached: isBreached ?? this.isBreached,
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
    );
  }
}

// ── EncryptedEntry ────────────────────────────────────────────────────────────
// What gets stored in SQLite and synced to Supabase.
// Each sensitive field has its own nonce — compromise of one does not affect others.

class EncryptedEntry {
  final String id; // UUID v4 — plaintext (indexing only)

  // Sensitive fields — each independently encrypted with AES-256-GCM.
  final Uint8List siteNameNonce;
  final Uint8List siteNameCipher;
  final Uint8List siteUrlNonce;
  final Uint8List siteUrlCipher;
  final Uint8List usernameNonce;
  final Uint8List usernameCipher;
  final Uint8List passwordNonce;
  final Uint8List passwordCipher;
  final Uint8List notesNonce;
  final Uint8List notesCipher;
  final Uint8List categoryNonce;
  final Uint8List categoryCipher;
  final bool deleted; // ✅ ADD THIS
  // Non-sensitive metadata — stored plaintext.
  final bool isFavourite;
  final bool isBreached;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String deviceId;
  final bool syncPending;

  const EncryptedEntry({
    required this.id,
    required this.siteNameNonce,
    required this.siteNameCipher,
    required this.siteUrlNonce,
    required this.siteUrlCipher,
    required this.usernameNonce,
    required this.usernameCipher,
    required this.passwordNonce,
    required this.passwordCipher,
    required this.notesNonce,
    required this.notesCipher,
    required this.categoryNonce,
    required this.categoryCipher,
    required this.isFavourite,
    required this.isBreached,
    required this.createdAt,
    required this.modifiedAt,
    required this.deviceId,
    required this.syncPending,
    this.deleted = false, // ✅ ADD THIS
  });

  EncryptedEntry copyWith({bool? isBreached, bool? isFavourite, bool? syncPending,  bool? deleted}) {
    return EncryptedEntry(
      id: id,
      siteNameNonce: siteNameNonce,
      siteNameCipher: siteNameCipher,
      siteUrlNonce: siteUrlNonce,
      siteUrlCipher: siteUrlCipher,
      usernameNonce: usernameNonce,
      usernameCipher: usernameCipher,
      passwordNonce: passwordNonce,
      passwordCipher: passwordCipher,
      notesNonce: notesNonce,
      notesCipher: notesCipher,
      categoryNonce: categoryNonce,
      categoryCipher: categoryCipher,
      isFavourite: isFavourite ?? this.isFavourite,
      isBreached: isBreached ?? this.isBreached,
      createdAt: createdAt,
      modifiedAt: modifiedAt,
      deviceId: deviceId,
      syncPending: syncPending ?? this.syncPending,
      deleted: deleted ?? this.deleted, // ✅ ADD THIS

    );
  }
}
