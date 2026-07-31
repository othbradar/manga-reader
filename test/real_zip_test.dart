import 'dart:io';
import 'dart:ui' as ui;

import 'package:copymanga_reader/services/zip_book.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final path = Platform.environment['COPYMANGA_REAL_ZIP'];
  test(
    '真实章节 ZIP 可以在后台展开并读取首尾页',
    () async {
      final book = await ZipBook.open(path!);
      addTearDown(book.close);

      expect(book.length, greaterThan(1));
      expect(book.pageName(0), isNotEmpty);
      expect(File(book.pagePath(0)).existsSync(), isTrue);
      final first = await book.bytes(0);
      final last = await book.bytes(book.length - 1);
      expect(first, isNotEmpty);
      expect(last, isNotEmpty);

      for (final bytes in [first, last]) {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(0));
        expect(frame.image.height, greaterThan(0));
        frame.image.dispose();
        codec.dispose();
      }
    },
    skip: path == null ? '设置 COPYMANGA_REAL_ZIP 后运行真实章节校验' : false,
  );
}
