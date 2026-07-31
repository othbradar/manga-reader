import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:copymanga_reader/controllers/download_controller.dart';
import 'package:copymanga_reader/models/chapter.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/models/download_task.dart';
import 'package:copymanga_reader/services/copy_client.dart';
import 'package:copymanga_reader/services/library_database.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('下载中的字节进度实时写回页面任务，清理会清空全部任务', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'download-controller-test-',
    );
    final local = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async =>
          Directory('${temporary.path}/app-support'),
    );
    final library = LibraryDatabase(localDatabase: local);
    await library.open(Directory('${temporary.path}/library'));
    final client = _ProgressCopyClient();
    final controller = DownloadController(database: library, client: client);

    try {
      await controller.initialize();
      await controller.enqueue(
        const Comic(
          uuid: 'comic-1',
          pathWord: 'comic-one',
          title: '测试漫画',
          authors: '作者',
        ),
        const <Chapter>[
          Chapter(
            uuid: 'chapter-1',
            comicUuid: 'comic-1',
            groupPathWord: 'default',
            groupName: '默认',
            title: '第1话',
            order: 1,
          ),
        ],
      );

      await controller.resumeAll();
      await client.progressReported.future;

      expect(controller.tasks.single.state, DownloadState.downloading);
      expect(controller.tasks.single.progress, closeTo(0.5, 0.001));

      client.finishImage.complete();
      await _waitUntil(
        () => controller.tasks.single.state == DownloadState.completed,
      );
      await controller.clearAllTasks();

      expect(controller.tasks, isEmpty);
      expect(await library.loadDownloadTasks(), isEmpty);
      expect(controller.globalPaused, isTrue);
    } finally {
      controller.dispose();
      await library.close();
      await local.close();
      await temporary.delete(recursive: true);
    }
  });

  test('漫画图片按设置值并发下载且并发数最大为 10', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'download-concurrency-test-',
    );
    final local = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async =>
          Directory('${temporary.path}/app-support'),
    );
    final library = LibraryDatabase(localDatabase: local);
    await library.open(Directory('${temporary.path}/library'));
    final client = _ConcurrentCopyClient(expectedConcurrency: 3);
    final controller = DownloadController(database: library, client: client);

    try {
      await controller.initialize();
      await controller.setImageDownloadConcurrency(3);
      await controller.enqueue(
        const Comic(
          uuid: 'comic-concurrent',
          pathWord: 'comic-concurrent',
          title: '并发漫画',
          authors: '作者',
        ),
        const [
          Chapter(
            uuid: 'chapter-concurrent',
            comicUuid: 'comic-concurrent',
            groupPathWord: 'default',
            groupName: '默认',
            title: '第1话',
            order: 1,
          ),
        ],
      );

      await controller.resumeAll();
      await _waitUntil(
        () => controller.tasks.single.state == DownloadState.completed,
      );

      expect(client.peakActive, 3);
      expect(await library.setting('image_download_concurrency'), '3');
      await controller.setImageDownloadConcurrency(99);
      expect(controller.imageDownloadConcurrency, 10);
    } finally {
      controller.dispose();
      await library.close();
      await local.close();
      await temporary.delete(recursive: true);
    }
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待下载状态更新超时');
}

final class _ProgressCopyClient extends CopyClient {
  final progressReported = Completer<void>();
  final finishImage = Completer<void>();

  @override
  Future<ChapterContent> chapterContent({
    required String comicPathWord,
    required String chapterUuid,
  }) async {
    return const ChapterContent(
      urls: <String>['https://img.example/page.jpg'],
      pageCount: 1,
    );
  }

  @override
  Future<Uint8List> imageBytes(
    String url, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    onReceiveProgress?.call(5, 10);
    if (!progressReported.isCompleted) progressReported.complete();
    await finishImage.future;
    onReceiveProgress?.call(10, 10);
    return Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]);
  }
}

final class _ConcurrentCopyClient extends CopyClient {
  _ConcurrentCopyClient({required this.expectedConcurrency});

  final int expectedConcurrency;
  final Completer<void> _release = Completer<void>();
  int _active = 0;
  int peakActive = 0;

  @override
  Future<ChapterContent> chapterContent({
    required String comicPathWord,
    required String chapterUuid,
  }) async {
    return ChapterContent(
      urls: List.generate(6, (index) => 'https://img.example/$index.jpg'),
      pageCount: 6,
    );
  }

  @override
  Future<Uint8List> imageBytes(
    String url, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    _active++;
    if (_active > peakActive) peakActive = _active;
    if (_active >= expectedConcurrency && !_release.isCompleted) {
      _release.complete();
    }
    await _release.future;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    onReceiveProgress?.call(1, 1);
    _active--;
    return Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]);
  }
}
