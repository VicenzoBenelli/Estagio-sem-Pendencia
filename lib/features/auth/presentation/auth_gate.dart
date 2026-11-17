import 'package:flutter/material.dart';

import '../../../core/responsive/app_breakpoints.dart';
import '../application/auth_controller.dart';
import 'auth_screen.dart';
import 'reset_password_page.dart';
import 'role_home_pages.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({required this.controller, super.key});

  final AuthController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final profile = controller.profile;
        final status = controller.status;

        // Chaves distintas por estado e usuário garantem descarte imediato
        // de qualquer estado de UI ao trocar de conta ou encerrar sessão.
        return switch (status) {
          AuthViewStatus.unconfigured => const _UnconfiguredSupabaseView(
            key: ValueKey('auth_unconfigured'),
          ),
          AuthViewStatus.loading => const _LoadingSessionView(
            key: ValueKey('auth_loading'),
          ),
          AuthViewStatus.unauthenticated ||
          AuthViewStatus.awaitingEmailConfirmation => AuthScreen(
            key: ValueKey('auth_screen_${status.name}'),
            controller: controller,
          ),
          AuthViewStatus.passwordRecovery => ResetPasswordPage(
            key: const ValueKey('auth_password_recovery'),
            controller: controller,
          ),
          AuthViewStatus.authenticatedStudent => StudentHomePage(
            key: ValueKey('student_home_${profile?.id ?? ''}'),
            profile: profile!,
            controller: controller,
          ),
          AuthViewStatus.authenticatedReviewer => ReviewerHomePage(
            key: ValueKey('reviewer_home_${profile?.id ?? ''}'),
            profile: profile!,
            controller: controller,
          ),
        };
      },
    );
  }
}

class _LoadingSessionView extends StatelessWidget {
  const _LoadingSessionView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Validando sessão...'),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnconfiguredSupabaseView extends StatelessWidget {
  const _UnconfiguredSupabaseView({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < AppBreakpoints.compact;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(compact ? 20 : 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 24 : 36),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.settings_input_antenna_outlined,
                            color: colors.primary,
                            size: 44,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Estágio sem Pendência',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Configuração Supabase ausente neste build',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: colors.primary),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Inicie a aplicação informando SUPABASE_URL e SUPABASE_PUBLISHABLE_KEY via --dart-define. Nunca inclua service_role no cliente.',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 16),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.secondaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    color: colors.onSecondaryContainer,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Esta ferramenta não representa autorização institucional de estágio.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: colors.onSecondaryContainer,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
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
