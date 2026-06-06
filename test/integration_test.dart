import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:vaultx/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('VaultX integration tests', () {

    testWidgets(
      'Full flow: register → set PIN → add entry → lock → relaunch → restore',
      (tester) async {
        app.main();
        await tester.pumpAndSettle(const Duration(seconds: 3));

        // ── 1. Should land on Login screen ──────────────────────────────
        expect(find.text('VaultX'), findsOneWidget);
        expect(find.text('Sign In'), findsOneWidget);

        // ── 2. Navigate to Register ─────────────────────────────────────
        await tester.tap(find.text('Create account'));
        await tester.pumpAndSettle();
        expect(find.text('Create Account'), findsOneWidget);

        // Note: Integration tests require a live Supabase instance.
        // Replace these with test credentials from your Supabase project.
        // Use a dedicated test user — never use production credentials.
        const testEmail    = 'test@vaultx-test.com';
        const testPassword = 'IntegrationTestPw123!';

        await tester.enterText(
            find.widgetWithText(TextFormField, 'Email'), testEmail);
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Account Password'), testPassword);
        await tester.tap(find.text('Create Account'));
        await tester.pumpAndSettle(const Duration(seconds: 5));

        // ── 3. Setup Master Password ────────────────────────────────────
        expect(find.text('Set Master Password'), findsOneWidget);
        const masterPw = 'CorrectHorseBatteryStaple2026!';
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Master Password'), masterPw);
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Confirm Master Password'), masterPw);

        // Tick the acknowledgement checkbox.
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Set Master Password'));
        await tester.pumpAndSettle(const Duration(seconds: 5));

        // ── 4. Setup Vault PIN ──────────────────────────────────────────
        expect(find.text('Set Vault PIN'), findsOneWidget);
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Vault PIN (6+ digits)'), '123456');
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Confirm Vault PIN'), '123456');
        await tester.tap(find.text('Set Vault PIN'));
        await tester.pumpAndSettle(const Duration(seconds: 5));

        // ── 5. Should be on Vault List ──────────────────────────────────
        expect(find.byIcon(Icons.add), findsOneWidget);

        // ── 6. Add a new entry ──────────────────────────────────────────
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();

        await tester.enterText(
            find.widgetWithText(TextFormField, 'Site Name *'), 'Test Site');
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Username / Email *'), 'user@test.com');
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Password *'),
            'MyStr0ng!Password#2026');
        await tester.tap(find.text('Save Entry'));
        await tester.pumpAndSettle(const Duration(seconds: 5));

        // ── 7. Entry should appear in vault list ────────────────────────
        expect(find.byType(ListTile), findsWidgets);

        // ── 8. Lock vault ───────────────────────────────────────────────
        await tester.tap(find.byIcon(Icons.lock_outline));
        await tester.pumpAndSettle();
        expect(find.text('Sign In'), findsOneWidget);

        // ── 9. Login again ──────────────────────────────────────────────
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Email'), testEmail);
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Password'), testPassword);
        await tester.tap(find.text('Sign In'));
        await tester.pumpAndSettle(const Duration(seconds: 5));

        // ── 10. Unlock with master password ─────────────────────────────
        expect(find.text('Unlock Vault'), findsOneWidget);
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Master Password'), masterPw);
        await tester.tap(find.text('Unlock'));
        await tester.pumpAndSettle(const Duration(seconds: 5));

        // ── 11. Entry should be restored from Supabase sync ─────────────
        expect(find.byType(ListTile), findsWidgets);
      },
    );
  });
}
