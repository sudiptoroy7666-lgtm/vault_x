# 🛡️ VaultX
### Zero-Knowledge Password Manager — Android & Windows

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x-blue?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/Platform-Android%20%7C%20Windows-green" alt="Platform">
  <img src="https://img.shields.io/badge/Encryption-AES--256--GCM-blue" alt="Encryption">
  <img src="https://img.shields.io/badge/KDF-Argon2id-purple" alt="KDF">
  <img src="https://img.shields.io/badge/Backend-Supabase-3ECF8E?logo=supabase" alt="Supabase">
  <img src="https://img.shields.io/badge/License-Apache%202.0-orange" alt="License">
</p>

VaultX is a **strictly offline-first, zero-knowledge password manager** built with Flutter. Designed for users who demand absolute control over their cryptographic keys, VaultX ensures that the server (Supabase) **never sees plaintext data, never stores your Master Password, and cannot recover your vault** if you forget your credentials.

> ⚠️ **SECURITY WARNING — BY DESIGN:** Loss of Master Password = **permanent, irrecoverable data loss**. There is no reset link, no recovery key, and no support team that can decrypt your data. This is a feature, not a bug.

---

## 📑 Table of Contents
- [Platform Support](#-platform-support)
- [Core Features](#-core-features)
- [Security Architecture](#-security-architecture)
- [Cross-Platform Sync](#-cross-platform-sync-the-both-architecture)
- [Export & Import System](#-export--import-system)
- [Tech Stack](#️-tech-stack)
- [Project Structure](#-project-structure)
- [Getting Started](#-getting-started)
- [Build & Distribution](#-build--distribution)
- [Testing](#-testing)
- [Hard Rules](#️-hard-rules-for-contributors--auditors)
- [License](#-license)

---

## 📱 Platform Support

| Platform | Status | Security Features |
| :--- | :---: | :--- |
| **Android** | ✅ Fully Supported | StrongBox HSM, Biometrics, `FLAG_SECURE` screenshot blocking, Root detection |
| **Windows** | ✅ Fully Supported | TPM 2.0 / Credential Manager, Windows Hello, Partial screenshot protection |
| **iOS / macOS** | ❌ Out of Scope | Not in v7.1 specification |
| **Web / Linux** | ❌ Out of Scope | Not in v7.1 specification |

---

## ✨ Core Features

### 🔐 Two-Tier Security Model
- **Master Password** (15–128 chars): Derives the `session_key` that encrypts metadata (site name, URL, username, notes, category).
- **Vault PIN** (6+ digits): Derives the `vault_key` that encrypts the **actual passwords**. Passwords are masked in the vault list and require PIN entry to reveal.

### 🚫 Auto-Wipe Protection
10 consecutive failed Vault PIN attempts trigger a **permanent cryptographic wipe**:
- Local SQLite database is destroyed
- Hardware-backed secure storage is cleared
- User is signed out of Supabase
- A permanent "Vault Wiped" screen is shown

### 🌐 End-to-End Encrypted Sync
- **Offline-first**: All data lives in local SQLite (Drift ORM)
- **Silent Last-Write-Wins**: Background sync to Supabase on login with zero conflict UI
- **Soft Deletes**: Deleted entries are marked with tombstones to prevent offline devices from resurrecting them

### 🛡️ Breach Detection
- Integrates with **HaveIBeenPwned v3** using k-anonymous SHA-1 prefix checking
- Only the first 5 hex characters of the SHA-1 hash ever leave the device
- Breached entries are flagged with a red badge in the vault list

### 🎲 Intelligent Password Generator
Three tiers with `zxcvbn` strength validation:
| Tier | Length | Minimum Score | Rules |
| :--- | :---: | :---: | :--- |
| **Strong** | 15 chars | 2 | ≥2 chars from each class |
| **Very Strong** | 20 chars | 3 | Full charset, no ambiguous chars (0/O, l/1/I) |
| **Maximum** | 24 chars | 4 | ≥3 chars from each class |

All generation uses **FortunaRandom** (cryptographically secure) — `dart:math` is strictly banned.

### 🔍 Instant Full-Text Search
In-memory searching of decrypted site names with zero performance impact on the UI thread.

### 🧹 Deep Clean Tool
One-click factory reset that wipes local SQLite, Secure Storage, and Supabase session without destroying the cloud backup.

---

## 🔒 Security Architecture

VaultX does not use SQLCipher or full-database encryption. Instead, it employs **Application-Layer Per-Field Encryption** to ensure that even if the local SQLite file or the Supabase Postgres database is compromised, the attacker only sees isolated, useless ciphertext blobs.

### Cryptographic Primitives
| Component | Algorithm | Implementation |
| :--- | :--- | :--- |
| **KDF** | Argon2id | `argon2` package in Dart Isolate (adaptive memory: 32MB baseline) |
| **Symmetric Encryption** | AES-256-GCM | `cryptography` package, per-field with fresh 12-byte nonces |
| **Key Derivation** | HKDF-SHA256 | `cryptography` package for session keys |
| **Randomness** | FortunaRandom | `pointycastle` package — `dart:math` is banned |
| **Memory Zeroing** | FFI Arena | Deterministic overwrite via `calloc` immediately after use |
| **Hash Comparison** | Constant-Time | `constantTimeEquals()` for all PIN/key comparisons |
| **Hardware Backing** | Keystore / TPM | `flutter_secure_storage` with StrongBox on Android, Credential Manager on Windows |

### Per-Field Encryption Schema
Every sensitive field is encrypted independently with its own nonce:

```
EncryptedEntry
├── id (UUID, plaintext for indexing)
├── site_name_nonce + site_name_cipher   (AES-256-GCM with session_key)
├── site_url_nonce + site_url_cipher     (AES-256-GCM with session_key)
├── username_nonce + username_cipher     (AES-256-GCM with session_key)
├── password_nonce + password_cipher     (AES-256-GCM with vault_key) ⭐
├── notes_nonce + notes_cipher           (AES-256-GCM with session_key)
├── category_nonce + category_cipher     (AES-256-GCM with session_key)
└── Plaintext metadata: isFavourite, isBreached, createdAt, modifiedAt, deviceId, syncPending, deleted
```

### Memory Safety
- All keys (`master_key`, `session_key`, `vault_key`) are deterministically overwritten with zeros via **FFI** immediately after use
- Keys are held in RAM only during the brief window needed for cryptographic operations
- `AppLifecycleState.hidden` and `detached` trigger automatic vault locking

---

## 🔄 Cross-Platform Sync: The "Both" Architecture

VaultX uses an innovative **"Both" architecture** for Vault PIN salts that balances offline accessibility with seamless cross-device sync.

### The Challenge
- The Vault PIN salt must be stored **locally** for instant offline access
- But if the OS wipes the hardware keystore (common on Android/Windows updates), the user is locked out of all synced passwords
- Storing the salt **only** in Supabase would destroy offline accessibility

### The Solution
```
┌─────────────────────┐         ┌─────────────────────┐
│   Local Hardware    │         │   Supabase Cloud    │
│   Keystore / TPM    │         │   (Encrypted Backup)│
│                     │         │                     │
│ • pin_hash          │         │ • enc_pin_hash      │
│ • pin_salt          │◄───────►│ • enc_pin_salt      │ (encrypted with
│ • vault_key_salt    │  sync   │ • enc_vault_key_salt│  session_key)
│                     │         │                     │
└─────────────────────┘         └─────────────────────┘
```

1. **Normal Operation**: App reads salts from local hardware storage (instant, offline)
2. **OS Wipe Recovery**: If local storage is empty, app silently downloads encrypted salts from Supabase, decrypts them with the `session_key`, and restores to local hardware
3. **Zero-Knowledge**: Supabase only sees the salts **encrypted with your `session_key`** — they cannot decrypt them without your Master Password

### Argon2id Cross-Platform Unification
Both Android and Windows use a unified **32MB memory parameter** for Argon2id. This ensures that the same Master Password + salt always produces the same cryptographic key on both platforms, enabling seamless cross-device decryption.

---

## 📦 Export & Import System

### 🔐 Encrypted Backup (`.vltx` Portable Format)
A truly portable backup format that **survives Supabase outages**:

**Export Flow:**
1. User enters **Vault PIN** (to decrypt passwords into RAM)
2. User creates an **Export Password** (15+ chars)
3. All fields are decrypted and re-encrypted with the Export Password
4. Saved as a standalone JSON file with embedded Argon2id salt

**Import Flow:**
1. User selects `.vltx` file and enters **Export Password**
2. User enters current **Vault PIN** (to encrypt passwords into the new DB)
3. Entries are decrypted from the file and re-encrypted with the current account's keys
4. New UUIDs are generated and entries sync to Supabase

**Result:** The backup file is **completely independent** of the original Supabase account and can be restored on any device, even if Supabase permanently shuts down.

### 📄 Plaintext CSV Export/Import
Standard CSV format compatible with Bitwarden, 1Password, KeePass, and other password managers. Includes a strict security warning requiring user acknowledgement before export.

### 📁 Platform-Specific Save Paths
- **Android**: Uses the native Storage Access Framework (SAF) "Save As" dialog — works perfectly on Android 13+ with Scoped Storage
- **Windows**: Opens the native Windows "Save As" dialog, defaulting to the Downloads folder

---

## 🛠️ Tech Stack

| Category | Technology |
| :--- | :--- |
| **Framework** | Flutter (Dart) |
| **State Management** | `Provider` + `ChangeNotifier` |
| **Local Database** | `Drift` (SQLite ORM) + `sqlite3_flutter_libs` (≥ 3.50.2) |
| **Backend / Auth** | Supabase (Auth, Postgres, Row Level Security) |
| **Cryptography** | `cryptography`, `argon2`, `pointycastle`, `ffi` |
| **Navigation** | `go_router` (declarative routing with redirect guards) |
| **Secure Storage** | `flutter_secure_storage` (StrongBox / TPM backed) |
| **Biometrics** | `local_auth` (Fingerprint / Windows Hello) |
| **Password Strength** | `zxcvbn` |
| **HTTP Client** | `http` with manual certificate pinning for HIBP |
| **File Operations** | `file_picker` with Storage Access Framework |
| **Logging** | `logger` (no `print()` or `debugPrint()` allowed) |

---

## 📂 Project Structure

```
vault_x/
├── lib/
│   ├── main.dart                 # App entry, Supabase init, SQLite version check
│   ├── app.dart                  # MaterialApp, GoRouter, Material 3 theme
│   ├── auth.dart                 # Supabase Auth, session management, biometric unlock
│   ├── crypto.dart               # Argon2id, AES-GCM, HKDF, FortunaRandom, FFI zeroing
│   ├── models.dart               # VaultEntry (plaintext), EncryptedEntry (encrypted)
│   ├── storage.dart              # Drift schema, SecureStorageService
│   ├── sync.dart                 # Supabase CRUD, offline queue, last-write-wins
│   ├── generator.dart            # Password generator, zxcvbn, HIBP k-anon check
│   ├── export_import.dart        # .vltx and CSV export/import service
│   ├── utils.dart                # Clipboard helper, exceptions, hex utilities
│   ├── platform.dart             # Platform-specific features (screenshots, root detect)
│   └── screens/
│       ├── login.dart            # Email + password login
│       ├── register.dart         # Registration with zxcvbn scoring
│       ├── setup_master.dart     # Master password setup with no-recovery warning
│       ├── setup_pin.dart        # Vault PIN setup with immutability warning
│       ├── unlock.dart           # Master password unlock screen
│       ├── vault_list.dart       # Main vault list with search and filter
│       ├── add_edit_entry.dart   # Add/edit entry with inline generator
│       ├── pin_gate.dart         # Modal PIN prompt with attempt counter
│       ├── reveal.dart           # 30s countdown password reveal
│       ├── settings.dart         # Settings with Deep Clean tool
│       ├── export_dialog.dart    # Export format selection dialog
│       └── import_screen.dart    # Import file picker screen
├── test/
│   ├── crypto_test.dart          # 10 mandatory cryptographic tests
│   └── integration_test.dart     # Full end-to-end flow test
├── android/                      # Android native configuration
├── windows/                      # Windows native configuration
├── assets/icon/                  # App icons (1024x1024 PNG)
├── config/supabase.sql           # Database schema and RLS policies
├── installer.iss                 # Inno Setup script for Windows installer
└── pubspec.yaml                  # Dependencies and configuration
```

---

## 🚀 Getting Started

### Prerequisites
1. **Flutter SDK** (Latest Stable, 3.x)
2. **Supabase Account** with a new project
3. **Android Studio** (for Android builds)
4. **Visual Studio 2022** with C++ Desktop Development workload (for Windows builds)

### 1. Clone the Repository
```bash
git clone https://github.com/yourusername/vault_x.git
cd vault_x
```

### 2. Supabase Configuration
1. Create a new project at [supabase.com](https://supabase.com)
2. Navigate to **SQL Editor** and run the contents of `config/supabase.sql`
   - Creates `profiles` and `vault_entries` tables
   - Enables **Row Level Security (RLS)** on all tables
   - Adds owner-only policies and performance indexes
3. Go to **Authentication → URL Configuration** and add your redirect URL for email verification

### 3. Environment Variables
Create a `.env` file in the project root:

```env
SUPABASE_URL=https://your-project-ref.supabase.co
SUPABASE_ANON_KEY=your-anon-key-here
```

> ⚠️ Never commit `.env` to version control. It's already in `.gitignore`.

### 4. Install Dependencies
```bash
flutter pub get
```

### 5. Generate Drift Code
```bash
dart run build_runner build --delete-conflicting-outputs
```

### 6. Run the App
```bash
# Android
flutter run -d android

# Windows
flutter run -d windows
```

---

## 📦 Build & Distribution

### Production Builds
Both platforms **must** be built with obfuscation and split debug info to prevent reverse engineering:

**Android APK:**
```bash
flutter build apk --release --obfuscate --split-debug-info=build/debug-info
```

**Android App Bundle (Play Store):**
```bash
flutter build appbundle --release --obfuscate --split-debug-info=build/debug-info
```

**Windows:**
```bash
flutter build windows --release --obfuscate --split-debug-info=build/debug-info
```

### Windows Installer (Inno Setup)
1. Download [Inno Setup Compiler](https://jrsoftware.org/isdl.php)
2. Right-click `installer.iss` → **Compile**
3. Find `VaultX_Setup_v1.0.0.exe` in the `installer_output` folder

The installer includes:
- Native Windows installation experience
- Start Menu and Desktop shortcuts
- Clean uninstaller in "Add/Remove Programs"
- Custom app icon branding

### App Icons
Custom icons are generated using `flutter_launcher_icons`:

```bash
dart run flutter_launcher_icons
```

Configuration in `pubspec.yaml`:
- Android: Adaptive icons with `#1E3A5F` background
- Windows: 256x256 High-DPI `.ico` file

---

## 🧪 Testing

### Mandatory Cryptographic Tests
VaultX includes 10 non-negotiable cryptographic tests. **No code should be merged if these fail.**

```bash
flutter test test/crypto_test.dart
```

| # | Test | Pass Condition |
| :--- | :--- | :--- |
| 1 | Nonce uniqueness | 1000 nonces — all unique, all exactly 12 bytes |
| 2 | Round-trip | `decrypt(encrypt(p, k), k)` equals original plaintext |
| 3 | Wrong key | `AuthenticationException` thrown with different key |
| 4 | Tampered ciphertext | `AuthenticationException` after single bit flip |
| 5 | Nonce freshness | Two encryptions produce different nonces |
| 6 | Memory zero | All bytes equal 0 after `zeroMemory()` |
| 7 | Session key determinism | Same inputs → same key; different sessionId → different key |
| 8 | zxcvbn gate | 'password' scores 0, 'correct-horse-battery-staple' scores 4 |
| 9 | DoS guard | 14-char and 129-char passwords throw `ValidationException` |
| 10 | Isolate non-blocking | UI microtasks continue during `deriveKey()` |

### End-to-End Integration Tests
```bash
flutter test integration_test
```

Tests the full user flow: Register → Master Password Setup → PIN Setup → Add Entry → Sync → Lock → Relaunch → Restore.

---

## ⚠️ Hard Rules (For Contributors & Auditors)

Violating any of these rules produces a **security vulnerability** or a **broken build**.

### Cryptography
1. ❌ **NEVER** use `dart:math` `Random` — FortunaRandom only
2. ❌ **NEVER** reuse a nonce — `encrypt()` generates its own internally
3. ❌ **NEVER** use `==` for PIN or key comparison — `constantTimeEquals()` always
4. ❌ **NEVER** store plaintext for sensitive fields (passwords, usernames, URLs, notes, categories)
5. ❌ **NEVER** log secrets, keys, nonces, or PINs — use `logger` package only
6. ✅ **ALWAYS** call `zeroMemory()` via FFI on every `Uint8List` key immediately after use
7. ✅ **ALWAYS** run Argon2id in a Dart `Isolate` — never on the UI thread
8. ✅ **ALWAYS** enforce 15 ≤ password.length ≤ 128 before calling `deriveKey()`

### Platform
9. ❌ **NEVER** call `root_detect` or `flutter_windowmanager` on Windows — `Platform.isAndroid` guard required
10. ❌ **NEVER** use `share_plus` for file operations — `file_picker` only

### Storage & Sync
11. ❌ **NEVER** store master key or session key in SharedPreferences, Hive, or SQLite
12. ❌ **NEVER** add a PIN reset or Master Password recovery path — immutable by design
13. ✅ **ALWAYS** enable RLS on all Supabase tables before any user connects
14. ✅ **ALWAYS** verify SQLite ≥ 3.50.2 at startup — refuse vault open if below (CVE-2025-6965)

### Build
15. ❌ **NEVER** hardcode Supabase URL or anon key — use `--dart-define` or `.env` only
16. ❌ **NEVER** send full SHA-1 to HIBP — first 5 hex chars only
17. ❌ **NO** `print()` or `debugPrint()` anywhere — `logger` package only
18. ✅ **ALWAYS** build with `--obfuscate --split-debug-info` for releases
19. ✅ Android release: `debuggable=false`, `minifyEnabled=true`, `shrinkResources=true`

---

## 📸 Screenshots

| Login Screen | Vault List | PIN Gate | Password Generator |
| :---: | :---: | :---: | :---: |
| ![Login](assets/screenshots/login.png) | ![Vault](assets/screenshots/vault_list.png) | ![PIN](assets/screenshots/pin_gate.png) | ![Generator](assets/screenshots/generator.png) |

---

## 🤝 Contributing

Contributions are welcome, but **all PRs must**:
1. Pass all 10 cryptographic tests
2. Pass the integration test on both Android and Windows
3. Achieve `flutter analyze` with zero errors and zero warnings
4. Adhere to all Hard Rules listed above
5. Not introduce any packages from the banned list (Firebase, SQLCipher, Riverpod, BLoC, etc.)

---

## 📄 License

This project is licensed under the **Apache 2.0 License** — see the [LICENSE](LICENSE) file for details.

**Disclaimer:** The authors of VaultX are not responsible for data loss resulting from forgotten Master Passwords or lost hardware. The cryptographic design intentionally prevents anyone, including the developers, from recovering your data.

---

<p align="center">
  <strong>VaultX v7.1</strong> — May 2026<br>
  <em>Zero-Knowledge. Offline-First. Uncompromising Security.</em>
</p>
