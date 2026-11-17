import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/auth_gateway.dart';
import '../domain/user_profile.dart';

enum AuthViewStatus {
  unconfigured,
  loading,
  unauthenticated,
  awaitingEmailConfirmation,
  passwordRecovery,
  authenticatedStudent,
  authenticatedReviewer,
}

class AuthController extends ChangeNotifier {
  AuthController({required this.gateway});

  final AuthGateway? gateway;

  StreamSubscription<AuthGatewayEvent>? _subscription;
  int _authEpoch = 0;

  AuthViewStatus _status = AuthViewStatus.loading;
  UserProfile? _profile;
  String? _errorMessage;
  String? _infoMessage;
  String? _pendingConfirmationEmail;
  bool _isBusy = false;

  AuthViewStatus get status => _status;
  UserProfile? get profile => _profile;
  String? get errorMessage => _errorMessage;
  String? get infoMessage => _infoMessage;
  String? get pendingConfirmationEmail => _pendingConfirmationEmail;
  bool get isBusy => _isBusy;

  Future<void> initialize() async {
    final gateway = this.gateway;
    if (gateway == null) {
      _profile = null;
      _status = AuthViewStatus.unconfigured;
      notifyListeners();
      return;
    }

    _subscription ??= gateway.onAuthEvents.listen(_handleGatewayEvent);
    await revalidateSession();
  }

  Future<void> revalidateSession() async {
    final gateway = this.gateway;
    if (gateway == null) return;

    final epoch = ++_authEpoch;
    _status = AuthViewStatus.loading;
    _errorMessage = null;
    notifyListeners();

    try {
      final restored = await gateway.restoreAndValidateSession();
      if (epoch != _authEpoch) return;

      if (restored == null) {
        if (_status != AuthViewStatus.passwordRecovery) {
          _clearAuthenticatedState();
          _status = AuthViewStatus.unauthenticated;
        }
      } else if (_status != AuthViewStatus.passwordRecovery) {
        _setAuthenticatedProfile(restored);
      }
    } on AuthFailure catch (failure) {
      if (epoch != _authEpoch) return;
      _clearAuthenticatedState();
      _status = AuthViewStatus.unauthenticated;
      _errorMessage = failure.message;
    } catch (_) {
      if (epoch != _authEpoch) return;
      _clearAuthenticatedState();
      _status = AuthViewStatus.unauthenticated;
      _errorMessage = 'Não foi possível validar sua sessão. Entre novamente.';
    }
    notifyListeners();
  }

  Future<void> signIn({required String email, required String password}) async {
    final gateway = this.gateway;
    if (gateway == null) return;

    final epoch = ++_authEpoch;
    _isBusy = true;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();

    try {
      final profile = await gateway.signIn(email: email, password: password);
      if (epoch != _authEpoch) return;
      _pendingConfirmationEmail = null;
      _setAuthenticatedProfile(profile);
    } on AuthFailure catch (failure) {
      if (epoch != _authEpoch) return;
      _clearAuthenticatedState();
      _status = AuthViewStatus.unauthenticated;
      _errorMessage = failure.message;
    } catch (_) {
      if (epoch != _authEpoch) return;
      _clearAuthenticatedState();
      _status = AuthViewStatus.unauthenticated;
      _errorMessage = 'Não foi possível entrar no momento.';
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<void> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    final gateway = this.gateway;
    if (gateway == null) return;

    final epoch = ++_authEpoch;
    _isBusy = true;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();

    try {
      final outcome = await gateway.signUp(
        email: email,
        password: password,
        fullName: fullName,
      );
      if (epoch != _authEpoch) return;

      if (outcome.requiresEmailConfirmation || outcome.profile == null) {
        _clearAuthenticatedState();
        _pendingConfirmationEmail = email.trim();
        _status = AuthViewStatus.awaitingEmailConfirmation;
        _infoMessage = 'Cadastro criado como estudante. Confirme seu e-mail antes de acessar o sistema.';
      } else {
        _pendingConfirmationEmail = null;
        _setAuthenticatedProfile(outcome.profile!);
      }
    } on AuthFailure catch (failure) {
      if (epoch != _authEpoch) return;
      _errorMessage = failure.message;
    } catch (_) {
      if (epoch != _authEpoch) return;
      _errorMessage = 'Não foi possível concluir o cadastro.';
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<void> sendPasswordResetEmail({required String email}) async {
    final gateway = this.gateway;
    if (gateway == null) return;

    _isBusy = true;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();

    try {
      await gateway.sendPasswordResetEmail(email: email);
      // Mensagem neutra: nunca confirma se o e-mail existe na base.
      _infoMessage = 'Se o e-mail informado estiver cadastrado, você receberá instruções de recuperação.';
    } on AuthFailure catch (failure) {
      _errorMessage = failure.message;
    } catch (_) {
      _errorMessage = 'Não foi possível solicitar a recuperação de senha.';
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<void> updatePassword({required String newPassword}) async {
    final gateway = this.gateway;
    if (gateway == null) return;

    final epoch = ++_authEpoch;
    _isBusy = true;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();

    try {
      await gateway.updatePassword(newPassword: newPassword);
      final profile = await gateway.fetchCurrentProfile();
      if (epoch != _authEpoch) return;
      _infoMessage = 'Senha redefinida com sucesso.';
      _setAuthenticatedProfile(profile);
    } on AuthFailure catch (failure) {
      if (epoch != _authEpoch) return;
      _errorMessage = failure.message;
      if (failure.isSessionInvalid) {
        _clearAuthenticatedState();
        _status = AuthViewStatus.unauthenticated;
      }
    } catch (_) {
      if (epoch != _authEpoch) return;
      _errorMessage = 'Não foi possível atualizar a senha.';
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    final gateway = this.gateway;
    ++_authEpoch;
    _clearAuthenticatedState();
    _pendingConfirmationEmail = null;
    _errorMessage = null;
    _infoMessage = 'Sessão encerrada com segurança.';
    _status = gateway == null
        ? AuthViewStatus.unconfigured
        : AuthViewStatus.unauthenticated;
    notifyListeners();

    if (gateway != null) {
      await gateway.signOut();
    }
  }

  void returnToLogin() {
    _pendingConfirmationEmail = null;
    _errorMessage = null;
    _infoMessage = null;
    if (_status == AuthViewStatus.awaitingEmailConfirmation ||
        _status == AuthViewStatus.passwordRecovery) {
      _clearAuthenticatedState();
      _status = AuthViewStatus.unauthenticated;
      notifyListeners();
    }
  }

  void clearMessages() {
    if (_errorMessage != null || _infoMessage != null) {
      _errorMessage = null;
      _infoMessage = null;
      notifyListeners();
    }
  }

  Future<void> _handleGatewayEvent(AuthGatewayEvent event) async {
    final gateway = this.gateway;
    if (gateway == null) return;

    switch (event.kind) {
      case AuthEventKind.signedOut:
        if (_isBusy) return;
        ++_authEpoch;
        _clearAuthenticatedState();
        _status = AuthViewStatus.unauthenticated;
        notifyListeners();
      case AuthEventKind.passwordRecovery:
        ++_authEpoch;
        _clearAuthenticatedState();
        _errorMessage = null;
        _infoMessage = 'Defina sua nova senha para concluir a recuperação.';
        _status = AuthViewStatus.passwordRecovery;
        notifyListeners();
      case AuthEventKind.sessionError:
        ++_authEpoch;
        _clearAuthenticatedState();
        _status = AuthViewStatus.unauthenticated;
        _errorMessage =
            event.errorMessage ??
            'Link ou sessão de autenticação inválido ou expirado.';
        notifyListeners();
      case AuthEventKind.authenticated:
        if (_isBusy || _status == AuthViewStatus.passwordRecovery) {
          return;
        }
        final epoch = ++_authEpoch;
        try {
          final profile = await gateway.fetchCurrentProfile();
          if (epoch != _authEpoch) return;
          _setAuthenticatedProfile(profile);
          notifyListeners();
        } on AuthFailure catch (failure) {
          if (epoch != _authEpoch) return;
          await gateway.signOut();
          _clearAuthenticatedState();
          _status = AuthViewStatus.unauthenticated;
          _errorMessage = failure.message;
          notifyListeners();
        }
    }
  }

  void _setAuthenticatedProfile(UserProfile profile) {
    _profile = profile;
    _status = switch (profile.role) {
      UserRole.student => AuthViewStatus.authenticatedStudent,
      UserRole.reviewer => AuthViewStatus.authenticatedReviewer,
    };
  }

  void _clearAuthenticatedState() {
    _profile = null;
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
