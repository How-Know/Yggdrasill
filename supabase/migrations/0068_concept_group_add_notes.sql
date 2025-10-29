-- concept_group에 노트 컬럼 추가 (정리, 명제, 공식 등)

alter table concept_group
add column if not exists notes text[] default '{}';

comment on column concept_group.notes is '중요하지 않은 정리, 명제, 공식 등을 저장';

