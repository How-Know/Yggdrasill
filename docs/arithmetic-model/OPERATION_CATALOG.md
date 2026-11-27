# 유형 목록

실행에 쓰는 목록은 `packages/ygg_arithmetic/lib/src/catalog.dart`의 `naturalSeeds`와 `draftSeeds`다. 이 문서는 그 파일을 베끼지 않는다.

- `naturalSeeds`: 기존 37개 코드, 1/10 이후 시드 비용, 최초 기준 시간(ms), 프로토콜
- `draftSeeds`: 신규 25개. 기본 상태는 초안
- `protocols`: 기초 암산 둘, 메모 허용 둘

운영 DB의 `unit_score`가 시드 비용과 다르면 DB가 우선이다. 이 목록을 DB에 다시 쓰지 않는다. 기준 시간만 `arithmetic_reference_seeds`에 한 번 넣는다.
