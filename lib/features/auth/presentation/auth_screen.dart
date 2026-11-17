import 'package:flutter/material.dart';

import '../../../core/responsive/app_breakpoints.dart';
import '../application/auth_controller.dart';

enum _AuthMode { signIn, signUp, forgotPassword }

class AuthScreen extends StatefulWidget {
  const AuthScreen({required this.controller, super.key});

  final AuthController controller;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  _AuthMode _mode = _AuthMode.signIn;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _switchMode(_AuthMode nextMode) {
    if (_mode == nextMode) return;
    widget.controller.clearMessages();
    _passwordController.clear();
    _confirmPasswordController.clear();
    setState(() {
      _mode = nextMode;
    });
  }

  String? _validateEmail(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return 'Informe seu e-mail.';
    }
    final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    if (!emailRegex.hasMatch(text)) {
      return 'Informe um e-mail válido.';
    }
    return null;
  }

  String? _validateFullName(String? value) {
    if (_mode != _AuthMode.signUp) return null;
    final text = value?.trim() ?? '';
    if (text.length < 3) {
      return 'Informe seu nome completo (mínimo de 3 caracteres).';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (_mode == _AuthMode.forgotPassword) return null;
    final text = value ?? '';
    if (text.isEmpty) {
      return 'Informe sua senha.';
    }
    if (_mode == _AuthMode.signUp && text.length < 8) {
      return 'A senha deve ter pelo menos 8 caracteres.';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (_mode != _AuthMode.signUp) return null;
    if ((value ?? '') != _passwordController.text) {
      return 'As senhas não coincidem.';
    }
    return null;
  }

  Future<void> _submit() async {
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid || widget.controller.isBusy) return;

    final email = _emailController.text.trim();
    switch (_mode) {
      case _AuthMode.signIn:
        await widget.controller.signIn(
          email: email,
          password: _passwordController.text,
        );
      case _AuthMode.signUp:
        await widget.controller.signUp(
          email: email,
          password: _passwordController.text,
          fullName: _nameController.text.trim(),
        );
      case _AuthMode.forgotPassword:
        await widget.controller.sendPasswordResetEmail(email: email);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final controller = widget.controller;
    final isAwaitingEmail =
        controller.status == AuthViewStatus.awaitingEmailConfirmation;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < AppBreakpoints.compact;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(compact ? 20 : 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 24 : 36),
                      child: isAwaitingEmail
                          ? _buildAwaitingConfirmation(context, colors)
                          : _buildFormContent(context, colors, compact),
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

  Widget _buildAwaitingConfirmation(BuildContext context, ColorScheme colors) {
    final controller = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.mark_email_read_outlined, size: 48, color: colors.primary),
        const SizedBox(height: 16),
        Text(
          'Confirme seu e-mail',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(
          'Enviamos um link de confirmação para ${controller.pendingConfirmationEmail ?? 'o e-mail informado'}. Após confirmar pelo link, entre com sua senha.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 20),
        if (controller.infoMessage != null)
          _StatusBanner(
            icon: Icons.info_outline,
            message: controller.infoMessage!,
            backgroundColor: colors.secondaryContainer,
            foregroundColor: colors.onSecondaryContainer,
          ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () {
            _switchMode(_AuthMode.signIn);
            controller.returnToLogin();
          },
          icon: const Icon(Icons.login),
          label: const Text('Ir para o login'),
        ),
      ],
    );
  }

  Widget _buildFormContent(
    BuildContext context,
    ColorScheme colors,
    bool compact,
  ) {
    final controller = widget.controller;
    final busy = controller.isBusy;

    final title = switch (_mode) {
      _AuthMode.signIn => 'Entrar na conta',
      _AuthMode.signUp => 'Criar conta de estudante',
      _AuthMode.forgotPassword => 'Recuperar senha',
    };

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.assignment_turned_in_outlined,
                color: colors.primary,
                size: 36,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Estágio sem Pendência',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      'Acompanhamento documental de estágio obrigatório',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SegmentedButton<_AuthMode>(
            segments: const [
              ButtonSegment<_AuthMode>(
                value: _AuthMode.signIn,
                icon: Icon(Icons.login),
                label: Text('Entrar'),
              ),
              ButtonSegment<_AuthMode>(
                value: _AuthMode.signUp,
                icon: Icon(Icons.person_add_outlined),
                label: Text('Cadastrar'),
              ),
              ButtonSegment<_AuthMode>(
                value: _AuthMode.forgotPassword,
                icon: Icon(Icons.lock_reset),
                label: Text('Recuperar'),
              ),
            ],
            selected: <_AuthMode>{_mode},
            onSelectionChanged: busy
                ? null
                : (selection) {
                    if (selection.isNotEmpty) {
                      _switchMode(selection.first);
                    }
                  },
          ),
          const SizedBox(height: 20),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          if (controller.errorMessage != null) ...[
            _StatusBanner(
              icon: Icons.error_outline,
              message: controller.errorMessage!,
              backgroundColor: colors.errorContainer,
              foregroundColor: colors.onErrorContainer,
            ),
            const SizedBox(height: 12),
          ],
          if (controller.infoMessage != null) ...[
            _StatusBanner(
              icon: Icons.check_circle_outline,
              message: controller.infoMessage!,
              backgroundColor: colors.secondaryContainer,
              foregroundColor: colors.onSecondaryContainer,
            ),
            const SizedBox(height: 12),
          ],
          if (_mode == _AuthMode.signUp) ...[
            TextFormField(
              key: const Key('auth_full_name_field'),
              controller: _nameController,
              enabled: !busy,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.name],
              decoration: const InputDecoration(
                labelText: 'Nome completo',
                prefixIcon: Icon(Icons.badge_outlined),
                border: OutlineInputBorder(),
              ),
              validator: _validateFullName,
            ),
            const SizedBox(height: 14),
          ],
          TextFormField(
            key: const Key('auth_email_field'),
            controller: _emailController,
            enabled: !busy,
            keyboardType: TextInputType.emailAddress,
            textInputAction: _mode == _AuthMode.forgotPassword
                ? TextInputAction.done
                : TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'E-mail',
              prefixIcon: Icon(Icons.email_outlined),
              border: OutlineInputBorder(),
            ),
            validator: _validateEmail,
            onFieldSubmitted: (_) {
              if (_mode == _AuthMode.forgotPassword) {
                _submit();
              }
            },
          ),
          if (_mode != _AuthMode.forgotPassword) ...[
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('auth_password_field'),
              controller: _passwordController,
              enabled: !busy,
              obscureText: _obscurePassword,
              textInputAction: _mode == _AuthMode.signUp
                  ? TextInputAction.next
                  : TextInputAction.done,
              autofillHints: _mode == _AuthMode.signUp
                  ? const [AutofillHints.newPassword]
                  : const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'Senha',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                helperText: _mode == _AuthMode.signUp
                    ? 'Mínimo de 8 caracteres.'
                    : null,
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Mostrar senha' : 'Ocultar senha',
                  onPressed: () {
                    setState(() => _obscurePassword = !_obscurePassword);
                  },
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              validator: _validatePassword,
              onFieldSubmitted: (_) {
                if (_mode == _AuthMode.signIn) {
                  _submit();
                }
              },
            ),
          ],
          if (_mode == _AuthMode.signUp) ...[
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('auth_confirm_password_field'),
              controller: _confirmPasswordController,
              enabled: !busy,
              obscureText: _obscureConfirmPassword,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Confirmar senha',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscureConfirmPassword
                      ? 'Mostrar confirmação'
                      : 'Ocultar confirmação',
                  onPressed: () {
                    setState(
                      () => _obscureConfirmPassword = !_obscureConfirmPassword,
                    );
                  },
                  icon: Icon(
                    _obscureConfirmPassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              validator: _validateConfirmPassword,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Text(
              'O cadastro público cria automaticamente um perfil de estudante. Perfis de revisor são provisionados exclusivamente no backend.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('auth_submit_button'),
            onPressed: busy ? null : _submit,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: compact ? 12 : 14),
              child: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(switch (_mode) {
                      _AuthMode.signIn => 'Entrar',
                      _AuthMode.signUp => 'Criar conta',
                      _AuthMode.forgotPassword => 'Enviar link de recuperação',
                    }),
            ),
          ),
          const SizedBox(height: 18),
          _StatusBanner(
            icon: Icons.info_outline,
            message: 'Esta ferramenta não representa autorização institucional de estágio.',
            backgroundColor: colors.surfaceContainerHighest,
            foregroundColor: colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.icon,
    required this.message,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final IconData icon;
  final String message;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: foregroundColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: foregroundColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
