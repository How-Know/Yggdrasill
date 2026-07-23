import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/textbook_api.dart';

void main() {
  group('TextbookUnitTree', () {
    test('v2 개념원리 트리의 실제 소단원과 중첩 페이지를 파싱한다', () {
      final tree = TextbookUnitTree.fromJson(const {
        'schema_version': 2,
        'page_offset': 4,
        'units': [
          {
            'order': 0,
            'name': '수와 연산',
            'mids': [
              {
                'order': 0,
                'name': '소인수분해',
                'smalls': [
                  {
                    'order': 0,
                    'sub_key': '1-1',
                    'name': '소수와 합성수',
                    'pages': [
                      {
                        'raw_page': 12,
                        'display_page': 8,
                        'total': 5,
                        'graded': 3,
                        'correct': 2,
                      },
                    ],
                  },
                  {
                    'order': 1,
                    'sub_key': '1-2',
                    'name': '소인수분해',
                    'pages': [
                      {
                        'raw_page': 14,
                        'display_page': 10,
                        'total': 4,
                        'graded': 4,
                        'correct': 4,
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
        'category_catalog': [
          {'code': 'concept', 'label': '개념원리 익히기'},
          {'code': 'essential', 'label': '필수유형'},
        ],
      });

      expect(tree.pageOffset, 4);
      expect(tree.bigUnits.single.name, '수와 연산');
      final smalls = tree.bigUnits.single.mids.single.smalls;
      expect(smalls.map((small) => small.name), [
        '소수와 합성수',
        '소인수분해',
      ]);
      expect(smalls.first.subKey, '1-1');
      expect(smalls.first.pages.single.rawPage, 12);
      expect(smalls.first.pages.single.displayPage, 8);
      expect(smalls.last.pages.single.done, isTrue);
      expect(tree.categoryCatalog.map((category) => category.label), [
        '개념원리 익히기',
        '필수유형',
      ]);
    });

    test('레거시 payload와 평면 pages 응답도 계속 파싱한다', () {
      final tree = TextbookUnitTree.fromJson(const {
        'page_offset': 2,
        'payload': {
          'units': [
            {
              'order_index': 0,
              'name': '대단원',
              'middles': [
                {
                  'order_index': 0,
                  'name': '중단원',
                  'smalls': [
                    {'order_index': 0, 'sub_key': 'A', 'name': 'A단계'},
                  ],
                },
              ],
            },
          ],
        },
        'pages': [
          {
            'big_order': 0,
            'mid_order': 0,
            'sub_key': 'A',
            'raw_page': 7,
            'total': 2,
            'graded': 1,
            'correct': 1,
          },
        ],
      });

      expect(tree.pageOffset, 2);
      expect(tree.bigUnits.single.mids.single.smalls.single.name, 'A단계');
      expect(
        tree.bigUnits.single.mids.single.smalls.single.pages.single.rawPage,
        7,
      );
    });
  });

  test('PageProblem은 선택적 분류 메타데이터를 하위 호환으로 파싱한다', () {
    final categorized = PageProblem.fromRow(const {
      'crop_id': 'crop-1',
      'problem_number': '1',
      'category_code': 'essential',
      'category_label': '필수유형',
      'item_name': '대표 문제',
    });
    final legacy = PageProblem.fromRow(const {
      'crop_id': 'crop-2',
      'problem_number': '2',
    });

    expect(categorized.categoryCode, 'essential');
    expect(categorized.categoryLabel, '필수유형');
    expect(categorized.itemName, '대표 문제');
    expect(legacy.categoryCode, isNull);
    expect(legacy.categoryLabel, isNull);
    expect(legacy.itemName, isNull);
  });
}
