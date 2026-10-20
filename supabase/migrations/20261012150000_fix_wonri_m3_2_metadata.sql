-- 개념원리 중3-2에 다른 교육과정 목차가 저장된 데이터를 실제 등록 교재
-- (2015 개정) 목차로 교정한다.
--
-- 기존 크롭 472건은 잘못된 목차 범위로 추출되었고 storage 객체도 모두
-- 사라진 고아 데이터다. 학생 답안/학습 이력이 없는 경우에만 함께 제거한다.

do $$
declare
  v_academy_id constant uuid := '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677';
  v_book_id constant uuid := 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72';
  v_grade constant text := '3-2';
  v_rows integer;
  v_learning_records bigint;
begin
  select
    (select count(*) from public.student_textbook_answer_records
      where book_id = v_book_id and grade_label = v_grade)
    + (select count(*) from public.learning_attempts
      where book_id = v_book_id and grade_label = v_grade)
  into v_learning_records;

  if v_learning_records <> 0 then
    raise exception
      '개념원리 3-2 학습 기록 %건이 있어 고아 크롭을 안전하게 교체할 수 없습니다.',
      v_learning_records;
  end if;

  update public.textbook_metadata
  set payload = jsonb_set(
        payload,
        '{units}',
        $units$
        [
          {
            "name": "삼각비",
            "order_index": 0,
            "middles": [
              {
                "name": "삼각비",
                "order_index": 0,
                "smalls": [
                  {"name":"개념원리 확인하기","sub_key":"A","start_page":8,"end_page":15,"order_index":0,"page_counts":{}},
                  {"name":"핵심문제 익히기","sub_key":"B","start_page":8,"end_page":15,"order_index":1,"page_counts":{}},
                  {"name":"이런 문제가 시험에 나온다","sub_key":"C","start_page":8,"end_page":15,"order_index":2,"page_counts":{}},
                  {"name":"중단원 마무리하기","sub_key":"D","start_page":16,"end_page":21,"order_index":3,"page_counts":{}},
                  {"name":"서술형 대비 문제","sub_key":"E","start_page":16,"end_page":21,"order_index":4,"page_counts":{}}
                ],
                "sub_units": [
                  {"name":"삼각비의 뜻","start_page":8,"end_page":9,"order_index":0},
                  {"name":"특수한 각의 삼각비의 값","start_page":10,"end_page":11,"order_index":1},
                  {"name":"예각의 삼각비의 값","start_page":12,"end_page":15,"order_index":2},
                  {"name":"유형 check · 중단원 마무리","start_page":16,"end_page":21,"order_index":3,"is_exercise":true}
                ]
              },
              {
                "name": "삼각비의 활용",
                "order_index": 1,
                "smalls": [
                  {"name":"개념원리 확인하기","sub_key":"A","start_page":24,"end_page":37,"order_index":0,"page_counts":{}},
                  {"name":"핵심문제 익히기","sub_key":"B","start_page":24,"end_page":37,"order_index":1,"page_counts":{}},
                  {"name":"이런 문제가 시험에 나온다","sub_key":"C","start_page":24,"end_page":37,"order_index":2,"page_counts":{}},
                  {"name":"중단원 마무리하기","sub_key":"D","start_page":38,"end_page":40,"order_index":3,"page_counts":{}},
                  {"name":"서술형 대비 문제","sub_key":"E","start_page":38,"end_page":40,"order_index":4,"page_counts":{}}
                ],
                "sub_units": [
                  {"name":"삼각비의 활용 (1)","start_page":24,"end_page":31,"order_index":0},
                  {"name":"삼각비의 활용 (2)","start_page":32,"end_page":37,"order_index":1},
                  {"name":"중단원 마무리","start_page":38,"end_page":40,"order_index":2,"is_exercise":true}
                ]
              }
            ]
          },
          {
            "name": "원의 성질",
            "order_index": 1,
            "middles": [
              {
                "name": "원과 직선",
                "order_index": 0,
                "smalls": [
                  {"name":"개념원리 확인하기","sub_key":"A","start_page":42,"end_page":51,"order_index":0,"page_counts":{}},
                  {"name":"핵심문제 익히기","sub_key":"B","start_page":42,"end_page":51,"order_index":1,"page_counts":{}},
                  {"name":"이런 문제가 시험에 나온다","sub_key":"C","start_page":42,"end_page":51,"order_index":2,"page_counts":{}},
                  {"name":"중단원 마무리하기","sub_key":"D","start_page":52,"end_page":58,"order_index":3,"page_counts":{}},
                  {"name":"서술형 대비 문제","sub_key":"E","start_page":52,"end_page":58,"order_index":4,"page_counts":{}}
                ],
                "sub_units": [
                  {"name":"원의 현","start_page":42,"end_page":45,"order_index":0},
                  {"name":"원의 접선의 길이","start_page":46,"end_page":47,"order_index":1},
                  {"name":"삼각형의 내접원","start_page":48,"end_page":49,"order_index":2},
                  {"name":"원에 외접하는 사각형","start_page":50,"end_page":51,"order_index":3},
                  {"name":"유형 check · 중단원 마무리","start_page":52,"end_page":58,"order_index":4,"is_exercise":true}
                ]
              },
              {
                "name": "원주각",
                "order_index": 1,
                "smalls": [
                  {"name":"개념원리 확인하기","sub_key":"A","start_page":60,"end_page":75,"order_index":0,"page_counts":{}},
                  {"name":"핵심문제 익히기","sub_key":"B","start_page":60,"end_page":75,"order_index":1,"page_counts":{}},
                  {"name":"이런 문제가 시험에 나온다","sub_key":"C","start_page":60,"end_page":75,"order_index":2,"page_counts":{}},
                  {"name":"중단원 마무리하기","sub_key":"D","start_page":76,"end_page":78,"order_index":3,"page_counts":{}},
                  {"name":"서술형 대비 문제","sub_key":"E","start_page":76,"end_page":78,"order_index":4,"page_counts":{}}
                ],
                "sub_units": [
                  {"name":"원주각과 중심각","start_page":60,"end_page":61,"order_index":0},
                  {"name":"원주각의 크기와 호의 길이","start_page":62,"end_page":67,"order_index":1},
                  {"name":"원과 사각형","start_page":68,"end_page":71,"order_index":2},
                  {"name":"원의 접선과 현이 이루는 각","start_page":72,"end_page":75,"order_index":3},
                  {"name":"중단원 마무리","start_page":76,"end_page":78,"order_index":4,"is_exercise":true}
                ]
              }
            ]
          },
          {
            "name": "통계",
            "order_index": 2,
            "middles": [
              {
                "name": "대푯값과 산포도",
                "order_index": 0,
                "smalls": [
                  {"name":"개념원리 확인하기","sub_key":"A","start_page":80,"end_page":87,"order_index":0,"page_counts":{}},
                  {"name":"핵심문제 익히기","sub_key":"B","start_page":80,"end_page":91,"order_index":1,"page_counts":{}},
                  {"name":"이런 문제가 시험에 나온다","sub_key":"C","start_page":80,"end_page":91,"order_index":2,"page_counts":{}},
                  {"name":"중단원 마무리하기","sub_key":"D","start_page":92,"end_page":94,"order_index":3,"page_counts":{}},
                  {"name":"서술형 대비 문제","sub_key":"E","start_page":92,"end_page":94,"order_index":4,"page_counts":{}}
                ],
                "sub_units": [
                  {"name":"대푯값","start_page":80,"end_page":81,"order_index":0},
                  {"name":"산포도와 편차","start_page":82,"end_page":83,"order_index":1},
                  {"name":"분산과 표준편차","start_page":84,"end_page":85,"order_index":2},
                  {"name":"도수분포표에서의 분산과 표준편차","start_page":86,"end_page":91,"order_index":3},
                  {"name":"중단원 마무리","start_page":92,"end_page":94,"order_index":4,"is_exercise":true}
                ]
              },
              {
                "name": "상관관계",
                "order_index": 1,
                "smalls": [
                  {"name":"개념원리 확인하기","sub_key":"A","start_page":96,"end_page":99,"order_index":0,"page_counts":{}},
                  {"name":"핵심문제 익히기","sub_key":"B","start_page":96,"end_page":101,"order_index":1,"page_counts":{}},
                  {"name":"이런 문제가 시험에 나온다","sub_key":"C","start_page":96,"end_page":101,"order_index":2,"page_counts":{}},
                  {"name":"중단원 마무리하기","sub_key":"D","start_page":102,"end_page":104,"order_index":3,"page_counts":{}},
                  {"name":"서술형 대비 문제","sub_key":"E","start_page":102,"end_page":104,"order_index":4,"page_counts":{}}
                ],
                "sub_units": [
                  {"name":"산점도","start_page":96,"end_page":97,"order_index":0},
                  {"name":"상관관계","start_page":98,"end_page":101,"order_index":1},
                  {"name":"중단원 마무리","start_page":102,"end_page":104,"order_index":2,"is_exercise":true}
                ]
              }
            ]
          }
        ]
        $units$::jsonb,
        true
      ),
      version = 8,
      updated_at = now()
  where academy_id = v_academy_id
    and book_id = v_book_id
    and grade_label = v_grade
    and version = 7;

  get diagnostics v_rows = row_count;
  if v_rows = 0 and exists (
    select 1
    from public.textbook_metadata
    where academy_id = v_academy_id
      and book_id = v_book_id
      and grade_label = v_grade
      and version = 8
      and payload #>> '{units,1,middles,1,sub_units,0,name}' = '원주각과 중심각'
      and payload #>> '{units,1,middles,1,sub_units,0,start_page}' = '60'
  ) then
    -- 운영 DB에 먼저 적용한 뒤 정식 migration이 실행되는 경우.
    v_rows := 1;
  end if;
  if v_rows <> 1 then
    raise exception
      '개념원리 3-2 메타데이터가 예상한 version 7/8 상태가 아닙니다 (수정 행: %).',
      v_rows;
  end if;

  delete from public.textbook_problem_crops
  where academy_id = v_academy_id
    and book_id = v_book_id
    and grade_label = v_grade;
end
$$;
