enum UserRole {
  student('student'),
  reviewer('reviewer');

  const UserRole(this.value);

  final String value;

  static UserRole fromDatabase(String raw) {
    return switch (raw) {
      'student' => UserRole.student,
      'reviewer' => UserRole.reviewer,
      _ => throw FormatException('Papel de usuário desconhecido: $raw'),
    };
  }
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.role,
    required this.active,
    this.fullName,
  });

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      id: map['id'] as String,
      email: map['email'] as String,
      fullName: map['full_name'] as String?,
      role: UserRole.fromDatabase(map['role'] as String),
      active: (map['active'] as bool?) ?? false,
    );
  }

  final String id;
  final String email;
  final String? fullName;
  final UserRole role;
  final bool active;

  String get displayName {
    final trimmed = fullName?.trim() ?? '';
    return trimmed.isNotEmpty ? trimmed : email;
  }
}

class AuthFailure implements Exception {
  const AuthFailure(this.message, {this.isSessionInvalid = false});

  final String message;
  final bool isSessionInvalid;

  @override
  String toString() => message;
}
