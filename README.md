# VaultX 🔐

> **Zero-Knowledge Password Manager for Android & Windows**
> *Your passwords. Your keys. Your device. Nobody else — not even us — can read them.*

[![Platform](https://img.shields.io/badge/platform-Android%20|%20Windows-1E3A5F)]()
[![Flutter](https://img.shields.io/badge/Flutter-3.11+-02569B?logo=flutter)]()
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Security](https://img.shields.io/badge/Encryption-AES--256--GCM-green)]()
[![KDF](https://img.shields.io/badge/KDF-Argon2id-green)]()
[![Backend](https://img.shields.io/badge/Backend-Supabase%20RLS-3ECF8E?logo=supabase)]()

---

## 📖 Table of Contents

1. [Overview](#-overview)
2. [Core Features](#-core-features)
3. [Security Architecture](#-security-architecture)
4. [Cryptographic Flow](#-cryptographic-flow)
5. [Data Model](#-data-model)
6. [Platform Feature Matrix](#-platform-feature-matrix)
7. [Project Structure](#-project-structure)
8. [Tech Stack](#-tech-stack)
9. [Getting Started](#-getting-started)
10. [Supabase Setup](#-supabase-setup)
11. [Building for Release](#-building-for-release)
12. [Testing](#-testing)
13. [Security Hard Rules](#-security-hard-rules)
14. [Known Limitations](#-known-limitations)
15. [License](#-license)

---

## 🌟 Overview

**VaultX** is a fully offline-first, zero-knowledge password manager built with Flutter. Unlike traditional password managers, VaultX encrypts **every single sensitive field independently** on your device *before* any data ever touches SQLite or Supabase. The server never sees plaintext — not your passwords, not your usernames, not even your site names.

Designed for users who demand absolute control over their cryptographic keys, VaultX features seamless cross-platform sync, portable disaster recovery backups, and hardware-backed key storage.

> ⚠️ **SECURITY WARNING — BY DESIGN:** 
> **Loss of Master Password = permanent, irrecoverable data loss.** There is no reset link, no recovery key, and no support team that can decrypt your data. This is a feature, not a bug.

---

## ⚡ Core Features

### 🔒 Security-First & Zero-Knowledge
- **Per-field AES-256-GCM encryption** — every sensitive field has its own unique 12-byte `FortunaRandom` nonce.
- **Argon2id KDF** (memory-hard) running in Dart Isolates to prevent UI blocking. Standardized at 32MB memory cost across all platforms for deterministic cross-platform sync.
- **HKDF-SHA256** session key derivation.
- **Hardware-backed key storage** (Android StrongBox HSM / Windows TPM 2.0 via Credential Manager).
- **Constant-time comparison** for PIN and key verification to prevent timing attacks.
- **FFI-based memory zeroing** of keys immediately after cryptographic operations.

### 🔄 Cross-Platform Sync & "Both" PIN Architecture
- **Offline-first** architecture with local SQLite (Drift ORM).
- **Last-write-wins conflict resolution** via Supabase Postgres with soft-delete tombstones.
- **Cross-Platform PIN Sync:** Vault PIN salts are stored locally in the hardware keystore *and* encrypted with the session key and backed up to Supabase metadata. If you log into a new device or the OS wipes your keystore, the app silently restores your PIN salts using your Master Password.
- **Row Level Security (RLS)** strictly enforced on all Supabase tables.

### 🧳 Data Portability & Disaster Recovery
- **Portable Encrypted Backup (`.vltx`):** Exports your entire vault into a standalone, encrypted JSON file. Completely independent of Supabase; survives server outages and can be imported on any device.
- **Plaintext CSV Export/Import:** Standardized format for migrating to/from other password managers (Bitwarden, 1Password, KeePass).
- **Native Android 13+ SAF Integration:** Uses the native Storage Access Framework "Save As" dialog to bypass Scoped Storage restrictions without requiring invasive file permissions.
- **Deep Clean & Account Deletion:** Granular controls to wipe local device cache or permanently nuke server-side data.

### 🧠 Password Intelligence & UX
- **In-Memory Full-Text Search:** Instantly filter your vault by site name using a decrypted RAM cache (zero UI thread blocking).
- **3-tier password generator** (Strong / Very Strong / Maximum) with Fisher-Yates shuffling via `FortunaRandom`.
- **`zxcvbn` strength scoring** with visual feedback.
- **HaveIBeenPwned k-anonymous breach check** — only the first 5 SHA-1 prefix characters leave the device.

### 🛡️ Threat Mitigation
- **Screenshot & screen recording blocking** (Android `FLAG_SECURE`, best-effort on Windows).
- **Root / jailbreak detection** (soft warning on Android).
- **10-attempt PIN wipe** — vault is cryptographically destroyed after repeated failures.
- **30-second auto-clipboard clear** after copying passwords.

---

## 🏗️ Security Architecture

```mermaid
graph TD
    subgraph "📱 User Device (Trusted Zone)"
        A[User Input<br/>Master Password / PIN] --> B[Argon2id<br/>Isolate, 32MB]
        B --> C[master_key]
        C --> D[HKDF-SHA256]
        D --> E[session_key<br/>RAM only]
        C --> F[zeroMemory via FFI]
        
        E --> G[AES-256-GCM<br/>per-field encryption]
        G --> H[nonce_i + cipher_i]
    end
    
    subgraph "💾 Local Storage"
        H --> I[(SQLite / Drift<br/>encrypted blobs only)]
        K[Flutter Secure Storage] -.->|PIN hash & salts| K
    end
    
    subgraph "☁️ Supabase (Untrusted Zone)"
        H -->|hex-encoded| L[(vault_entries<br/>RLS-protected)]
        M[user_metadata] -.->|master_salt + enc_pin_salts| M
    end
    
    style A fill:#e3f2fd
    style F fill:#ffebee
    style L fill:#fff9c4
    style K fill:#e8f5e9
