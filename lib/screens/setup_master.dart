import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:zxcvbn/zxcvbn.dart';

import '../auth.dart';
import '../generator.dart';
import '../utils.dart';

class SetupMasterScreen extends StatefulWidget {
  const SetupMasterScreen({super.key});

  @override
  State<SetupMasterScreen> createState() => _SetupMasterScreenState();
}

class _SetupMasterScreenState extends State<SetupMasterScreen> {
  final _masterCtrl  = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _formKey     = GlobalKey<FormState>();
  bool _loading      = false;
  bool _obscure      = true;
  bool _ackChecked   = false;
  int _score         = 0;

  @override
  void dispose() {
    _masterCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _setup() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_ackChecked) {
      _showError('You must acknowledge the no-recovery warning.');
      return;
    }
    setState(() => _loading = true);
    try {
      await context.read<AuthService>().setupMasterPassword(_masterCtrl.text);
      if (mounted) context.go('/setup-pin');
    } on ValidationException catch (e) {
      if (mounted) _showError(e.message);
    } catch (e) {
      if (mounted) _showError('Setup failed. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  Color _strengthColor() {
    switch (_score) {
      case 0:
      case 1: return Colors.red;
      case 2: return Colors.orange;
      case 3: return Colors.blue;
      case 4: return Colors.green;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set Master Password')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // No-recovery warning
              Card(
                color: Colors.red.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.red.shade700),
                        const SizedBox(width: 8),
                        Text('No Recovery Path',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.red.shade700)),
                      ]),
                      const SizedBox(height: 8),
                      const Text(
                        'If you forget your Master Password, all vault data is permanently '
                        'and irrecoverably lost. There is no reset, no backup, and no support '
                        'that can recover it. This is by design.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _masterCtrl,
                obscureText: _obscure,
                onChanged: (v) {
                  setState(() {
                    _score = v.isEmpty ? 0 : (Zxcvbn().evaluate(v).score ?? 0).toInt();
                  });
                },
                decoration: InputDecoration(
                  labelText: 'Master Password',
                  prefixIcon: const Icon(Icons.key),
                  border: const OutlineInputBorder(),
                  helperText: '15–128 characters required',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.length < 15) return 'Minimum 15 characters';
                  if (v.length > 128) return 'Maximum 128 characters';
                  if (v == null || (Zxcvbn().evaluate(v).score ?? 0) < 3) return 'Password is too weak (score < 3)';
                  return null;
                },
              ),
              const SizedBox(height: 8),
              if (_masterCtrl.text.isNotEmpty) ...[
                LinearProgressIndicator(
                  value: (_score + 1) / 5,
                  color: _strengthColor(),
                  backgroundColor: Colors.grey.shade200,
                ),
                const SizedBox(height: 4),
                Text(
                  PasswordGenerator.scorePassword(_masterCtrl.text).label,
                  style: TextStyle(color: _strengthColor(), fontSize: 12),
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _confirmCtrl,
                obscureText: _obscure,
                decoration: const InputDecoration(
                  labelText: 'Confirm Master Password',
                  prefixIcon: Icon(Icons.key),
                  border: OutlineInputBorder(),
                ),
                validator: (v) => v != _masterCtrl.text ? 'Passwords do not match' : null,
              ),
              const SizedBox(height: 20),
              // Acknowledgement checkbox
              CheckboxListTile(
                value: _ackChecked,
                onChanged: (v) => setState(() => _ackChecked = v ?? false),
                title: const Text(
                  'I understand that losing my Master Password means permanent, '
                  'irrecoverable loss of all vault data.',
                  style: TextStyle(fontSize: 13),
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: (_loading || !_ackChecked) ? null : _setup,
                child: _loading
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Set Master Password'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
