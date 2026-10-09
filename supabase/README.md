# Preparação para Supabase

Nenhum projeto Supabase é configurado nesta task. A sprint correspondente deverá versionar migrations SQL em `migrations/`, aplicar RLS a todas as tabelas acessíveis pelo cliente e usar Storage privado para documentos.

Valores públicos poderão ser enviados por `--dart-define`; como podem integrar o cliente, nunca inclua `service_role`, senhas de banco ou segredos administrativos. Desenvolvimento e homologação deverão usar configurações separadas e dados fictícios.
