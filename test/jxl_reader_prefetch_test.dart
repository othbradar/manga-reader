import 'dart:io';

import 'package:archive/archive.dart';
import 'package:copymanga_reader/controllers/reader_controller.dart';
import 'package:copymanga_reader/controllers/reading_history_controller.dart';
import 'package:copymanga_reader/models/chapter.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _History extends ReadingHistoryController {
  _History() : super(LocalAppDatabase(factory: databaseFactoryFfi));
  @override
  Future<int> loadProgress(String chapterUuid) async => 0;
  @override
  Future<void> record({
    required Comic comic,
    required Chapter chapter,
    required int pageIndex,
    required int pageCount,
  }) async {}
}

void main() {
  final enabled = Platform.environment.containsKey('COPYMANGA_JXL_LIBRARY');
  group(
    'local JXL preloading policy',
    () {
      for (final count in [31, 99, 100]) {
        test(
          '$count pages: ${count < 100 ? 'whole chapter' : 'nearby only'}',
          () async {
            final temp = await Directory.systemTemp.createTemp('jxl-prefetch-');
            addTearDown(() => temp.delete(recursive: true));
            final bytes = await File(
              'test/fixtures/jxl/reversible.jxl',
            ).readAsBytes();
            final archive = Archive();
            for (var i = 0; i < count; i++) {
              archive.addFile(ArchiveFile('$i.jxl', bytes.length, bytes));
            }
            final zip = await File(
              '${temp.path}/chapter.zip',
            ).writeAsBytes(ZipEncoder().encode(archive));
            final reader = ReaderController(
              history: _History(),
              comic: const Comic(
                uuid: 'c',
                pathWord: 'c',
                title: 'c',
                authors: 'a',
              ),
              chapter: const Chapter(
                uuid: 'ch',
                comicUuid: 'c',
                groupPathWord: 'default',
                groupName: 'default',
                title: 'ch',
                order: 1,
              ),
              archivePath: zip.path,
            );
            addTearDown(reader.dispose);
            await reader.initialize();
            expect(reader.error, isEmpty);
            final expected = count < 100 ? count : 3;
            int preparedCount() => [
              for (var i = 0; i < count; i++) reader.cachedPagePath(i),
            ].whereType<String>().length;
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (preparedCount() < expected &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
            expect(preparedCount(), expected);
            expect(reader.pageAspectRatio(0), closeTo(32 / 48, 0.00001));
            if (count >= 100) {
              reader.changePage(50);
              await reader.ensurePagePath(50);
              expect(reader.cachedPagePath(50), endsWith('.jpg'));
              expect(reader.cachedPagePath(20), isNull);
            }
          },
        );
      }
    },
    skip: enabled ? false : '设置 COPYMANGA_JXL_LIBRARY 运行原生预载策略测试',
  );
}
