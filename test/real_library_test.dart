import 'dart:io';

import 'package:copymanga_reader/services/chinese_search_normalizer.dart';
import 'package:copymanga_reader/services/library_database.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['COPYMANGA_REAL_LIBRARY'];
  test(
    '真实桌面版总索引可以保持原样打开并查询',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final normalizer = ChineseSearchNormalizer();
      await normalizer.loadAssets();
      final localRoot = await Directory.systemTemp.createTemp(
        'real-library-local-state-',
      );
      final local = LocalAppDatabase(
        factory: databaseFactoryFfi,
        supportDirectoryProvider: () async => localRoot,
      );
      final library = LibraryDatabase(
        normalizer: normalizer,
        localDatabase: local,
      );
      await library.open(Directory(path!));
      addTearDown(() async {
        await library.close();
        await local.close();
        await localRoot.delete(recursive: true);
      });

      final quickCheck = await library.database.rawQuery('PRAGMA quick_check');
      final comics = await library.loadComics();
      final simplifiedSearch = await library.loadComics(query: '水星领航员');
      final chapterCount = Sqflite.firstIntValue(
        await library.database.rawQuery('SELECT COUNT(*) FROM chapters'),
      );
      final sourceCounts = {
        for (final row in await library.database.rawQuery(
          'SELECT source_kind, COUNT(*) AS count '
          'FROM comics GROUP BY source_kind',
        ))
          row['source_kind']?.toString() ?? '':
              (row['count'] as num?)?.toInt() ?? 0,
      };
      final modern = await library.loadComic(
        'local-546w5Luj6a2U5aWz5Zu-6Ym0IC0g5LyK5ZKy5a6H5aSaKOS8iuWSsuOCpuOCvyk',
      );

      expect(quickCheck.first.values.first, 'ok');
      expect(comics.length, greaterThan(1000));
      expect(simplifiedSearch.map((comic) => comic.title), contains('水星領航員'));
      expect(chapterCount, greaterThan(70000));
      expect(sourceCounts, {'both': 1035, 'copy_manga': 81, 'dmzj': 75});
      expect(modern?.title, '现代魔女图鉴');
      expect(modern?.libraryOrder, 1168);
      expect(modern?.titleSortKey, 'xiandaimonutujian');
    },
    skip: path == null ? '设置 COPYMANGA_REAL_LIBRARY 后运行真实库校验' : false,
  );
}
