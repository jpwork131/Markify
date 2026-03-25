import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markify/features/license/providers/license_provider.dart';

class LicenseScreen extends ConsumerStatefulWidget {
  const LicenseScreen({super.key});

  @override
  ConsumerState<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends ConsumerState<LicenseScreen> {
  final _emailController = TextEditingController();
  final _keyController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _handleActivate() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    final success = await ref.read(licenseProvider.notifier).activate(
      _emailController.text.trim(),
      _keyController.text.trim(),
    );
    setState(() => _isLoading = false);

    if (!success && mounted) {
      final msg = ref.read(licenseProvider).message ?? 'Activation failed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 450),
          padding: const EdgeInsets.all(40.0),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 40,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.security, size: 64, color: Colors.blueAccent),
                const SizedBox(height: 24),
                Text(
                  'Activate Markify',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Please enter your email and license key to continue.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.textTheme.bodySmall?.color),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email Address',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _keyController,
                  decoration: const InputDecoration(
                    labelText: 'License Key',
                    prefixIcon: Icon(Icons.key_outlined),
                  ),
                  validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: _isLoading ? null : _handleActivate,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isLoading 
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Activate Now', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 24),
                Opacity(
                  opacity: 0.5,
                  child: Text(
                    'Your license is bound to this device hardware.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
