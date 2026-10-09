# Arquitetura inicial

Um projeto Flutter atende Android e Web para compartilhar UI, tema, validações futuras e testes. Kotlin fica restrito à camada Android quando necessária.

- `app`: composição e configuração global;
- `core`: recursos técnicos pequenos e reutilizáveis;
- `features`: módulos de domínio criados somente quando aprovados.

Supabase é planejado para Auth, PostgreSQL, Storage privado, migrations e RLS. Papéis de estudante e revisor não serão autorização por interface: permissões críticas deverão ser aplicadas no backend.

Não foram adicionados gerenciador de estado, roteador externo, injeção de dependência, SDK Supabase, upload ou visualização de PDF, porque a tela estática atual não os justifica.

## Android e compatibilidade local

`Mobile/` é a raiz Flutter; `Mobile/android/` é a raiz Gradle do módulo Android. O projeto deve ser aberto como Flutter no Android Studio, deixando `android/` para diagnósticos nativos isolados. Não crie um build Gradle na raiz Flutter com `gradle init`.

A sincronização Gradle e os builds locais foram concluídos. `android.overridePathCheck=true` preserva a compatibilidade com o caminho Windows atual, que contém `Área de Trabalho`; esse contorno não deve ser generalizado sem nova evidência. O aviso de depreciação de `org.jetbrains.kotlin.android` com AGP 9 não bloqueou a sincronização ou os builds; uma migração deverá ser analisada em tarefa futura.

O critério local do daemon Gradle (Java 25) não foi adotado como requisito do time e permanece fora do versionamento até que a JVM compartilhada seja definida. A análise estática local passou com `dart analyze`; `flutter analyze` apresentou falha de comunicação LSP do Flutter 3.47.3 em caminho Unicode (`FormatException: Unexpected end of input`, [flutter/flutter#191309](https://github.com/flutter/flutter/issues/191309)). O workflow remoto mantém `flutter analyze`, cuja execução ainda não foi comprovada.
