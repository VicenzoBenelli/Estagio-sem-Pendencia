import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/supabase_config.dart';
import 'features/auth/application/auth_controller.dart';
import 'features/auth/data/supabase_auth_gateway.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = SupabaseConfig.fromEnvironment();
  AuthController authController;

  if (config.isConfigured) {
    await Supabase.initialize(
      url: config.url,
      publishableKey: config.publishableKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        detectSessionInUri: true,
        persistSession: true,
      ),
    );
    authController = AuthController(
      gateway: SupabaseAuthGateway(Supabase.instance.client, config: config),
    );
  } else {
    authController = AuthController(gateway: null);
  }

  await authController.initialize();

  runApp(EstagioSemPendenciaApp(authController: authController));
}
