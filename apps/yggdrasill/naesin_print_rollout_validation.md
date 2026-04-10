# 내신 인쇄 정식 연동 검증 체크리스트

## 1) 신규 내신 과제 생성 경로

- [ ] 내신 셀(활성 칸) 탭 시 하위 과제가 추가되고 `pbPresetId`가 payload에 포함된다.
- [ ] 생성 직후 `homework_items.pb_preset_id`에 값이 저장된다.
- [ ] `pbPresetId`가 없는 일반 교재 과제는 기존과 동일하게 생성된다.

## 2) 배정 생성 시 live release 연결

- [ ] `markItemsAsHomework`/`markIncompleteAsHomework` 경로에서 `pbPresetId`를 가진 항목에 대해 최신 live release를 조회한다.
- [ ] `recordAssignments`의 `liveReleaseIdByItem`로 항목별 `live_release_id`가 저장된다.
- [ ] `pbPresetId`가 없는 항목은 `live_release_id` 없이 저장된다(기존 호환).

## 3) 인쇄 소스 우선순위

- [ ] (1순위) `assignment.release_export_job_id`가 있으면 해당 export PDF를 사용한다.
- [ ] (2순위) `assignment.live_release_id` 기준 live release export PDF를 사용한다.
- [ ] (3순위) `homework_item.pb_preset_id` 기준 최신 live release export PDF를 사용한다.
- [ ] (4순위) 모두 실패하면 기존 교재 본문 PDF 경로로 fallback 한다.

## 4) URL/로컬 파일 처리

- [ ] 문제은행 signed URL 인쇄 시 임시 PDF로 다운로드 후 인쇄 파이프라인을 재사용한다.
- [ ] 로컬 파일 경로 인쇄는 기존 동작을 유지한다.
- [ ] URL 다운로드 실패 시 사용자에게 원인 스낵바를 노출한다.

## 5) 그룹 인쇄 회귀

- [ ] 그룹 하위 과제 중 인쇄 가능한 항목만 체크 가능하다.
- [ ] 서로 다른 인쇄 원본(sourceKey)이 섞인 항목은 동일 그룹 인쇄 선택에서 자동 제외된다.
- [ ] 선택한 하위 과제가 0개면 인쇄를 진행하지 않는다.

## 6) 기존 과제 호환

- [ ] `pb_preset_id`가 null인 기존 과제는 기존 교재 인쇄 경로로 정상 동작한다.
- [ ] 기존 과제의 답지/해설 열람, 상태 전환, 편집 동작에 회귀가 없다.

