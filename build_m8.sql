with q as (
  select q.id, q.stem, q.is_published, (q.meta->'table_layout') is not null as has_table_layout
  from pb_questions q
  where q.meta ? 'mock_exam_item'
)
select
  count(*) as mock_questions,
  count(*) filter (where stem ~ '\[표시작\]') as with_raw_table,
  count(*) filter (where stem ~ '\[표시작\]' and stem ~ '오른쪽\s*표준정규분포표') as right_normal_table,
  count(*) filter (where stem ~ '\[표시작\]' and stem ~ '오른쪽\s*표준정규분포표' and is_published) as right_normal_table_published,
  count(*) filter (where stem ~ '\[표시작\]' and stem ~ '(오른쪽|왼쪽)' and stem !~ '오른쪽\s*표준정규분포표') as other_side_word_table,
  count(*) filter (where stem ~ '\[표시작\]' and has_table_layout) as table_with_layout,
  count(*) filter (where stem ~ '&\s*\\(text|mathrm)\{[A-Z]+\}\(') as table_cell_upright_fn,
  count(*) filter (where stem ~ '&\s*\\(text|mathrm)\{[A-Z]+\}\(' and is_published) as table_cell_upright_fn_published,
  count(*) filter (where stem ~ '\n\((가|나|다|라)\)\s*[A-Z](와|과|는|은|가|를|의|,)') as box_line_bare_name,
  count(*) filter (where stem ~ '\n\((가|나|다|라)\)\s*[A-Z](와|과|는|은|가|를|의|,)' and is_published) as box_line_bare_name_published
from q;
