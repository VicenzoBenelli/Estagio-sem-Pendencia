# Estagio-sem-Pendencia

MVP acadêmico para organização e acompanhamento documental de estágios curriculares obrigatórios em cursos de tecnologia.

> A ferramenta não concede autorização institucional de estágio. Curso piloto e regras documentais ainda dependem de validação institucional.

## Tecnologias

Flutter 3.47.3, Dart 3.13.3, Android/Kotlin, Flutter Web, Supabase planejado e GitHub Actions. O application ID Android provisório é `br.com.estagiosempendencia.estagio_sem_pendencia`; o prefixo não comprova posse de domínio.

## Ambiente e execução

Instale Flutter 3.47.3, Android Studio e Android SDK. Abra `Mobile/` como projeto Flutter no Android Studio ou execute:

```powershell
flutter pub get
flutter run
```

Para Web, use `flutter run -d chrome` quando o Chrome estiver reconhecido pelo `flutter doctor`.

O módulo Android usa `Mobile/android/` como raiz Gradle. Abra essa pasta separadamente apenas para diagnósticos nativos; não execute `gradle init` na raiz Flutter. A sincronização Gradle foi concluída com sucesso nesta máquina. A propriedade `android.overridePathCheck=true` em `android/gradle.properties` é um contorno local para este caminho Windows com `Área de Trabalho`; não é uma solução universal.

## Qualidade

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build web
flutter build apk --debug
```

`dart analyze` foi aprovado localmente. Nesta instalação, `flutter analyze` é afetado por uma regressão de comunicação LSP do Flutter 3.47.3 em caminho com caracteres Unicode (`FormatException: Unexpected end of input`); acompanhe [flutter/flutter#191309](https://github.com/flutter/flutter/issues/191309). O comando permanece no GitHub Actions e a execução remota ainda não foi validada.

## Estrutura e Git

`lib/app` contém composição e tema, `lib/core` reúne utilitários pequenos e `lib/features` agrupa funcionalidades por domínio. `supabase` contém apenas convenções para a integração futura; `docs` reúne arquitetura e fluxo Git.

O fluxo é `branch individual -> homolog -> main`, sempre por Pull Request revisado. Consulte [docs/WORKFLOW_GITHUB.md](docs/WORKFLOW_GITHUB.md).

## Limites atuais

Esta fundação possui somente uma tela estática responsiva e seu teste. Não implementa autenticação, processos, checklist, upload, dashboard, Supabase ou regras documentais.
