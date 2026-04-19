-- VLM 파이프라인 입력용 PDF 도 problem-documents 버킷에 같이 저장하므로
-- 기존 버킷의 allowed_mime_types 에 application/pdf 를 추가한다.
-- 버킷은 on conflict (id) do nothing 으로 생성됐기에, 여기서 보정한다.

update storage.buckets
   set allowed_mime_types = (
     select array(
       select distinct unnest(
         coalesce(allowed_mime_types, array[]::text[])
         || array['application/pdf']
       )
     )
   )
 where id = 'problem-documents';
