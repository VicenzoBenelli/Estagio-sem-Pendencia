import 'package:flutter/material.dart';

import '../../../core/responsive/app_breakpoints.dart';
import '../application/auth_controller.dart';
import '../domain/user_profile.dart';

class StudentHomePage extends StatelessWidget {
  const StudentHomePage({
    required this.profile,
    required this.controller,
    super.key,
  });

  final UserProfile profile;
  final AuthController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _AuthenticatedRoleShell(
      profile: profile,
      controller: controller,
      appBarTitle: 'Estágio sem Pendência — Estudante',
      badgeLabel: 'Perfil Estudante',
      badgeIcon: Icons.school_outlined,
      badgeBackground: colors.primaryContainer,
      badgeForeground: colors.onPrimaryContainer,
      scopeTitle: 'Autenticação e sessão de estudante validadas',
      scopeDescription: 'Este é o painel inicial do estudante para o Lote 1 (ESP-07 a ESP-09). Abertura de processo, checklist versionado e envio privado de PDFs serão habilitados nos próximos lotes.',
      disclaimer: 'Esta ferramenta não representa autorização institucional de estágio.',
    );
  }
}

class ReviewerHomePage extends StatelessWidget {
  const ReviewerHomePage({
    required this.profile,
    required this.controller,
    super.key,
  });

  final UserProfile profile;
  final AuthController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _AuthenticatedRoleShell(
      profile: profile,
      controller: controller,
      appBarTitle: 'Estágio sem Pendência — Revisor',
      badgeLabel: 'Perfil Revisor (Escopo Protegido)',
      badgeIcon: Icons.fact_check_outlined,
      badgeBackground: colors.tertiaryContainer,
      badgeForeground: colors.onTertiaryContainer,
      scopeTitle: 'Painel inicial do revisor autenticado',
      scopeDescription: 'Seu papel foi verificado no backend com isolamento por atribuição de escopo (reviewer_assignments). A fila de revisão documental e o histórico de decisões serão habilitados nos próximos lotes.',
      disclaimer: 'Aprovação documental no MVP não equivale a autorização oficial de estágio.',
    );
  }
}

class _AuthenticatedRoleShell extends StatelessWidget {
  const _AuthenticatedRoleShell({
    required this.profile,
    required this.controller,
    required this.appBarTitle,
    required this.badgeLabel,
    required this.badgeIcon,
    required this.badgeBackground,
    required this.badgeForeground,
    required this.scopeTitle,
    required this.scopeDescription,
    required this.disclaimer,
  });

  final UserProfile profile;
  final AuthController controller;
  final String appBarTitle;
  final String badgeLabel;
  final IconData badgeIcon;
  final Color badgeBackground;
  final Color badgeForeground;
  final String scopeTitle;
  final String scopeDescription;
  final String disclaimer;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(appBarTitle),
        actions: [
          IconButton(
            key: const Key('revalidate_session_button'),
            tooltip: 'Revalidar sessão',
            onPressed: controller.isBusy ? null : controller.revalidateSession,
            icon: const Icon(Icons.refresh),
          ),
          TextButton.icon(
            key: const Key('logout_button'),
            onPressed: controller.isBusy ? null : controller.signOut,
            icon: const Icon(Icons.logout),
            label: const Text('Sair'),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < AppBreakpoints.compact;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(compact ? 20 : 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 24 : 36),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: badgeBackground,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    badgeIcon,
                                    size: 20,
                                    color: badgeForeground,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    badgeLabel,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(color: badgeForeground),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            profile.displayName,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            profile.email,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            scopeTitle,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: colors.primary),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            scopeDescription,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 20),
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
                                      disclaimer,
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
