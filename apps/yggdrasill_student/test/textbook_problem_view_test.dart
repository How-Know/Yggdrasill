import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/textbook_api.dart';

void main() {
  group('StudentTextbookProblemView', () {
    test('ready 응답의 PDF 메타데이터를 파싱한다', () {
      final view = StudentTextbookProblemView.fromJson(const {
        'status': 'ready',
        'pdf_url': 'https://example.test/problem.pdf',
        'raw_page': 12,
        'item_region_1k': [100, 200, 500, 800],
        'expires_in': 3600,
        'cache_key': 'cache-key',
      });

      expect(view.isReady, isTrue);
      expect(view.pdfUrl, 'https://example.test/problem.pdf');
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
  });
}
