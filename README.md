VaultX 🔐
Zero-Knowledge Password Manager for Android & Windows
Your passwords. Your keys. Your device. Nobody else — not even us — can read them.











📖 Table of Contents
Overview
Core Features
Security Architecture
Cryptographic Flow
Data Model
Platform Feature Matrix
Project Structure
Tech Stack
Getting Started
Supabase Setup
Building for Release
Testing
Security Hard Rules
Known Limitations
Contributing
License
🌟 Overview
VaultX is a fully offline-first, zero-knowledge password manager built with Flutter. Unlike traditional password managers, VaultX encrypts every single sensitive field independently on your device before any data ever touches SQLite or Supabase. The server never sees plaintext — not your passwords, not your usernames, not even your site names.
Designed for users who demand absolute control over their cryptographic keys, VaultX features seamless cross-platform sync, portable disaster recovery backups, and hardware-backed key storage.
⚠️ SECURITY WARNING — BY DESIGN:
Loss of Master Password = permanent, irrecoverable data loss. There is no reset link, no recovery key, and no support team that can decrypt your data. This is a feature, not a bug.
⚡ Core Features
🔒 Security-First & Zero-Knowledge
Per-field AES-256-GCM encryption — every sensitive field has its own unique 12-byte FortunaRandom nonce.
Argon2id KDF (memory-hard) running in Dart Isolates to prevent UI blocking. Standardized at 32MB memory cost across all platforms for deterministic cross-platform sync.
HKDF-SHA256 session key derivation.
Hardware-backed key storage (Android StrongBox HSM / Windows TPM 2.0 via Credential Manager).
Constant-time comparison for PIN and key verification to prevent timing attacks.
FFI-based memory zeroing of keys immediately after cryptographic operations.
🔄 Cross-Platform Sync & "Both" PIN Architecture
Offline-first architecture with local SQLite (Drift ORM).
Last-write-wins conflict resolution via Supabase Postgres with soft-delete tombstones.
Cross-Platform PIN Sync: Vault PIN salts are stored locally in the hardware keystore and encrypted with the session key and backed up to Supabase metadata. If you log into a new device or the OS wipes your keystore, the app silently restores your PIN salts using your Master Password.
Row Level Security (RLS) strictly enforced on all Supabase tables.
🧳 Data Portability & Disaster Recovery
Portable Encrypted Backup (.vltx): Exports your entire vault into a standalone, encrypted JSON file. Completely independent of Supabase; survives server outages and can be imported on any device.
Plaintext CSV Export/Import: Standardized format for migrating to/from other password managers (Bitwarden, 1Password, KeePass).
Native Android 13+ SAF Integration: Uses the native Storage Access Framework "Save As" dialog to bypass Scoped Storage restrictions without requiring invasive file permissions.
Deep Clean & Account Deletion: Granular controls to wipe local device cache or permanently nuke server-side data.
🧠 Password Intelligence & UX
In-Memory Full-Text Search: Instantly filter your vault by site name using a decrypted RAM cache (zero UI thread blocking).
3-tier password generator (Strong / Very Strong / Maximum) with Fisher-Yates shuffling via FortunaRandom.
zxcvbn strength scoring with visual feedback.
HaveIBeenPwned k-anonymous breach check — only the first 5 SHA-1 prefix characters leave the device.
🛡️ Threat Mitigation
Screenshot & screen recording blocking (Android FLAG_SECURE, best-effort on Windows).
Root / jailbreak detection (soft warning on Android).
10-attempt PIN wipe — vault is cryptographically destroyed after repeated failures.
30-second auto-clipboard clear after copying passwords.
Auto-lock on app backgrounding (lifecycle-aware).
🏗️ Security Architecture
mermaid





Code
Preview
The Zero-Knowledge Guarantee
Data
Where it lives
Encrypted?
Passwords, usernames, site names, URLs, notes
Device RAM → SQLite → Supabase
✅ AES-256-GCM (per-field)
Master key
RAM only (zeroed after HKDF)
N/A
Session key
RAM only (zeroed on lock)
N/A
Argon2id master salt
Supabase user_metadata
❌ (not secret — just a salt)
Vault PIN salts
Local HSM + Supabase (encrypted by session key)
✅ Hardware-backed + AES-GCM
is_favourite, is_breached, timestamps
SQLite + Supabase
❌ (non-sensitive metadata)
🔐 Cryptographic Flow
1. Master Password & Session Key
text
1234567891011
2. Vault PIN Setup
text
1234
3. Field Encryption (every sensitive field independently)
text
123456789
4. Portable Backup Crypto (.vltx)
To ensure backups survive Supabase outages, the export process decrypts data from the local DB and re-encrypts it with a user-provided Export Password.
text
123456
5. Decryption & Reveal
text
123456
📊 Data Model
EncryptedEntry Schema (SQLite & Supabase)
Column
Type
Encrypted
Key Used
id
UUID (PK)
❌
—
site_name_nonce / site_name_cipher
BLOB
✅
session_key
site_url_nonce / site_url_cipher
BLOB
✅
session_key
username_nonce / username_cipher
BLOB
✅
session_key
password_nonce / password_cipher
BLOB
✅
vault_key
notes_nonce / notes_cipher
BLOB
✅
session_key
category_nonce / category_cipher
BLOB
✅
session_key
is_favourite, is_breached, deleted
BOOLEAN
❌
—
created_at, modified_at
DATETIME
❌
—
device_id, sync_pending
TEXT/BOOL
❌
—
Note: Passwords are encrypted with the vault_key (derived from PIN), while all other sensitive fields use the session_key. This means site names can be displayed in the vault list without requiring a PIN, but viewing the actual password always requires PIN re-entry.
🖥️ Platform Feature Matrix
Feature
Android
Windows
Biometric unlock
✅ Fingerprint
✅ Windows Hello
Screenshot blocking
✅ FLAG_SECURE
⚠️ Partial (Win32 FFI)
Secure key storage
✅ StrongBox HSM
✅ Credential Manager + TPM
Root/jailbreak detection
✅ Soft check
❌ N/A
Clipboard auto-clear (30s)
✅
✅ (best-effort)
Native "Save As" (SAF)
✅ Scoped Storage compliant
✅ Native Dialog
SQLite ≥ 3.50.2 enforcement
✅
✅
Auto-lock on background
✅
✅
📁 Project Structure
text
123456789101112131415161718192021222324252627282930313233343536
🛠️ Tech Stack
Category
Technology
Framework
Flutter 3.11+
State
provider + ChangeNotifier
Navigation
go_router
Local DB
drift + sqlite3_flutter_libs
Crypto
cryptography (AES-GCM, HKDF), argon2 (KDF), pointycastle (FortunaRandom)
Key Storage
flutter_secure_storage
Backend
Supabase (Auth + Postgres + RLS)
HTTP
http (HIBP checks)
Biometrics
local_auth
Password Strength
zxcvbn
Platform
device_info_plus, connectivity_plus
Utilities
uuid, logger, file_picker, path_provider
🚀 Getting Started
Prerequisites
Flutter SDK ≥ 3.11.1
Android Studio (for Android build)
Visual Studio 2022 with C++ Desktop workload (for Windows build)
A Supabase account
Installation
bash
123456789101112131415161718
🗄️ Supabase Setup
1. Create a new Supabase project
2. Deploy the schema
Run config/supabase.sql in the Supabase SQL Editor. This creates:
profiles table (1:1 with auth.users)
vault_entries table (encrypted blobs)
Row Level Security policies (owner-only access)
3. Configure Email Auth
Go to Authentication → Providers → Email:
✅ Enable Email Provider
✅ Enable "Confirm email" (for verification flow)
4. Configure URL Redirects
Go to Authentication → URL Configuration:
Site URL: https://your-username.github.io/vaultx-auth/
Redirect URLs:
12
📦 Building for Release
⚠️ Never distribute debug binaries. Release builds enforce obfuscation and R8 minification.
Android APK / AAB
bash
12
Windows Executable & Installer
Build the obfuscated Windows binary:
bash
1
Create the Installer: Download Inno Setup, open the installer.iss file in the root directory, and press Ctrl+F9 to compile. This generates a professional VaultX_Setup.exe in the installer_output folder.
App Icons
VaultX uses flutter_launcher_icons. Place your app_icon.png and app_icon_foreground.png in assets/icon/ and run:
bash
1
🧪 Testing
Mandatory Crypto Tests
bash
1
All 10 tests must pass before any release. Tests include nonce uniqueness, GCM tampering detection, Isolate non-blocking, and FFI memory zeroing.
Integration Test
bash
1
Full flow: register → set PIN → save entry → sync → lock → relaunch → restore.
🚫 Security Hard Rules
These rules are enforced throughout the codebase. Violating any produces a security vulnerability.
Cryptography
❌ NEVER use dart:math.Random — FortunaRandom only.
❌ NEVER reuse a nonce — encrypt() generates its own.
❌ NEVER use == for PIN/key comparison — constantTimeEquals() always.
❌ NEVER store plaintext for sensitive fields.
❌ NEVER log secrets, keys, nonces, or PINs.
✅ ALWAYS zeroMemory() every key after use.
✅ ALWAYS run Argon2id in a Dart Isolate.
✅ ALWAYS enforce 15 ≤ password ≤ 128 before hashing.
✅ ALWAYS use identical Argon2id memory parameters (32MB) across all platforms to ensure cross-platform sync compatibility.
Platform & Storage
❌ NEVER call root_detect or flutter_windowmanager on Windows.
❌ NEVER store master/session key in SharedPreferences, Hive, or SQLite.
❌ NEVER add a PIN reset or recovery path (PIN is immutable by design).
✅ ALWAYS enable RLS on all Supabase tables.
✅ ALWAYS verify SQLite ≥ 3.50.2 at startup.
Build
❌ NEVER hardcode Supabase URL or anon key.
❌ NEVER send full SHA-1 to HIBP (5 chars only).
❌ NO print() or debugPrint() — logger package only.
⚠️ Known Limitations
These are intentional design tradeoffs documented for transparency:
No password recovery. Loss of Master Password = permanent data loss.
No SQLCipher. Per-field AES-256-GCM provides application-layer confidentiality. Schema and SQLite temp files are not encrypted — accepted risk on single-user devices.
Windows screenshot protection is partial. Win32 FFI cannot block all GPU-level capture tools.
Last-write-wins sync. No conflict resolution UI. Acceptable for single-user.
No TOTP 2FA. Replaced by Supabase email OTP for simplicity.
No browser extension or autofill. Out of scope for v1.0.
Windows clipboard managers may retain history externally despite 30s clear.
🤝 Contributing
VaultX is a security-critical application. All contributions must:
Pass all 10 crypto tests
Pass flutter analyze with zero warnings
Follow the Hard Rules listed above
Include tests for any new cryptographic code
Pull Request Process
Fork the repository and create your feature branch (git checkout -b feature/amazing-feature)
Commit your changes (git commit -m 'Add some amazing feature')
Push to the branch (git push origin feature/amazing-feature)
Open a Pull Request with a detailed description of your changes
📄 License
This project is licensed under the Apache License 2.0 — see the LICENSE file for details.
text
12
🙏 Acknowledgments
Supabase — Open-source Firebase alternative
Drift — Reactive SQLite library for Dart
Have I Been Pwned — Breach detection API
zxcvbn — Realistic password strength estimation
IconKitchen — Professional app icon generator
<div align="center">

Built with 🔒 and paranoia.
If you can read your passwords in the database, you're doing it wrong.
</div>
