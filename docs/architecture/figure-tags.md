# 그림 이름표 (그림 엔진)

그림 엔진(`packages/ygg_figure`)으로 다시 그린 그림에는 모두 이름표가 붙는다. 같은
구도의 그림을 다시 찾아 쓰기 위해서다. 자체 문항을 만들 때 출제자가 이미 구도가 잡힌
그림을 가져와 고쳐 쓰고, 나중에 그림을 검색할 때도 이 이름표로 찾는다.

2026학년도까지의 수능 그림 82장을 옮기면서 초안을 만들었고, 그 과정에서 고친 내용을
반영해 확정했다(2026-11-26).

- 태그 목록: `packages/ygg_figure/figures/tags.json`
- 요소 태그를 뽑는 코드: `packages/ygg_figure/lib/src/tags.dart`
- 이름표가 실리는 곳: 그림 파일(`figures/**/*.json`)과 내보낸 묶음의 `asset.json`

## 이름표는 세 겹이다

| 겹 | 그림 파일의 자리 | 개수 | 누가 붙이나 | 답하는 질문 |
| --- | --- | --- | --- | --- |
| 큰 종류 | `kind` | 하나 | 그리는 사람 | 어떤 부류의 그림인가 |
| 구도·곡선 종류 태그 | `tags` | 여러 개 | 그리는 사람 | 어떤 구도인가, 어떤 곡선인가 |
| 요소 태그 | (없음, 저절로) | 여러 개 | 엔진 | 무엇이 그려져 있나 |

처음 초안에는 "삼각형", "사각형"도 구도 태그였다. 수능 그림을 다 옮겨 보니 삼각형이
11장, 사각형이 8장에 붙었는데, 이 태그로 찾아 봐야 서로 닮은 그림이 나오지 않았다.
삼각형은 구도가 아니라 **재료**였다. 그래서 재료는 요소 태그로 내리고, 구도 태그는
"이 그림을 가져다 쓰면 구도가 이미 잡혀 있다"고 말할 수 있는 것만 남겼다.

## 큰 종류 (`kind`)

| 값 | 뜻 | 수능 82장 |
| --- | --- | --- |
| `graph` | 함수 그래프 | 32 |
| `plane` | 평면도형 | 26 |
| `solid` | 공간도형 | 13 |
| `solid_graph` | 입체 그래프(단면 부피) | 7 |
| `mapping` | 함수 대응 | 4 |
| `glyph` | 글줄 안 작은 모양 | 아직 옮기지 않음 |
| `illustration` | 삽화 | 아직 옮기지 않음 |

## 구도 태그 (`tags`, 묶음 `composition`)

괄호 안은 수능 82장에서 쓰인 횟수다.

**함수 대응**
- `mapping-arrows` 집합과 화살표 대응 (4)
- `mapping-composite` 두 대응을 나란히(합성함수) (2)

**그래프**
- `curve-and-line` 곡선과 직선의 교점 (10)
- `piecewise-graph` 구간마다 끊어진 그래프 (6)
- `polyline-graph` 꺾은선 그래프 (4)
- `area-between` 곡선 사이 넓이(색칠) (4)
- `points-on-curve` 곡선 위의 점과 수선 (4)
- `pdf-graph` 확률밀도함수 그래프 (3)
- `tangent-line` 곡선과 접선 (3)
- `sequence-on-curve` 곡선 위 점의 나열(수열) (2)
- `triangle-on-graph` 그래프 위의 점이 만드는 삼각형 (2)
- `circle-on-curve` 곡선 위의 점을 중심으로 하는 원 (1)

**이차곡선**
- `conic-focus-triangle` 초점과 곡선 위 점이 만드는 삼각형 (7)
- `conic-with-circle` 이차곡선과 원 (3)
- `two-conics` 두 이차곡선 (3)

**평면도형**
- `sector` 부채꼴 (7)
- `series-repeat` 급수 반복 도형 (6)
- `theta-limit` 각 θ 로 정해지는 도형(극한) (6)
- `circle-and-chords` 원과 현·접선 (5)
- `triangle-in-circle` 원 안의 삼각형(원에 내접) (3)
- `points-on-circle` 원 위의 점·둘레 배치 (3)
- `plain-polygon` 다각형 하나(꼭짓점 이름만) (3)
- `semicircle` 반원 (2)
- `two-circles` 두 원 (2)
- `round-table` 원탁 둘레 자리 배치 (2)
- `quadrilateral-in-circle` 원 안의 사각형(원에 내접) (1)
- `circle-in-triangle` 삼각형 안의 원(내접원) (1)
- `series-branch` 단계마다 개수가 늘어나는 급수 반복 도형 (1)
- `triangle-inner-lines` 삼각형과 안쪽 선분(수선·내분점) (1)

**입체 그래프**
- `cross-section-volume` 밑면 곡선 위에 세운 단면 입체 (7)
- `section-square` 단면이 정사각형 (5)
- `section-triangle` 단면이 정삼각형 (2)

**공간도형**
- `tetrahedron` 사면체 (5)
- `sphere` 구 (5)
- `sphere-and-plane` 구와 평면(단면 원) (2)
- `line-and-plane` 직선과 평면 (2)
- `circle-on-plane` 평면 위의 원(비스듬히 본 원) (2)
- `prism` 각기둥, `cube` 정육면체·직육면체, `cylinder` 원기둥 (각 1)
- `sphere-in-polyhedron` 다면체 안의 구, `two-planes` 두 평면(이면각), `solid-section` 입체의 단면,
  `orthogonal-projection` 정사영, `folded-figure` 접은 도형, `space-coordinates` 좌표공간 (각 1)

## 곡선 종류 태그 (`tags`, 묶음 `curve`)

구도와 따로 묶는다. "지수·로그 곡선이 나오는 그림"과 "곡선과 직선의 교점을 다루는
그림"은 서로 다른 질문이고, 둘을 겹쳐 찾을 수 있어야 한다. 그림 파일에서는 구도
태그와 같은 `tags` 에 함께 적고, 어느 묶음인지는 태그 목록이 안다.

- `exp-log-curve` 지수·로그 곡선 (8)
- `polynomial-curve` 다항함수 곡선 (6)
- `ellipse` 타원 (5)
- `trig-curve` 삼각함수 곡선 (4)
- `hyperbola` 쌍곡선 (4)
- `parabola` 포물선 (3)
- `root-curve` 무리함수 곡선 (2)
- `rational-curve` 유리함수 곡선 (1)

곡선 종류는 요소 태그처럼 저절로 뽑지 않는다. 엔진이 보는 것은 식(`exp(x)`,
`x^3-3x`)이라 식에서 종류를 가려낼 수는 있어도, 그림 속 곡선이 문제에서 어떤
함수로 쓰이는지(예: 이름 없는 `y=f(x)`)는 그리는 사람만 안다.

## 요소 태그 (저절로 붙는다)

그림 파일에 적힌 요소의 종류를 보고 엔진이 뽑는다. 그림을 고치면 따라 바뀌므로
손으로 맞출 일이 없다. 내보낼 때 `asset.json` 의 `elements` 에 실린다.

| 태그 | 뜻 | 무엇을 보고 붙이나 |
| --- | --- | --- |
| `triangle` | 삼각형 | 점 3개짜리 `polygon` |
| `quadrilateral` | 사각형 | 점 4개짜리 `polygon` |
| `polygon` | 다각형 | `polygon` |
| `circle` | 원 | `circle` |
| `arc` | 호 | `arc` |
| `oval` | 타원 모양 | `ellipse` |
| `function-curve` | 함수 곡선 | `function` |
| `parametric-curve` | 매개변수 곡선 | `parametric` |
| `axes` | 좌표축 | `axes` |
| `fill` | 색칠 영역 | `fill`, 또는 요소의 `fill` |
| `dashed-line` | 점선 | 요소의 `line` 이 점선 |
| `arrow` | 화살표 | 요소의 `arrow` |
| `dot` | 점 표시 | `dot`, 또는 요소의 `dot` |
| `right-angle` | 직각 표시 | `right_angle` |
| `angle-mark` | 각 표시 | `angle` |
| `length-mark` | 길이 표시 | `dimension` |
| `repeat` | 되풀이 | 개수를 준 `use` |
| `space` | 공간 좌표 | 그림 파일의 `projection` |

교점을 찾으려고 둔 보조 요소(`"draw": false`)는 보이지 않으므로 세지 않는다.

**손으로 보태는 경우.** 선분 세 개로 그린 삼각형은 종류만 봐서는 삼각형인지 알 수
없다. 이런 그림은 그림 파일의 `"elements": ["triangle"]` 에 적어 두면 저절로 뽑은
것과 합쳐진다. 초안에서 삼각형·사각형 태그가 붙어 있던 18장은 이 자리로 옮겨
정보를 잃지 않게 했다.

## 붙이는 규칙

1. `kind` 는 하나, `tags` 는 하나 이상. 구도 태그가 적어도 하나는 있어야 한다.
2. 목록(`tags.json`)에 없는 이름은 쓰지 않는다. 엔진 테스트가 저장소의 모든 그림을
   확인한다(`dart test`).
3. 맞는 구도 태그가 없으면 억지로 가까운 것을 붙이지 않고 목록에 새로 더한다.
   수능을 옮기면서 그렇게 더한 것이 `circle-on-curve`, `triangle-on-graph`,
   `two-conics`, `round-table`, `series-branch`, `circle-on-plane`,
   `circle-in-triangle`, `sphere-in-polyhedron`, `section-square`,
   `section-triangle`, `plain-polygon`, `triangle-inner-lines` 다.
4. 재료(삼각형, 원, 점선 …)는 구도 태그로 만들지 않는다. 요소 태그의 몫이다.
5. 이름은 그림에 보이는 대로 짓는다. "원에 내접하는 삼각형"과 "삼각형의 내접원"은
   말이 비슷해 헷갈렸다. 무엇이 무엇 안에 있는지로 고쳤다: `triangle-in-circle`
   (원 안의 삼각형), `circle-in-triangle`(삼각형 안의 원).
6. 입체 그래프는 단면 모양을 함께 적는다(`section-square`, `section-triangle`).
   단면 모양에 따라 그리는 방법이 달라서, 가져다 쓸 때 가장 먼저 가르는 기준이다.

## 미뤄 둔 것

- `pyramid`(각뿔): 수능 그림에는 쓰인 곳이 없다. 평가원 그림을 옮길 때 다시 본다
  (`tags.json` 의 `on_hold`).
- 글줄 안 작은 모양(8장)과 삽화(15장)는 아직 엔진으로 옮기지 않았다. 옮기기로
  하면 그때 태그를 정한다.
- 이름표로 그림을 찾는 화면과 "구도 가져오기"는 아직 만들지 않았다. 이름표는
  내보낸 묶음(`asset.json`)까지만 실려 있고, DB 에는 싣지 않았다.
