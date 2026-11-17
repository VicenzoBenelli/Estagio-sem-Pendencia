import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/supabase_config.dart';
import 'features/auth/application/auth_controller.dart';
import 'features/auth/data/supabase_auth_gateway.dart';
import 'features/processes/data/supabase_process_repository.dart';
import 'features/processes/domain/process_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = SupabaseConfig.fromEnvironment();
  AuthController authController;
  ProcessRepository? processRepository;

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
    final client = Supabase.instance.client;
    authController = AuthController(
      gateway: SupabaseAuthGateway(client, config: config),
    );
    processRepository = SupabaseProcessRepository(client);
  } else {
    authController = AuthController(gateway: null);
  }

  await authController.initialize();

  runApp(
    EstagioSemPendenciaApp(
      authController: authController,
      processRepository: processRepository,
    ),
  );
}
