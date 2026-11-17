import 'user_profile.dart';

enum AuthEventKind { signedOut, authenticated, passwordRecovery, sessionError }

class AuthGatewayEvent {
  const AuthGatewayEvent({required this.kind, this.errorMessage});

  final AuthEventKind kind;
  final String? errorMessage;
}

class SignUpOutcome {
  const SignUpOutcome({required this.requiresEmailConfirmation, this.profile});

  final bool requiresEmailConfirmation;
  final UserProfile? profile;
}

abstract interface class AuthGateway {
  bool get hasCurrentSession;

  Stream<AuthGatewayEvent> get onAuthEvents;

  Future<UserProfile?> restoreAndValidateSession();

  Future<UserProfile> fetchCurrentProfile();

  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String fullName,
  });

  Future<UserProfile> signIn({required String email, required String password});

  Future<void> signOut();

  Future<void> sendPasswordResetEmail({required String email});

  Future<void> updatePassword({required String newPassword});
}
