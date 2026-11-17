import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:estagio_sem_pendencia/app/app.dart';
import 'package:estagio_sem_pendencia/core/config/supabase_config.dart';
import 'package:estagio_sem_pendencia/features/auth/application/auth_controller.dart';
import 'package:estagio_sem_pendencia/features/auth/domain/auth_gateway.dart';
import 'package:estagio_sem_pendencia/features/auth/domain/user_profile.dart';

class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway({
    this.restoredProfile,
    this.restoreFailure,
    this.signInProfile,
    this.signInFailure,
    this.requiresEmailConfirmation = true,
  });

  final StreamController<AuthGatewayEvent> _events =
      StreamController<AuthGatewayEvent>.broadcast();

  UserProfile? restoredProfile;
  AuthFailure? restoreFailure;
  UserProfile? signInProfile;
  AuthFailure? signInFailure;
  bool requiresEmailConfirmation;

  String? lastSignUpEmail;
  String? lastSignUpFullName;
  String? lastResetEmail;
  String? lastUpdatedPassword;
  int signOutCalls = 0;

  @override
  bool get hasCurrentSession => restoredProfile != null;

  @override
  Stream<AuthGatewayEvent> get onAuthEvents => _events.stream;

  void emit(AuthGatewayEvent event) => _events.add(event);

  Future<void> dispose() => _events.close();

  @override
  Future<UserProfile?> restoreAndValidateSession() async {
    if (restoreFailure != null) {
      restoredProfile = null;
      throw restoreFailure!;
    }
    return restoredProfile;
  }

  @override
  Future<UserProfile> fetchCurrentProfile() async {
    final profile = restoredProfile ?? signInProfile;
    if (profile == null) {
      throw const AuthFailure('Sessão inválida.', isSessionInvalid: true);
    }
    return profile;
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    lastSignUpEmail = email;
    lastSignUpFullName = fullName;
    if (requiresEmailConfirmation) {
      return const SignUpOutcome(requiresEmailConfirmation: true);
    }
    final created = UserProfile(
      id: 'student-new',
      email: email,
      fullName: fullName,
      role: UserRole.student,
      active: true,
    );
    restoredProfile = created;
    return SignUpOutcome(requiresEmailConfirmation: false, profile: created);
  }

  @override
  Future<UserProfile> signIn({
    required String email,
    required String password,
  }) async {
    if (signInFailure != null) {
      throw signInFailure!;
    }
    final profile = signInProfile!;
    restoredProfile = profile;
    return profile;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    restoredProfile = null;
    _events.add(const AuthGatewayEvent(kind: AuthEventKind.signedOut));
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {
    lastResetEmail = email;
  }

  @override
  Future<void> updatePassword({required String newPassword}) async {
    lastUpdatedPassword = newPassword;
    restoredProfile ??= signInProfile;
  }
}

void main() {
  group('Configuração e modelos', () {
    test('SupabaseConfig valida URL e chave pública corretamente', () {
      const missing = SupabaseConfig(url: '', publishableKey: '');
      expect(missing.isConfigured, isFalse);

      const badScheme = SupabaseConfig(
        url: 'ftp://127.0.0.1:54321',
        publishableKey: 'abc',
      );
      expect(badScheme.isConfigured, isFalse);

      const validLocal = SupabaseConfig(
        url: 'http://127.0.0.1:54321',
        publishableKey: 'sb_publishable_demo',
      );
      expect(validLocal.isConfigured, isTrue);
      expect(validLocal.isLoopbackHost, isTrue);

      const validRemote = SupabaseConfig(
        url: 'https://demo.supabase.co',
        publishableKey: 'sb_publishable_demo',
      );
      expect(validRemote.isConfigured, isTrue);
      expect(validRemote.isLoopbackHost, isFalse);
    });

    test(
      'resolveRedirectUrl resolve callback Android válido segundo RFC 3986',
      () {
        const callback = SupabaseConfig.androidAuthCallbackUrl;
        expect(callback, 'estagiosempendencia://auth/callback');
        expect(SupabaseConfig.isValidCallbackUri(callback), isTrue);

        final parsed = Uri.parse(callback);
        expect(parsed.scheme, 'estagiosempendencia');
        expect(parsed.scheme.contains('_'), isFalse);
        expect(parsed.host, 'auth');
        expect(parsed.path, '/callback');
        expect(SupabaseConfig.resolveRedirectUrl(), callback);

        // Esquema com underscore viola RFC 3986 e deve ser rejeitado pelo validador
        expect(
          SupabaseConfig.isValidCallbackUri(
            'br.com.estagiosempendencia.estagio_sem_pendencia://auth-callback',
          ),
          isFalse,
        );
      },
    );

    test('UserProfile.fromMap interpreta student e reviewer e rejeita papel inválido', () {
      final student = UserProfile.fromMap({
        'id': 'u1',
        'email': 'aluno@demo.local',
        'full_name': 'Aluno Teste',
        'role': 'student',
        'active': true,
      });
      expect(student.role, UserRole.student);
      expect(student.displayName, 'Aluno Teste');

      final reviewer = UserProfile.fromMap({
        'id': 'u2',
        'email': 'revisor@demo.local',
        'full_name': null,
        'role': 'reviewer',
        'active': true,
      });
      expect(reviewer.role, UserRole.reviewer);
      expect(reviewer.displayName, 'revisor@demo.local');

      expect(
        () => UserProfile.fromMap({
          'id': 'u3',
          'email': 'x@demo.local',
          'role': 'admin',
          'active': true,
        }),
        throwsFormatException,
      );
    });
  });

  group('Interface responsiva sem configuração', () {
    testWidgets('exibe orientação de configuração em largura compacta', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(const EstagioSemPendenciaApp());
      await tester.pumpAndSettle();

      expect(find.text('Estágio sem Pendência'), findsOneWidget);
      expect(
        find.text('Configuração Supabase ausente neste build'),
        findsOneWidget,
      );
      expect(
        find.textContaining('não representa autorização institucional'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('exibe orientação de configuração em largura ampla', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(const EstagioSemPendenciaApp());
      await tester.pumpAndSettle();

      expect(find.text('Estágio sem Pendência'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Fluxos de Autenticação e Separação de Perfis', () {
    testWidgets(
      'cadastro cria estudante sem seletor de papel e solicita confirmação',
      (tester) async {
        final gateway = _FakeAuthGateway(requiresEmailConfirmation: true);
        final controller = AuthController(gateway: gateway);
        addTearDown(() async {
          controller.dispose();
          await gateway.dispose();
        });
        await controller.initialize();

        await tester.binding.setSurfaceSize(const Size(400, 860));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(authController: controller),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Cadastrar'));
        await tester.pumpAndSettle();

        expect(find.text('Criar conta de estudante'), findsOneWidget);
        expect(find.textContaining('perfil de estudante'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('auth_full_name_field')),
          'Estudante Fictício',
        );
        await tester.enterText(
          find.byKey(const Key('auth_email_field')),
          'estudante@demo.local',
        );
        await tester.enterText(
          find.byKey(const Key('auth_password_field')),
          'SenhaSegura123',
        );
        await tester.enterText(
          find.byKey(const Key('auth_confirm_password_field')),
          'SenhaSegura123',
        );

        await tester.ensureVisible(find.byKey(const Key('auth_submit_button')));
        await tester.tap(find.byKey(const Key('auth_submit_button')));
        await tester.pumpAndSettle();

        expect(gateway.lastSignUpEmail, 'estudante@demo.local');
        expect(gateway.lastSignUpFullName, 'Estudante Fictício');
        expect(find.text('Confirme seu e-mail'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'login estudante x revisor separa áreas visuais e logout limpa sessão',
      (tester) async {
        const student = UserProfile(
          id: 'student-1',
          email: 'estudante.a@demo.local',
          fullName: 'Estudante A',
          role: UserRole.student,
          active: true,
        );
        const reviewer = UserProfile(
          id: 'reviewer-1',
          email: 'revisor.r1@demo.local',
          fullName: 'Revisor R1',
          role: UserRole.reviewer,
          active: true,
        );

        final gateway = _FakeAuthGateway(signInProfile: student);
        final controller = AuthController(gateway: gateway);
        addTearDown(() async {
          controller.dispose();
          await gateway.dispose();
        });
        await controller.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(authController: controller),
        );
        await tester.pumpAndSettle();

        // Login Estudante A
        await tester.enterText(
          find.byKey(const Key('auth_email_field')),
          student.email,
        );
        await tester.enterText(
          find.byKey(const Key('auth_password_field')),
          'SenhaSegura123',
        );
        await tester.tap(find.byKey(const Key('auth_submit_button')));
        await tester.pumpAndSettle();

        expect(find.text('Perfil Estudante'), findsOneWidget);
        expect(find.text('Estudante A'), findsOneWidget);
        expect(find.text('Perfil Revisor (Escopo Protegido)'), findsNothing);

        // Logout limpa dados anteriores
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();

        expect(gateway.signOutCalls, 1);
        expect(controller.profile, isNull);
        expect(find.text('Estudante A'), findsNothing);
        expect(find.text('Entrar na conta'), findsOneWidget);

        // Login Revisor R1 não reapresenta dados do Estudante A
        gateway.signInProfile = reviewer;
        await tester.enterText(
          find.byKey(const Key('auth_email_field')),
          reviewer.email,
        );
        await tester.enterText(
          find.byKey(const Key('auth_password_field')),
          'SenhaSegura123',
        );
        await tester.tap(find.byKey(const Key('auth_submit_button')));
        await tester.pumpAndSettle();

        expect(find.text('Perfil Revisor (Escopo Protegido)'), findsOneWidget);
        expect(find.text('Revisor R1'), findsOneWidget);
        expect(find.text('Estudante A'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'sessão restaurada inválida bloqueia acesso e recuperação de senha funciona',
      (tester) async {
        final gateway = _FakeAuthGateway(
          restoredProfile: const UserProfile(
            id: 'student-1',
            email: 'estudante.a@demo.local',
            fullName: 'Estudante A',
            role: UserRole.student,
            active: true,
          ),
          restoreFailure: const AuthFailure(
            'Sua sessão expirou ou é inválida. Entre novamente.',
            isSessionInvalid: true,
          ),
        );
        final controller = AuthController(gateway: gateway);
        addTearDown(() async {
          controller.dispose();
          await gateway.dispose();
        });
        await controller.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(authController: controller),
        );
        await tester.pumpAndSettle();

        // Sessão expirada na restauração cai para login com erro claro
        expect(find.text('Entrar na conta'), findsOneWidget);
        expect(
          find.text('Sua sessão expirou ou é inválida. Entre novamente.'),
          findsOneWidget,
        );

        // Solicitar recuperação de senha mostra mensagem neutra
        await tester.tap(find.text('Recuperar'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('auth_email_field')),
          'estudante.a@demo.local',
        );
        await tester.tap(find.byKey(const Key('auth_submit_button')));
        await tester.pumpAndSettle();

        expect(gateway.lastResetEmail, 'estudante.a@demo.local');
        expect(
          find.textContaining('Se o e-mail informado estiver cadastrado'),
          findsOneWidget,
        );

        // Evento de link de recuperação abre tela de redefinição
        gateway.signInProfile = const UserProfile(
          id: 'student-1',
          email: 'estudante.a@demo.local',
          fullName: 'Estudante A',
          role: UserRole.student,
          active: true,
        );
        gateway.emit(
          const AuthGatewayEvent(kind: AuthEventKind.passwordRecovery),
        );
        await tester.pumpAndSettle();

        expect(find.text('Defina sua nova senha'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('reset_new_password_field')),
          'NovaSenha123',
        );
        await tester.enterText(
          find.byKey(const Key('reset_confirm_password_field')),
          'NovaSenha123',
        );
        await tester.tap(find.byKey(const Key('reset_submit_button')));
        await tester.pumpAndSettle();

        expect(gateway.lastUpdatedPassword, 'NovaSenha123');
        expect(find.text('Perfil Estudante'), findsOneWidget);

        // Link inválido ou expirado exibe mensagem apropriada no retorno
        gateway.emit(
          const AuthGatewayEvent(
            kind: AuthEventKind.sessionError,
            errorMessage: 'O link de verificação ou redefinição é inválido ou expirou. Solicite um novo link.',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Entrar na conta'), findsOneWidget);
        expect(find.textContaining('inválido ou expirou'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('falha no login exibe mensagem segura sem vazar detalhes', (
      tester,
    ) async {
      final gateway = _FakeAuthGateway(
        signInFailure: const AuthFailure('E-mail ou senha inválidos.'),
      );
      final controller = AuthController(gateway: gateway);
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });
      await controller.initialize();

      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        EstagioSemPendenciaApp(authController: controller),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('auth_email_field')),
        'desconhecido@demo.local',
      );
      await tester.enterText(
        find.byKey(const Key('auth_password_field')),
        'SenhaErrada123',
      );
      await tester.ensureVisible(find.byKey(const Key('auth_submit_button')));
      await tester.tap(find.byKey(const Key('auth_submit_button')));
      await tester.pumpAndSettle();

      expect(find.text('E-mail ou senha inválidos.'), findsOneWidget);
      expect(find.text('Perfil Estudante'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
