import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../auth.dart';
import '../utils.dart';

class SetupPinScreen extends StatefulWidget {
  const SetupPinScreen({super.key});

  @override
  State<SetupPinScreen> createState() => _SetupPinScreenState();
}

class _SetupPinScreenState extends State<SetupPinScreen> {
  final _pinCtrl     = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _formKey     = GlobalKey<FormState>();
  bool _loading      = false;
  bool _obscure      = true;

  @override
  void dispose() {
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _setup() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await context.read<AuthService>().setupVaultPin(_pinCtrl.text);
      if (mounted) context.go('/vault');
    } on ValidationException catch (e) {
      if (mounted) _showError(e.message);
    } catch (e) {
      if (mounted) _showError('PIN setup failed. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set Vault PIN')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                color: Colors.amber.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.lock, color: Colors.amber.shade800),
                        const SizedBox(width: 8),
                        Text('PIN is Permanent',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.amber.shade800)),
                      ]),
                      const SizedBox(height: 8),
                      const Text(
                        'Your Vault PIN cannot be changed or reset after creation. '
                        'It is required every time you view a password. '
                        'After 10 wrong attempts, the vault will be wiped.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _pinCtrl,
                obscureText: _obscure,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Vault PIN (6+ digits)',
                  prefixIcon: const Icon(Icons.pin),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.length < 6) return 'Minimum 6 digits required';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmCtrl,
                obscureText: _obscure,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Confirm Vault PIN',
                  prefixIcon: Icon(Icons.pin),
                  border: OutlineInputBorder(),
                ),
                validator: (v) => v != _pinCtrl.text ? 'PINs do not match' : null,
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _loading ? null : _setup,
                child: _loading
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Set Vault PIN'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
