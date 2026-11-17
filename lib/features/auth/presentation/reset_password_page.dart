import 'package:flutter/material.dart';

import '../../../core/responsive/app_breakpoints.dart';
import '../application/auth_controller.dart';

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({required this.controller, super.key});

  final AuthController controller;

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid || widget.controller.isBusy) return;
    await widget.controller.updatePassword(
      newPassword: _passwordController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final controller = widget.controller;
    final busy = controller.isBusy;

    return Scaffold(
      appBar: AppBar(title: const Text('Redefinição de senha')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < AppBreakpoints.compact;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(compact ? 20 : 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 24 : 36),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock_reset,
                              size: 44,
                              color: colors.primary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Defina sua nova senha',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 12),
                            if (controller.errorMessage != null) ...[
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.errorContainer,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.error_outline,
                                        color: colors.onErrorContainer,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          controller.errorMessage!,
                                          style: TextStyle(
                                            color: colors.onErrorContainer,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            TextFormField(
                              key: const Key('reset_new_password_field'),
                              controller: _passwordController,
                              enabled: !busy,
                              obscureText: _obscurePassword,
                              decoration: InputDecoration(
                                labelText: 'Nova senha',
                                helperText: 'Mínimo de 8 caracteres.',
                                prefixIcon: const Icon(Icons.lock_outline),
                                border: const OutlineInputBorder(),
                                suffixIcon: IconButton(
                                  tooltip: _obscurePassword
                                      ? 'Mostrar senha'
                                      : 'Ocultar senha',
                                  onPressed: () {
                                    setState(
                                      () =>
                                          _obscurePassword = !_obscurePassword,
                                    );
                                  },
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                              validator: (value) {
                                final text = value ?? '';
                                if (text.length < 8) {
                                  return 'A senha deve ter pelo menos 8 caracteres.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              key: const Key('reset_confirm_password_field'),
                              controller: _confirmController,
                              enabled: !busy,
                              obscureText: _obscurePassword,
                              decoration: const InputDecoration(
                                labelText: 'Confirmar nova senha',
                                prefixIcon: Icon(Icons.lock_outline),
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) {
                                if ((value ?? '') != _passwordController.text) {
                                  return 'As senhas não coincidem.';
                                }
                                return null;
                              },
                              onFieldSubmitted: (_) => _submit(),
                            ),
                            const SizedBox(height: 20),
                            FilledButton(
                              key: const Key('reset_submit_button'),
                              onPressed: busy ? null : _submit,
                              child: busy
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Salvar nova senha'),
                            ),
                            const SizedBox(height: 10),
                            TextButton(
                              onPressed: busy ? null : controller.signOut,
                              child: const Text('Cancelar e encerrar sessão'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
