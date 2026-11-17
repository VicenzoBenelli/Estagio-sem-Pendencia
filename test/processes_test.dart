import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:estagio_sem_pendencia/app/app.dart';
import 'package:estagio_sem_pendencia/features/auth/application/auth_controller.dart';
import 'package:estagio_sem_pendencia/features/auth/domain/auth_gateway.dart';
import 'package:estagio_sem_pendencia/features/auth/domain/user_profile.dart';
import 'package:estagio_sem_pendencia/features/processes/application/process_controller.dart';
import 'package:estagio_sem_pendencia/features/processes/data/supabase_process_repository.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/process_models.dart';
import 'package:estagio_sem_pendencia/features/processes/domain/process_repository.dart';

class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway({this.restoredProfile});

  final StreamController<AuthGatewayEvent> _events =
      StreamController<AuthGatewayEvent>.broadcast();

  UserProfile? restoredProfile;
  UserProfile? signInProfile;
  int signOutCalls = 0;

  @override
  bool get hasCurrentSession => restoredProfile != null;

  @override
  Stream<AuthGatewayEvent> get onAuthEvents => _events.stream;

  Future<void> dispose() => _events.close();

  @override
  Future<UserProfile?> restoreAndValidateSession() async => restoredProfile;

  @override
  Future<UserProfile> fetchCurrentProfile() async =>
      restoredProfile ?? signInProfile!;

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    return const SignUpOutcome(requiresEmailConfirmation: true);
  }

  @override
  Future<UserProfile> signIn({
    required String email,
    required String password,
  }) async {
    restoredProfile = signInProfile;
    return signInProfile!;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    restoredProfile = null;
    _events.add(const AuthGatewayEvent(kind: AuthEventKind.signedOut));
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {}

  @override
  Future<void> updatePassword({required String newPassword}) async {}
}

class _FakeProcessRepository implements ProcessRepository {
  _FakeProcessRepository({
    List<InternshipProcessSummary>? initialProcesses,
    List<CatalogModalityOption>? initialCatalog,
    Map<String, ProcessDetailBundle?>? detailsByProcessId,
  }) : processes = List<InternshipProcessSummary>.from(
         initialProcesses ?? const <InternshipProcessSummary>[],
       ),
       catalog = List<CatalogModalityOption>.from(
         initialCatalog ?? const <CatalogModalityOption>[],
       ),
       details = Map<String, ProcessDetailBundle?>.from(
         detailsByProcessId ?? const <String, ProcessDetailBundle?>{},
       );

  List<InternshipProcessSummary> processes;
  List<CatalogModalityOption> catalog;
  Map<String, ProcessDetailBundle?> details;

  Object? fetchProcessesError;
  Object? fetchCatalogError;
  Object? createProcessError;
  Object? fetchDetailError;

  Completer<List<InternshipProcessSummary>>? pendingFetchProcesses;
  final List<Completer<List<InternshipProcessSummary>>>
  pendingFetchProcessesQueue = <Completer<List<InternshipProcessSummary>>>[];
  Completer<List<CatalogModalityOption>>? pendingFetchCatalog;
  Completer<InternshipProcessSummary>? pendingCreateProcess;

  int fetchProcessesCalls = 0;
  int fetchCatalogCalls = 0;
  int createProcessCalls = 0;
  int fetchDetailCalls = 0;
  String? lastCreatedModalityId;

  InternshipProcessSummary Function(String modalityId)? onCreateSuccess;

  @override
  Future<List<CatalogModalityOption>> fetchActiveCatalog() async {
    fetchCatalogCalls++;
    if (pendingFetchCatalog != null) {
      return pendingFetchCatalog!.future;
    }
    if (fetchCatalogError != null) {
      throw fetchCatalogError!;
    }
    return List<CatalogModalityOption>.from(catalog);
  }

  @override
  Future<List<InternshipProcessSummary>> fetchStudentProcesses() async {
    fetchProcessesCalls++;
    if (pendingFetchProcessesQueue.isNotEmpty) {
      return pendingFetchProcessesQueue.removeAt(0).future;
    }
    if (pendingFetchProcesses != null) {
      return pendingFetchProcesses!.future;
    }
    if (fetchProcessesError != null) {
      throw fetchProcessesError!;
    }
    return List<InternshipProcessSummary>.from(processes);
  }

  @override
  Future<InternshipProcessSummary> createProcess({
    required String courseModalityId,
  }) async {
    createProcessCalls++;
    lastCreatedModalityId = courseModalityId;

    if (pendingCreateProcess != null) {
      return pendingCreateProcess!.future;
    }
    if (createProcessError != null) {
      throw createProcessError!;
    }

    final created = onCreateSuccess != null
        ? onCreateSuccess!(courseModalityId)
        : _buildSampleProcess(
            id: 'proc-created-1',
            courseModalityId: courseModalityId,
            templateVersion: 1,
          );
    processes = <InternshipProcessSummary>[created, ...processes];
    details.putIfAbsent(
      created.id,
      () => _buildSampleDetailBundle(process: created),
    );
    return created;
  }

  @override
  Future<ProcessDetailBundle?> fetchProcessDetail({
    required String processId,
  }) async {
    fetchDetailCalls++;
    if (fetchDetailError != null) {
      throw fetchDetailError!;
    }
    return details[processId];
  }
}

const UserProfile _studentA = UserProfile(
  id: 'student-a',
  email: 'estudante.a@demo.local',
  fullName: 'Estudante A Fictício',
  role: UserRole.student,
  active: true,
);

const UserProfile _studentB = UserProfile(
  id: 'student-b',
  email: 'estudante.b@demo.local',
  fullName: 'Estudante B Fictício',
  role: UserRole.student,
  active: true,
);

const UserProfile _reviewerR1 = UserProfile(
  id: 'reviewer-r1',
  email: 'revisor.r1@demo.local',
  fullName: 'Revisor R1 Fictício',
  role: UserRole.reviewer,
  active: true,
);

const CatalogInstitution _demoInst = CatalogInstitution(
  id: '10000000-0000-4000-8000-000000000001',
  code: 'INST_DEMO',
  name: 'Instituição Fictícia de Demonstração (MVP)',
  isDemo: true,
  active: true,
);

const CatalogCourse _demoCourse1 = CatalogCourse(
  id: '20000000-0000-4000-8000-000000000001',
  institutionId: '10000000-0000-4000-8000-000000000001',
  code: 'TEC_DEMO',
  name: 'Curso Piloto de Tecnologia Fictício (Demonstração)',
  isDemo: true,
  active: true,
  institution: _demoInst,
);

const CatalogCourse _demoCourse2 = CatalogCourse(
  id: '20000000-0000-4000-8000-000000000002',
  institutionId: '10000000-0000-4000-8000-000000000001',
  code: 'ADS_DEMO',
  name: 'Segundo Curso Fictício (Demonstração)',
  isDemo: true,
  active: true,
  institution: _demoInst,
);

const CatalogModalityOption _modalityWithPublishedTemplate =
    CatalogModalityOption(
      id: '30000000-0000-4000-8000-000000000001',
      courseId: '20000000-0000-4000-8000-000000000001',
      code: 'ESTAGIO_OBRIG_DEMO',
      name: 'Estágio Curricular Obrigatório Fictício (Demonstração)',
      isMandatory: true,
      isDemo: true,
      active: true,
      course: _demoCourse1,
      publishedTemplate: PublishedTemplateSummary(
        id: '40000000-0000-4000-8000-000000000001',
        version: 1,
        title: 'Checklist Fictício de Demonstração v1 (Não Oficial)',
        sourceReference: 'Catálogo fictício de demonstração do MVP; não representa norma oficial do UNIPÊ.',
        status: 'published',
        isDemo: true,
      ),
    );

const CatalogModalityOption _modalityWithoutPublishedTemplate =
    CatalogModalityOption(
      id: '30000000-0000-4000-8000-000000000002',
      courseId: '20000000-0000-4000-8000-000000000002',
      code: 'ESTAGIO_SEM_TPL',
      name: 'Modalidade Fictícia Sem Template Publicado',
      isMandatory: true,
      isDemo: true,
      active: true,
      course: _demoCourse2,
      publishedTemplate: null,
    );

InternshipProcessSummary _buildSampleProcess({
  String id = 'proc-1',
  String ownerId = 'student-a',
  String courseModalityId = '30000000-0000-4000-8000-000000000001',
  int templateVersion = 1,
  ProcessStatus status = ProcessStatus.inProgress,
  ProcessProgressSummary? progress,
}) {
  return InternshipProcessSummary(
    id: id,
    ownerId: ownerId,
    institutionId: _demoInst.id,
    courseId: _demoCourse1.id,
    courseModalityId: courseModalityId,
    templateId: '40000000-0000-4000-8000-000000000001',
    templateVersion: templateVersion,
    status: status,
    isDemo: true,
    openedAt: DateTime(2026, 11, 17, 10, 30),
    createdAt: DateTime(2026, 11, 17, 10, 30),
    updatedAt: DateTime(2026, 11, 17, 10, 30),
    institutionName: _demoInst.name,
    institutionCode: _demoInst.code,
    courseName: _demoCourse1.name,
    courseCode: _demoCourse1.code,
    modalityName: _modalityWithPublishedTemplate.name,
    modalityCode: _modalityWithPublishedTemplate.code,
    isMandatoryModality: true,
    templateTitle: 'Checklist Fictício de Demonstração v$templateVersion',
    templateSourceReference: 'Catálogo fictício de demonstração do MVP; não representa norma oficial.',
    progress:
        progress ??
        ProcessProgressSummary(
          processId: id,
          ownerId: ownerId,
          processStatus: status,
          requiredTotal: 2,
          requiredApproved: 0,
          requiredUnderReview: 0,
          requiredCorrectionRequested: 0,
          progressStatus: ProgressStatus.inProgress,
          progressPercentage: 0.0,
        ),
  );
}

ProcessDetailBundle _buildSampleDetailBundle({
  required InternshipProcessSummary process,
  ProcessProgressSummary? progressOverride,
  List<ProcessRequirementItem>? requirementsOverride,
}) {
  final requirements =
      requirementsOverride ??
      <ProcessRequirementItem>[
        ProcessRequirementItem(
          id: 'req-1',
          processId: process.id,
          templateItemId: '50000000-0000-4000-8000-000000000001',
          code: 'DEMO_REQ_OBRIG_01',
          title: '[Demonstração] Termo de Compromisso Fictício',
          description: 'Item fictício obrigatório para demonstração do MVP.',
          acceptanceCriteria: 'PDF fictício legível para validação.',
          isRequired: true,
          displayOrder: 1,
          status: RequirementStatus.notSubmitted,
          currentVersion: 0,
          createdAt: DateTime(2026, 11, 17, 10, 30),
          updatedAt: DateTime(2026, 11, 17, 10, 30),
        ),
        ProcessRequirementItem(
          id: 'req-2',
          processId: process.id,
          templateItemId: '50000000-0000-4000-8000-000000000002',
          code: 'DEMO_REQ_OBRIG_02',
          title: '[Demonstração] Plano de Atividades Fictício',
          description: 'Segundo item fictício obrigatório.',
          acceptanceCriteria: 'PDF fictício legível com plano exemplificativo.',
          isRequired: true,
          displayOrder: 2,
          status: RequirementStatus.underReview,
          currentSubmissionId: 'sub-v2',
          currentVersion: 2,
          createdAt: DateTime(2026, 11, 17, 10, 30),
          updatedAt: DateTime(2026, 11, 17, 10, 30),
        ),
        ProcessRequirementItem(
          id: 'req-3',
          processId: process.id,
          templateItemId: '50000000-0000-4000-8000-000000000003',
          code: 'DEMO_REQ_OPC_01',
          title: '[Demonstração] Documento Complementar Opcional Fictício',
          description: 'Item fictício opcional que não bloqueia conclusão.',
          acceptanceCriteria: 'PDF fictício opcional.',
          isRequired: false,
          displayOrder: 3,
          status: RequirementStatus.approved,
          currentSubmissionId: 'sub-opt-v1',
          currentVersion: 1,
          createdAt: DateTime(2026, 11, 17, 10, 30),
          updatedAt: DateTime(2026, 11, 17, 10, 30),
        ),
      ];

  return ProcessDetailBundle(
    process: process,
    requirements: requirements,
    progress: progressOverride ?? process.progress,
  );
}

void main() {
  group('Modelos e mapeamento seguro de erros PostgREST (ESP-10/11/12)', () {
    test('mapError traduz todos os códigos PostgREST sem expor SQL cru', () {
      final err42501 = SupabaseProcessRepository.mapError(
        const PostgrestException(
          message: 'permission denied for function create_internship_process',
          code: '42501',
        ),
      );
      expect(err42501.code, '42501');
      expect(err42501.isUnauthorized, isTrue);
      expect(err42501.message, contains('Acesso não autorizado'));
      expect(err42501.message, isNot(contains('permission denied')));

      final err22023 = SupabaseProcessRepository.mapError(
        const PostgrestException(
          message: 'invalid parameter value',
          code: '22023',
        ),
      );
      expect(err22023.code, '22023');
      expect(err22023.message, contains('modalidade de estágio válida'));

      final errP0002 = SupabaseProcessRepository.mapError(
        const PostgrestException(message: 'no_data_found', code: 'P0002'),
      );
      expect(errP0002.code, 'P0002');
      expect(errP0002.isNotFoundOrInaccessible, isTrue);
      expect(errP0002.message, contains('não foi encontrada'));

      final err23505 = SupabaseProcessRepository.mapError(
        const PostgrestException(
          message: 'duplicate key value violates unique constraint',
          code: '23505',
        ),
      );
      expect(err23505.code, '23505');
      expect(err23505.isConflict, isTrue);
      expect(err23505.message, contains('Já existe um processo ativo'));

      final err23514 = SupabaseProcessRepository.mapError(
        const PostgrestException(
          message: 'check constraint violation',
          code: '23514',
        ),
      );
      expect(err23514.code, '23514');
      expect(
        err23514.message,
        contains('Catálogo ou checklist publicado indisponível'),
      );

      final errPgrst202 = SupabaseProcessRepository.mapError(
        const PostgrestException(
          message: 'Could not find the function in the schema cache',
          code: 'PGRST202',
        ),
      );
      expect(errPgrst202.code, 'PGRST202');
      expect(errPgrst202.message, contains('incompatível'));
    });

    test(
      'InternshipProcessSummary trata relacionamentos nulos com segurança',
      () {
        final summary = InternshipProcessSummary.fromMap(<String, dynamic>{
          'id': 'proc-null-rel',
          'owner_id': 'student-a',
          'institution_id': 'inst-1',
          'course_id': 'course-1',
          'course_modality_id': 'mod-1',
          'template_id': 'tpl-1',
          'template_version': 2,
          'status': 'in_progress',
          'is_demo': true,
          'opened_at': '2026-11-17T12:00:00Z',
          'created_at': '2026-11-17T12:00:00Z',
          'updated_at': '2026-11-17T12:00:00Z',
          'institutions': null,
          'courses': null,
          'course_modalities': null,
          'requirement_templates': null,
        });

        expect(
          summary.displayInstitutionName,
          'Instituição vinculada ao processo',
        );
        expect(summary.displayCourseName, 'Curso vinculado ao processo');
        expect(summary.displayModalityName, 'Modalidade vinculada ao processo');
        expect(summary.displayTemplateTitle, 'Checklist v2');
      },
    );
  });

  group('Painel de Processos, Abertura e Checklist (ESP-10 / ESP-11 / ESP-12)', () {
    testWidgets(
      '1, 2 e 3: estudante autenticado acessa painel com loading, erro, retry e estado vazio',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final pendingList = Completer<List<InternshipProcessSummary>>();
        final processRepo = _FakeProcessRepository()
          ..pendingFetchProcesses = pendingList;

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pump();

        // 1 & 3: Loading state
        expect(find.text('Meus processos de estágio'), findsOneWidget);
        expect(find.text('Carregando processos de estágio...'), findsOneWidget);

        // Falha na primeira chamada -> estado de erro com retry
        pendingList.completeError(
          const ProcessFailure(
            'Não foi possível conectar ao servidor. Verifique sua conexão e tente novamente.',
            code: 'network_error',
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Não foi possível conectar ao servidor'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('processes_retry_button')), findsOneWidget);

        // Retry retorna lista vazia -> 2: Empty state renderizado corretamente
        processRepo.pendingFetchProcesses = null;
        processRepo.processes = const <InternshipProcessSummary>[];
        await tester.tap(find.byKey(const Key('processes_retry_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('processes_empty_state')), findsOneWidget);
        expect(find.text('Nenhum processo de estágio aberto'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '4, 5, 6 e 17: formulário em layout compacto sem overflow, seleção de catálogo e bloqueio quando falta template publicado',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final processRepo = _FakeProcessRepository(
          initialCatalog: <CatalogModalityOption>[
            _modalityWithPublishedTemplate,
            _modalityWithoutPublishedTemplate,
          ],
        );

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        // 17: Layout compacto estreito (360x800)
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('open_create_process_button')),
        );
        await tester.tap(find.byKey(const Key('open_create_process_button')));
        await tester.pumpAndSettle();

        expect(processRepo.fetchCatalogCalls, 1);
        expect(find.text('Abrir novo processo de estágio'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Selecionar curso 2 (que possui modalidade SEM template publicado)
        final courseDropdown = find.byKey(
          ValueKey('select_course_${_demoInst.id}'),
        );
        await tester.ensureVisible(courseDropdown);
        await tester.tap(courseDropdown);
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('Segundo Curso Fictício (Demonstração)').last,
        );
        await tester.pumpAndSettle();

        // 6: Ausência de template publicado exibe alerta e desabilita abertura
        expect(
          find.byKey(const Key('missing_template_warning')),
          findsOneWidget,
        );
        expect(find.textContaining('Configuração pendente'), findsOneWidget);
        final submitButtonDisabled = tester.widget<FilledButton>(
          find.byKey(const Key('submit_create_process_button')),
        );
        expect(submitButtonDisabled.onPressed, isNull);

        // 5: Selecionar curso 1 (que possui template publicado v1)
        await tester.ensureVisible(courseDropdown);
        await tester.tap(courseDropdown);
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('Curso Piloto de Tecnologia Fictício (Demonstração)').last,
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('published_template_info_card')),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Checklist Fictício de Demonstração v1 (Não Oficial) (v1)',
          ),
          findsOneWidget,
        );
        final submitButtonEnabled = tester.widget<FilledButton>(
          find.byKey(const Key('submit_create_process_button')),
        );
        expect(submitButtonEnabled.onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '7 e 8: duplo clique não dispara duas RPCs e abertura bem-sucedida abre detalhes e atualiza painel',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final createCompleter = Completer<InternshipProcessSummary>();
        final processRepo = _FakeProcessRepository(
          initialCatalog: <CatalogModalityOption>[
            _modalityWithPublishedTemplate,
          ],
        )..pendingCreateProcess = createCompleter;

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('open_create_process_button')));
        await tester.pumpAndSettle();

        final submitFinder = find.byKey(
          const Key('submit_create_process_button'),
        );
        await tester.ensureVisible(submitFinder);

        // Primeiro clique inicia a RPC; segundo clique imediato é ignorado
        await tester.tap(submitFinder);
        await tester.pump();
        await tester.tap(submitFinder, warnIfMissed: false);
        await tester.pump();

        expect(processRepo.createProcessCalls, 1);
        expect(
          processRepo.lastCreatedModalityId,
          _modalityWithPublishedTemplate.id,
        );
        expect(find.text('Abrindo...'), findsOneWidget);

        // Concluir RPC e verificar navegação para detalhes + atualização do painel
        final createdProcess = _buildSampleProcess(
          id: 'proc-new-100',
          templateVersion: 1,
        );
        processRepo.processes = <InternshipProcessSummary>[createdProcess];
        processRepo.details[createdProcess.id] = _buildSampleDetailBundle(
          process: createdProcess,
        );
        createCompleter.complete(createdProcess);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('process_template_version_label')),
          findsOneWidget,
        );
        expect(find.text('Versão do template: v1'), findsOneWidget);
        expect(
          find.textContaining('[Demonstração] Termo de Compromisso Fictício'),
          findsOneWidget,
        );

        // Voltar para painel e verificar que processo está listado e pode ser reaberto (10)
        await tester.ensureVisible(find.byKey(const Key('detail_back_button')));
        await tester.tap(find.byKey(const Key('detail_back_button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(Key('process_card_${createdProcess.id}')),
          findsOneWidget,
        );
        final detailBtn = find.byKey(
          Key('open_process_detail_${createdProcess.id}'),
        );
        await tester.ensureVisible(detailBtn);
        await tester.tap(detailBtn);
        await tester.pumpAndSettle();

        expect(find.text('Versão do template: v1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '9: tentativa de abrir processo duplicado (23505) exibe mensagem clara e preserva formulário',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final processRepo =
            _FakeProcessRepository(
                initialCatalog: <CatalogModalityOption>[
                  _modalityWithPublishedTemplate,
                ],
              )
              ..createProcessError = const PostgrestException(
                message: 'duplicate key value violates unique constraint',
                code: '23505',
              );

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('open_create_process_button')));
        await tester.pumpAndSettle();

        final submitBtn = find.byKey(const Key('submit_create_process_button'));
        await tester.ensureVisible(submitBtn);
        await tester.tap(submitBtn);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('create_process_error_banner')),
          findsOneWidget,
        );
        expect(
          find.text(
            'Já existe um processo ativo para este curso e modalidade.',
          ),
          findsOneWidget,
        );
        // Preserva o formulário com a modalidade selecionada
        expect(
          find.byKey(const Key('published_template_info_card')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '10, 11, 12 e 13: detalhes exibem template version, itens obrigatórios/opcionais, versões e progresso indeterminado sem falso 100%',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);

        final processIndeterminate = _buildSampleProcess(
          id: 'proc-indeterminate',
          templateVersion: 2,
          progress: const ProcessProgressSummary(
            processId: 'proc-indeterminate',
            ownerId: 'student-a',
            processStatus: ProcessStatus.inProgress,
            requiredTotal: 0,
            requiredApproved: 0,
            requiredUnderReview: 0,
            requiredCorrectionRequested: 0,
            progressStatus: ProgressStatus.indeterminate,
            progressPercentage: null,
          ),
        );

        final detailBundle = _buildSampleDetailBundle(
          process: processIndeterminate,
          progressOverride: processIndeterminate.progress,
        );

        final processRepo = _FakeProcessRepository(
          initialProcesses: <InternshipProcessSummary>[processIndeterminate],
          detailsByProcessId: <String, ProcessDetailBundle?>{
            processIndeterminate.id: detailBundle,
          },
        );

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(Key('open_process_detail_${processIndeterminate.id}')),
        );
        await tester.pumpAndSettle();

        // 12: Template version v2 exibida
        expect(find.text('Versão do template: v2'), findsOneWidget);

        // 13: Progresso indeterminado não mostra 100%
        expect(
          find.byKey(const Key('progress_indeterminate_label')),
          findsOneWidget,
        );
        expect(find.textContaining('100%'), findsNothing);

        // 11: Requisitos obrigatórios e opcionais, estados traduzidos e versões de submissão
        expect(find.text('Obrigatório'), findsNWidgets(2));
        expect(find.text('Opcional'), findsOneWidget);
        expect(find.text('Não enviado'), findsOneWidget);
        expect(find.text('Em análise'), findsOneWidget);
        expect(find.text('Aprovado'), findsOneWidget);
        expect(
          find.byKey(const Key('requirement_version_DEMO_REQ_OBRIG_02')),
          findsOneWidget,
        );
        expect(find.text('Versão da submissão: v2'), findsOneWidget);
        expect(find.text('Submissão: nenhuma versão enviada'), findsOneWidget);

        // Aviso discreto sobre envio futuro de PDFs e ausência de botão falso de upload
        expect(
          find.byKey(const Key('pdf_upload_future_stage_notice')),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'A conclusão documental não representa autorização oficial de estágio pela instituição de ensino.',
          ),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '14: processo não encontrado ou inacessível pela RLS é tratado de forma neutra sem vazamento',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final proc = _buildSampleProcess(id: 'proc-missing');
        final processRepo = _FakeProcessRepository(
          initialProcesses: <InternshipProcessSummary>[proc],
          detailsByProcessId: <String, ProcessDetailBundle?>{
            'proc-missing': null,
          },
        );

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('open_process_detail_proc-missing')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('process_not_found_view')), findsOneWidget);
        expect(
          find.text('Processo não encontrado ou indisponível para sua conta.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '15 e 16: logout limpa dados privados de processos e perfil revisor não recebe ações de estudante',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final procA = _buildSampleProcess(id: 'proc-student-a');
        final processRepo = _FakeProcessRepository(
          initialProcesses: <InternshipProcessSummary>[procA],
          detailsByProcessId: <String, ProcessDetailBundle?>{
            procA.id: _buildSampleDetailBundle(process: procA),
          },
        );

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pumpAndSettle();

        // Estudante A abre detalhes do seu processo
        final detailFinderA = find.byKey(
          Key('open_process_detail_${procA.id}'),
        );
        await tester.ensureVisible(detailFinderA);
        await tester.tap(detailFinderA);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('[Demonstração] Termo de Compromisso Fictício'),
          findsOneWidget,
        );

        // 15: Logout limpa imediatamente a tela de detalhes e dados privados
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();

        expect(find.text('Entrar na conta'), findsOneWidget);
        expect(
          find.textContaining('[Demonstração] Termo de Compromisso Fictício'),
          findsNothing,
        );
        expect(find.text('Estudante A Fictício'), findsNothing);

        // Novo login como Estudante B não exibe processos de A
        processRepo.processes = const <InternshipProcessSummary>[];
        authGateway.signInProfile = _studentB;
        await tester.enterText(
          find.byKey(const Key('auth_email_field')),
          _studentB.email,
        );
        await tester.enterText(
          find.byKey(const Key('auth_password_field')),
          'SenhaSegura123',
        );
        await tester.tap(find.byKey(const Key('auth_submit_button')));
        await tester.pumpAndSettle();

        expect(find.text('Estudante B Fictício'), findsOneWidget);
        expect(find.byKey(const Key('processes_empty_state')), findsOneWidget);
        expect(find.byKey(Key('process_card_${procA.id}')), findsNothing);

        // Logout de B e login como Revisor R1 -> 16: Revisor não recebe ações de estudante
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();

        authGateway.signInProfile = _reviewerR1;
        await tester.enterText(
          find.byKey(const Key('auth_email_field')),
          _reviewerR1.email,
        );
        await tester.enterText(
          find.byKey(const Key('auth_password_field')),
          'SenhaSegura123',
        );
        await tester.tap(find.byKey(const Key('auth_submit_button')));
        await tester.pumpAndSettle();

        expect(find.text('Perfil Revisor (Escopo Protegido)'), findsOneWidget);
        expect(
          find.byKey(const Key('open_create_process_button')),
          findsNothing,
        );
        expect(find.text('Meus processos de estágio'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Regressão C2-01: ciclo de vida de carregamento e navegação painel <-> formulário', () {
    testWidgets(
      'Cenário A: consulta de listagem pendente ao abrir formulário e voltar conclui com sucesso, habilita atualização e descarta respostas antigas obsoletas',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final initialListCompleter =
            Completer<List<InternshipProcessSummary>>();
        final staleListCompleter = Completer<List<InternshipProcessSummary>>();
        final freshListCompleter = Completer<List<InternshipProcessSummary>>();

        final processRepo = _FakeProcessRepository(
          initialCatalog: <CatalogModalityOption>[
            _modalityWithPublishedTemplate,
          ],
        );
        processRepo.pendingFetchProcessesQueue.addAll(
          <Completer<List<InternshipProcessSummary>>>[
            initialListCompleter,
            staleListCompleter,
            freshListCompleter,
          ],
        );

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pump();

        // 1. Listagem inicial iniciada e mantida pendente
        expect(processRepo.fetchProcessesCalls, 1);
        expect(find.text('Carregando processos de estágio...'), findsOneWidget);
        final refreshWhileLoading = tester.widget<OutlinedButton>(
          find.byKey(const Key('refresh_processes_button')),
        );
        expect(refreshWhileLoading.onPressed, isNull);

        // 2. Navegar para abertura de processo (dispara loadCatalog)
        await tester.tap(find.byKey(const Key('open_create_process_button')));
        await tester.pumpAndSettle();
        expect(find.text('Abrir novo processo de estágio'), findsOneWidget);
        expect(processRepo.fetchCatalogCalls, 1);

        // 3. Retornar ao painel enquanto a consulta inicial ainda está pendente
        await tester.tap(find.byKey(const Key('back_to_processes_button')));
        await tester.pump();
        expect(find.text('Carregando processos de estágio...'), findsOneWidget);
        expect(processRepo.fetchProcessesCalls, 1);

        // 4. Concluir a consulta inicial com estado vazio
        initialListCompleter.complete(const <InternshipProcessSummary>[]);
        await tester.pumpAndSettle();

        // 6 & 7. Estado vazio renderizado, loading encerrado e botão Atualizar habilitado
        expect(find.text('Carregando processos de estágio...'), findsNothing);
        expect(find.byKey(const Key('processes_empty_state')), findsOneWidget);
        final refreshAfterInitial = tester.widget<OutlinedButton>(
          find.byKey(const Key('refresh_processes_button')),
        );
        expect(refreshAfterInitial.onPressed, isNotNull);

        // Validar também que se uma consulta antiga competir com uma consulta mais recente,
        // a antiga não sobrescreve os dados da consulta atual:
        await tester.tap(find.byKey(const Key('refresh_processes_button')));
        await tester.pump();
        expect(processRepo.fetchProcessesCalls, 2);

        // Abrir formulário, voltar e disparar nova consulta mais recente (3ª chamada)
        await tester.tap(find.byKey(const Key('open_create_process_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('back_to_processes_button')));
        await tester.pump();

        // Concluir a 2ª consulta (antiga) DEPOIS que uma 3ª consulta foi iniciada:
        final staleProc = _buildSampleProcess(id: 'proc-stale');
        final freshProc = _buildSampleProcess(id: 'proc-fresh');
        // Iniciar 3ª consulta explicitamente via loadDashboard na próxima ação após falha/conclusão:
        staleListCompleter.complete(<InternshipProcessSummary>[staleProc]);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('process_card_proc-stale')),
          findsOneWidget,
        );

        // Agora testar concorrência direta de duas chamadas loadDashboard onde a 1ª termina antes da 2ª
        final controllerDirect = ProcessController(repository: processRepo);
        addTearDown(controllerDirect.dispose);
        final cOld = Completer<List<InternshipProcessSummary>>();
        final cNew = Completer<List<InternshipProcessSummary>>();
        processRepo.pendingFetchProcessesQueue
          ..clear()
          ..addAll(<Completer<List<InternshipProcessSummary>>>[cOld, cNew]);

        final f1 = controllerDirect.loadDashboard();
        final f2 = controllerDirect.loadDashboard();
        cOld.complete(<InternshipProcessSummary>[staleProc]);
        await f1;
        // Enquanto cNew não terminou, ainda está loading e não aceitou staleProc
        expect(controllerDirect.listStatus, ProcessLoadStatus.loading);
        expect(controllerDirect.processes, isEmpty);

        cNew.complete(<InternshipProcessSummary>[freshProc]);
        await f2;
        expect(controllerDirect.listStatus, ProcessLoadStatus.loaded);
        expect(controllerDirect.processes.map((p) => p.id).toList(), <String>[
          'proc-fresh',
        ]);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Cenário B: consulta de listagem pendente ao abrir formulário e voltar que falha apresenta erro e permite retry funcional',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final failingListCompleter =
            Completer<List<InternshipProcessSummary>>();
        final recoveredProc = _buildSampleProcess(id: 'proc-recovered');

        final processRepo = _FakeProcessRepository(
          initialProcesses: <InternshipProcessSummary>[recoveredProc],
          initialCatalog: <CatalogModalityOption>[
            _modalityWithPublishedTemplate,
          ],
        )..pendingFetchProcesses = failingListCompleter;

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pump();

        // 1. Navegar para abertura de processo e retornar ao painel enquanto pendente
        await tester.tap(find.byKey(const Key('open_create_process_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('back_to_processes_button')));
        await tester.pump();

        expect(find.text('Carregando processos de estágio...'), findsOneWidget);

        // 2. Fazer a consulta pendente falhar
        failingListCompleter.completeError(
          const ProcessFailure(
            'Não foi possível conectar ao servidor. Verifique sua conexão e tente novamente.',
            code: 'network_error',
          ),
        );
        await tester.pumpAndSettle();

        // 3. Loading encerrado, erro apresentado, botões de retry e atualização disponíveis
        expect(find.text('Carregando processos de estágio...'), findsNothing);
        expect(
          find.textContaining('Não foi possível conectar ao servidor'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('processes_retry_button')), findsOneWidget);
        final refreshOnError = tester.widget<OutlinedButton>(
          find.byKey(const Key('refresh_processes_button')),
        );
        expect(refreshOnError.onPressed, isNotNull);

        // 4. Retry funcional carrega os processos com sucesso
        processRepo.pendingFetchProcesses = null;
        await tester.tap(find.byKey(const Key('processes_retry_button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(Key('process_card_${recoveredProc.id}')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Cenário C: logout ou dispose durante requisições pendentes descarta respostas antigas sem vazar dados nem notificar após dispose',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final pendingListA = Completer<List<InternshipProcessSummary>>();
        final pendingCatalogA = Completer<List<CatalogModalityOption>>();
        final secretProcA = _buildSampleProcess(id: 'proc-secret-a');

        final processRepo = _FakeProcessRepository()
          ..pendingFetchProcesses = pendingListA
          ..pendingFetchCatalog = pendingCatalogA;

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pump();

        // Navegar para abertura de processo (deixa tanto listagem quanto catálogo pendentes)
        await tester.tap(find.byKey(const Key('open_create_process_button')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('back_to_processes_button')));
        await tester.pump();

        // Executar logout enquanto ambas as requisições da sessão de A estão pendentes
        await tester.tap(find.byKey(const Key('logout_button')));
        await tester.pumpAndSettle();
        expect(find.text('Entrar na conta'), findsOneWidget);

        // Concluir as requisições antigas de A após o logout
        pendingListA.complete(<InternshipProcessSummary>[secretProcA]);
        pendingCatalogA.complete(<CatalogModalityOption>[
          _modalityWithPublishedTemplate,
        ]);
        await tester.pumpAndSettle();

        expect(find.byKey(Key('process_card_${secretProcA.id}')), findsNothing);
        expect(find.text('Estudante A Fictício'), findsNothing);

        // Validar também diretamente no ProcessController que clearPrivateState e dispose
        // impedem qualquer mutação ou notifyListeners tardio:
        final orphanCompleter = Completer<List<InternshipProcessSummary>>();
        processRepo.pendingFetchProcesses = orphanCompleter;
        final directController = ProcessController(repository: processRepo);
        var isControllerDisposed = false;
        var notificationsAfterDispose = 0;
        directController.addListener(() {
          if (isControllerDisposed) {
            notificationsAfterDispose++;
          }
        });
        final pendingFuture = directController.loadDashboard();
        directController.clearPrivateState();
        isControllerDisposed = true;
        directController.dispose();

        orphanCompleter.complete(<InternshipProcessSummary>[secretProcA]);
        await pendingFuture;
        expect(notificationsAfterDispose, 0);
        expect(directController.processes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Cenário D: abrir formulário e voltar ao painel com lista já carregada preserva estado sem recarregamento desnecessário',
      (tester) async {
        final authGateway = _FakeAuthGateway(restoredProfile: _studentA);
        final authController = AuthController(gateway: authGateway);
        final existingProc = _buildSampleProcess(id: 'proc-existing-d');
        final processRepo = _FakeProcessRepository(
          initialProcesses: <InternshipProcessSummary>[existingProc],
          initialCatalog: <CatalogModalityOption>[
            _modalityWithPublishedTemplate,
          ],
        );

        addTearDown(() async {
          authController.dispose();
          await authGateway.dispose();
        });
        await authController.initialize();

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          EstagioSemPendenciaApp(
            authController: authController,
            processRepository: processRepo,
          ),
        );
        await tester.pumpAndSettle();

        expect(processRepo.fetchProcessesCalls, 1);
        expect(
          find.byKey(Key('process_card_${existingProc.id}')),
          findsOneWidget,
        );

        // Abrir formulário e voltar para processos
        await tester.tap(find.byKey(const Key('open_create_process_button')));
        await tester.pumpAndSettle();
        expect(find.text('Abrir novo processo de estágio'), findsOneWidget);

        await tester.tap(find.byKey(const Key('back_to_processes_button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(Key('process_card_${existingProc.id}')),
          findsOneWidget,
        );
        expect(find.text('Carregando processos de estágio...'), findsNothing);
        expect(processRepo.fetchProcessesCalls, 1);
        final refreshButton = tester.widget<OutlinedButton>(
          find.byKey(const Key('refresh_processes_button')),
        );
        expect(refreshButton.onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
