import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/textbook_api.dart';

void main() {
  group('StudentTextbookProblemView', () {
    test('ready 응답의 PDF 메타데이터를 파싱한다', () {
      final view = StudentTextbookProblemView.fromJson(const {
        'status': 'ready',
        'pdf_url': 'https://example.test/problem.pdf',
        'body_pdf_url': 'https://example.test/book.pdf',
        'raw_page': 12,
        'item_region_1k': [100, 200, 500, 800],
        'expires_in': 3600,
        'cache_key': 'cache-key',
      });

      expect(view.isReady, isTrue);
      expect(view.pdfUrl, 'https://example.test/problem.pdf');
      expect(view.bodyPdfUrl, 'https://example.test/book.pdf');
      expect(view.rawPage, 12);
      expect(view.itemRegion1k, [100, 200, 500, 800]);
      expect(view.expiresIn, 3600);
      expect(view.cacheKey, 'cache-key');
    });

    test('fallback 중첩 필드와 body PDF URL을 파싱한다', () {
      final view = StudentTextbookProblemView.fromJson(const {
        'status': 'fallback',
        'pdf_url': 'https://example.test/book.pdf',
        'body_pdf_url': 'https://example.test/book.pdf',
        'fallback': {
          'raw_page': 31,
          'item_region_1k': [120, 90, 640, 920],
        },
      });

      expect(view.isFallback, isTrue);
      expect(view.bodyPdfUrl, 'https://example.test/book.pdf');
      expect(view.rawPage, 31);
      expect(view.itemRegion1k, [120, 90, 640, 920]);
    });

    test('queued 응답의 polling 간격을 파싱한다', () {
      final view = StudentTextbookProblemView.fromJson(const {
        'status': 'queued',
        'poll_after_ms': 1800,
      });

      expect(view.isQueued, isTrue);
      expect(view.pollAfterMs, 1800);
    });

    test('독립형 세트 메타데이터와 set view 응답을 파싱한다', () {
      final single = StudentTextbookProblemView.fromJson(const {
        'status': 'ready',
        'pdf_url': 'https://example.test/problem.pdf',
        'set_info': {
          'set_type': 'independent_set',
          'set_key': 'textbook:abc',
          'header_number': '0256~0261',
          'item_order': 1,
        },
      });
      expect(single.setInfo?.isIndependentSet, isTrue);
      expect(single.setInfo?.setKey, 'textbook:abc');
      expect(single.setInfo?.headerNumber, '0256~0261');

      final sets = ProblemSetInfo.mapFromJson(const {
        'crop-1': {
          'set_type': 'independent_set',
          'set_key': 'textbook:abc',
        },
      });
      expect(sets['crop-1']?.isIndependentSet, isTrue);

      final setView = StudentTextbookProblemSetView.fromJson(const {
        'status': 'ready',
        'common': {
          'crop_id': 'crop-1',
          'status': 'ready',
          'pdf_url': 'https://example.test/common.pdf',
        },
        'items': [
          {
            'crop_id': 'crop-1',
            'status': 'ready',
            'pdf_url': 'https://example.test/item1.pdf',
            'raw_page': 43,
            'item_region_1k': [10, 20, 30, 40],
          },
          {
            'crop_id': 'crop-2',
            'status': 'queued',
            'pdf_url': null,
            'raw_page': 43,
            'item_region_1k': [50, 20, 80, 40],
          },
        ],
        'body_pdf_url': 'https://example.test/body.pdf',
        'poll_after_ms': 1200,
      });
      expect(setView.isReady, isFalse);
      expect(setView.commonPdfUrl, 'https://example.test/common.pdf');
      expect(setView.items.length, 2);
      expect(setView.items[0].isReady, isTrue);
      expect(setView.items[1].isReady, isFalse);
    });

    test('body_page_pdf_url 과 body_cache_key 를 파싱한다', () {
      final view = StudentTextbookProblemView.fromJson(const {
        'status': 'ready',
        'pdf_url': 'https://example.test/page10.pdf',
        'body_pdf_url': 'https://example.test/book.pdf',
        'body_page_pdf_url': 'https://example.test/page10.pdf',
        'body_page_status': 'ready',
        'body_cache_key': '1450:8b6b0e21becc831f',
        'raw_page': 10,
      });

      expect(view.hasBodyPagePdf, isTrue);
      expect(view.bodyPagePdfUrl, 'https://example.test/page10.pdf');
      expect(view.bodyPageStatus, 'ready');
      expect(view.bodyCacheKey, '1450:8b6b0e21becc831f');
      expect(view.bodyPdfUrl, 'https://example.test/book.pdf');
    });

    test('page_regions 에서 item_region_1k 와 bbox_1k 합집합을 파싱한다', () {
      final view = StudentTextbookProblemView.fromJson(const {
        'status': 'ready',
        'body_page_pdf_url': 'https://example.test/page11.pdf',
        'raw_page': 11,
        'page_regions': [
          {
            'crop_id': 'crop-1',
            'bbox_1k': [164, 49, 177, 89],
            'item_region_1k': [164, 107, 177, 125],
          },
          {
            'crop_id': 'crop-2',
            'bbox_1k': null,
            'item_region_1k': [295, 109, 376, 456],
          },
        ],
      });

      expect(view.pageRegions.length, 2);
      expect(view.pageRegions[0].cropId, 'crop-1');
      expect(view.pageRegions[0].region1k, [164, 49, 177, 125]);
      expect(view.pageRegions[1].cropId, 'crop-2');
      expect(view.pageRegions[1].region1k, [295, 109, 376, 456]);
    });

    test('choice_regions_1k 와 prefetch_page_urls 를 파싱한다', () {
      final view = StudentTextbookProblemView.fromJson(const {
        'status': 'ready',
        'body_page_pdf_url': 'https://example.test/page11.pdf',
        'raw_page': 11,
        'page_regions': [
          {
            'crop_id': 'crop-1',
            'bbox_1k': [413, 57, 428, 126],
            'item_region_1k': [434, 57, 495, 370],
            'choice_regions_1k': {
              '1': [463, 58, 474, 77],
              '2': [463, 192, 474, 210],
              '3': [463, 325, 474, 344],
              '4': [483, 58, 495, 77],
              '5': [483, 192, 494, 210],
            },
          },
        ],
        'prefetch_page_urls': {
          '10': 'https://example.test/page10.pdf',
          '12': 'https://example.test/page12.pdf',
        },
      });

      expect(view.pageRegions.single.choiceRegions1k.length, 5);
      expect(view.pageRegions.single.choiceRegions1k[2], [463, 192, 474, 210]);
      expect(view.prefetchPageUrls, {
        10: 'https://example.test/page10.pdf',
        12: 'https://example.test/page12.pdf',
      });
    });
  });
}
