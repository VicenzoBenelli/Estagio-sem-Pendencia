-- Gate E3-BE-FIX: Compatibilidade da policy SELECT em storage.objects com Supabase Cloud Storage (v1.96.4).
-- Causa raiz: no ambiente gerenciado do Supabase Cloud, GET /storage/v1/object/authenticated/...
-- executa o fluxo /object/info/authenticated/... emitindo storage.operation = 'object.get_authenticated_info',
-- rejeitado pela comparação única storage.allow_only_operation('object.get_authenticated') da migration 20261118000700.
-- Correção aditiva sem editar migrations anteriores: atualiza exclusivamente a expressão USING
-- para aceitar 'object.get_authenticated' e 'object.get_authenticated_info' via storage.allow_any_operation(text[]),
-- preservando todas as travas de bucket privado, papel authenticated, auth.uid(), posse, escopo ativo de revisor,
-- arquivamento, exclusão e bloqueio estrito de signed URLs, listagens, rotas públicas e HEAD.

alter policy internship_documents_select_authorized
  on storage.objects
  using (
    bucket_id = 'internship-documents'
    and auth.uid() is not null
    and storage.allow_any_operation(array[
      'object.get_authenticated',
      'object.get_authenticated_info'
    ])
    and storage.objects.archived_at is null
    and storage.objects.is_delete_marker = false
    and exists (
      select 1
      from public.document_submissions as ds
      join public.internship_processes as ip
        on ip.id = ds.process_id
      where ds.storage_bucket = storage.objects.bucket_id
        and ds.storage_path = storage.objects.name
        and (
          ip.owner_id = auth.uid()
          or public.is_assigned_reviewer(
            ip.institution_id,
            ip.course_id,
            ip.course_modality_id
          )
        )
    )
  );
