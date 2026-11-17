import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Configuração pública de conexão com o Supabase injetada via `--dart-define`.
///
/// Nunca utilize `service_role`, senhas administrativas ou chaves secretas aqui.
class SupabaseConfig {
  const SupabaseConfig({required this.url, required this.publishableKey});

  factory SupabaseConfig.fromEnvironment() {
    const rawUrl = String.fromEnvironment('SUPABASE_URL');
    const rawPublishable = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    const rawAnonFallback = String.fromEnvironment('SUPABASE_ANON_KEY');
    final key = rawPublishable.trim().isNotEmpty
        ? rawPublishable.trim()
        : rawAnonFallback.trim();
    return SupabaseConfig(url: rawUrl.trim(), publishableKey: key);
  }

  static const String androidAuthCallbackUrl =
      'estagiosempendencia://auth/callback';

  static final RegExp _rfc3986SchemePattern = RegExp(
    r'^[a-zA-Z][a-zA-Z0-9+.-]*$',
  );

  static bool isValidCallbackUri(String rawUri) {
    final uri = Uri.tryParse(rawUri);
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      return false;
    }
    return _rfc3986SchemePattern.hasMatch(uri.scheme);
  }

  final String url;
  final String publishableKey;

  Uri? get parsedUri => Uri.tryParse(url);

  bool get isConfigured {
    final uri = parsedUri;
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      return false;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return false;
    }
    return publishableKey.isNotEmpty;
  }

  bool get isLoopbackHost {
    final host = parsedUri?.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost';
  }

  bool get isAndroidLoopbackWarning =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      isLoopbackHost;

  /// URL de retorno usada em links de confirmação de e-mail e redefinição de senha.
  static String? resolveRedirectUrl({Uri? webBaseUri}) {
    if (kIsWeb) {
      final base = webBaseUri ?? Uri.base;
      if (!base.hasScheme || base.host.isEmpty) {
        return null;
      }
      return Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: base.path.isEmpty ? '/' : base.path,
      ).toString();
    }
    return androidAuthCallbackUrl;
  }
}
