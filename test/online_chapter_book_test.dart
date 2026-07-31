import 'dart:io';
import 'dart:typed_data';

import 'package:copymanga_reader/services/copy_client.dart';
import 'package:copymanga_reader/services/online_chapter_book.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'online-chapter-cache-test-',
    );
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('在线章节只写应用缓存且同一图片不会重复请求', () async {
    var imageRequests = 0;
    final book = await OnlineChapterBook.openWithLoaders(
      chapterUuid: 'chapter-1',
      cacheRoot: temporary,
      contentLoader: () async => const ChapterContent(
        urls: ['https://img.example/001.jpg', 'https://img.example/002.jpg'],
        pageCount: 2,
      ),
      imageLoader: (url) async {
        imageRequests++;
        return Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
      },
    );

    expect(book.length, 2);
    expect(book.cachedPagePath(0), isNull);
    final firstPath = await book.pagePath(0);
    expect(File(firstPath).existsSync(), isTrue);
    expect(book.cachedPagePath(0), firstPath);
    expect(await book.pagePath(0), firstPath);
    expect(imageRequests, 1);
    expect(
      temporary
          .listSync(recursive: true)
          .whereType<File>()
          .any((file) => file.path.toLowerCase().endsWith('.zip')),
      isFalse,
    );

    final reopened = await OnlineChapterBook.openWithLoaders(
      chapterUuid: 'chapter-1',
      cacheRoot: temporary,
      contentLoader: () async => const ChapterContent(
        urls: ['https://img.example/001.jpg', 'https://img.example/002.jpg'],
        pageCount: 2,
      ),
      imageLoader: (url) async {
        imageRequests++;
        return Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
      },
    );
    expect(await reopened.pagePath(0), firstPath);
    expect(imageRequests, 1);
  });
}
