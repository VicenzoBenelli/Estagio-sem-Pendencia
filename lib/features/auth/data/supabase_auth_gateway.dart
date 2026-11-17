import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../domain/auth_gateway.dart';
import '../domain/user_profile.dart';

class SupabaseAuthGateway implements AuthGateway {
  SupabaseAuthGateway(this._client, {required this.config});

  final SupabaseClient _client;
  final SupabaseConfig config;

  @override
  bool get hasCurrentSession => _client.auth.currentSession != null;

  @override
  Stream<AuthGatewayEvent> get onAuthEvents {
    return _client.auth.onAuthStateChange.transform(
      StreamTransformer<AuthState, AuthGatewayEvent>.fromHandlers(
        handleData: (data, sink) {
          switch (data.event) {
            case AuthChangeEvent.signedOut:
              sink.add(const AuthGatewayEvent(kind: AuthEventKind.signedOut));
            case AuthChangeEvent.passwordRecovery:
              sink.add(
                const AuthGatewayEvent(kind: AuthEventKind.passwordRecovery),
              );
            case AuthChangeEvent.initialSession:
              if (data.session != null) {
                sink.add(
                  const AuthGatewayEvent(kind: AuthEventKind.authenticated),
                );
              } else {
                sink.add(const AuthGatewayEvent(kind: AuthEventKind.signedOut));
              }
            case AuthChangeEvent.signedIn:
            case AuthChangeEvent.tokenRefreshed:
            case AuthChangeEvent.userUpdated:
            case AuthChangeEvent.mfaChallengeVerified:
              if (data.session != null) {
                sink.add(
                  const AuthGatewayEvent(kind: AuthEventKind.authenticated),
                );
              }
            // ignore: deprecated_member_use
            case AuthChangeEvent.userDeleted:
              sink.add(const AuthGatewayEvent(kind: AuthEventKind.signedOut));
          }
        },
        handleError: (error, stackTrace, sink) {
          sink.add(
            AuthGatewayEvent(
              kind: AuthEventKind.sessionError,
              errorMessage: mapError(error),
            ),
          );
        },
      ),
    );
  }

  @override
  Future<UserProfile?> restoreAndValidateSession() async {
    final session = _client.auth.currentSession;
    if (session == null) {
      final urlError = _extractWebCallbackError();
      if (urlError != null) {
        throw AuthFailure(urlError, isSessionInvalid: true);
      }
      return null;
    }

    try {
      return await fetchCurrentProfile();
    } on AuthFailure {
      await _safeLocalSignOut();
      rethrow;
    } catch (error) {
      await _safeLocalSignOut();
      throw AuthFailure(mapError(error), isSessionInvalid: true);
    }
  }

  @override
  Future<UserProfile> fetchCurrentProfile() async {
    try {
      final userResponse = await _client.auth.getUser();
      final user = userResponse.user;
      if (user == null) {
        throw const AuthFailure(
          'Sua sessão expirou ou é inválida. Entre novamente.',
          isSessionInvalid: true,
        );
      }

      final row = await _client
          .from('profiles')
          .select('id, email, full_name, role, active')
          .eq('id', user.id)
          .maybeSingle();

      if (row == null) {
        throw const AuthFailure(
          'Perfil não localizado para esta sessão. Entre novamente.',
          isSessionInvalid: true,
        );
      }

      final profile = UserProfile.fromMap(row);
      if (!profile.active) {
        throw const AuthFailure(
          'Esta conta está desativada no momento.',
          isSessionInvalid: true,
        );
      }

      return profile;
    } on AuthFailure {
      rethrow;
    } catch (error) {
      throw AuthFailure(
        mapError(error),
        isSessionInvalid: _isAuthInvalid(error),
      );
    }
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    try {
      final response = await _client.auth.signUp(
        email: email.trim(),
        password: password,
        data: <String, dynamic>{'full_name': fullName.trim()},
        emailRedirectTo: SupabaseConfig.resolveRedirectUrl(),
      );

      if (response.session == null) {
        return const SignUpOutcome(requiresEmailConfirmation: true);
      }

      final profile = await fetchCurrentProfile();
      return SignUpOutcome(requiresEmailConfirmation: false, profile: profile);
    } on AuthFailure {
      rethrow;
    } catch (error) {
      throw AuthFailure(mapError(error));
    }
  }

  @override
  Future<UserProfile> signIn({
    required String email,
    required String password,
  }) async {
    try {
      await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      return await fetchCurrentProfile();
    } on AuthFailure {
      await _safeLocalSignOut();
      rethrow;
    } catch (error) {
      throw AuthFailure(mapError(error));
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _client.auth.signOut(scope: SignOutScope.global);
    } catch (_) {
      await _safeLocalSignOut();
    }
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {
    try {
      await _client.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: SupabaseConfig.resolveRedirectUrl(),
      );
    } catch (error) {
      throw AuthFailure(mapError(error));
    }
  }

  @override
  Future<void> updatePassword({required String newPassword}) async {
    try {
      await _client.auth.updateUser(UserAttributes(password: newPassword));
    } catch (error) {
      throw AuthFailure(mapError(error));
    }
  }

  Future<void> _safeLocalSignOut() async {
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      // Melhor esforço para limpar armazenamento local mesmo sem rede.
    }
  }

  String? _extractWebCallbackError() {
    if (!kIsWeb) return null;
    final uri = Uri.base;
    final fragmentParams = uri.fragment.isEmpty
        ? const <String, String>{}
        : Uri.splitQueryString(uri.fragment);
    final error = uri.queryParameters['error'] ?? fragmentParams['error'];
    final errorCode =
        uri.queryParameters['error_code'] ?? fragmentParams['error_code'];
    final errorDescription =
        uri.queryParameters['error_description'] ??
        fragmentParams['error_description'];

    if (error == null && errorCode == null && errorDescription == null) {
      return null;
    }
    return _mapLinkOrOtpMessage(
      code: errorCode ?? error,
      description: errorDescription,
    );
  }

  bool _isAuthInvalid(Object error) {
    if (error is AuthException) {
      final code = error.statusCode;
      return code == '401' || code == '403';
    }
    if (error is PostgrestException) {
      return error.code == '42501' || error.code == 'PGRST301';
    }
    return false;
  }

  String mapError(Object error) {
    if (error is AuthFailure) {
      return error.message;
    }

    if (error is AuthException) {
      final code = (error.code ?? '').toLowerCase();
      final msg = error.message.toLowerCase();
      final status = error.statusCode ?? '';

      if (code.contains('invalid_credentials') ||
          msg.contains('invalid login credentials')) {
        return 'E-mail ou senha inválidos.';
      }
      if (code.contains('email_not_confirmed') ||
          msg.contains('email not confirmed')) {
        return 'Confirme seu e-mail antes de entrar. Verifique a caixa de entrada (ou o Mailpit local).';
      }
      if (code.contains('otp_expired') ||
          code.contains('otp_disabled') ||
          code.contains('flow_state') ||
          code.contains('bad_code_verifier') ||
          code.contains('access_denied') ||
          msg.contains('expired') ||
          msg.contains('invalid') && msg.contains('token')) {
        return _mapLinkOrOtpMessage(code: code, description: error.message);
      }
      if (code.contains('weak_password') || msg.contains('password')) {
        return 'A senha não atende aos requisitos mínimos de segurança (mínimo de 8 caracteres).';
      }
      if (code.contains('over_email_send_rate_limit') ||
          code.contains('over_request_rate_limit') ||
          status == '429') {
        return 'Muitas solicitações em sequência. Aguarde alguns instantes e tente novamente.';
      }
      if (code.contains('user_already_exists') ||
          msg.contains('already registered')) {
        // Mensagem neutra para não confirmar diretamente o cadastro a terceiros.
        return 'Não foi possível concluir o cadastro com os dados informados.';
      }
      if (status == '401' || status == '403' || msg.contains('jwt')) {
        return 'Sua sessão expirou ou é inválida. Entre novamente.';
      }
    }

    if (error is PostgrestException) {
      if (error.code == '42501' || error.code == 'PGRST301') {
        return 'Acesso não autorizado ou sessão expirada.';
      }
      return 'Não foi possível consultar os dados do perfil no servidor.';
    }

    final text = error.toString().toLowerCase();
    if (text.contains('socketexception') ||
        text.contains('clientexception') ||
        text.contains('failed host lookup') ||
        text.contains('connection refused') ||
        text.contains('network')) {
      final androidHint = config.isAndroidLoopbackWarning
          ? ' Em emulador Android, use http://10.0.2.2:54321 em vez de 127.0.0.1.'
          : '';
      return 'Não foi possível conectar ao servidor de autenticação.$androidHint';
    }

    return 'Não foi possível concluir a operação de autenticação. Tente novamente.';
  }

  String _mapLinkOrOtpMessage({String? code, String? description}) {
    final normalized = '${code ?? ''} ${description ?? ''}'.toLowerCase();
    if (normalized.contains('expired') || normalized.contains('invalid')) {
      return 'O link de verificação ou redefinição é inválido ou expirou. Solicite um novo link.';
    }
    return 'Não foi possível validar o link de autenticação. Solicite um novo link.';
  }
}
