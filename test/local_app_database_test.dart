import 'dart:io';

import 'package:copymanga_reader/controllers/appearance_controller.dart';
import 'package:copymanga_reader/models/chapter.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/models/download_task.dart';
import 'package:copymanga_reader/models/recent_view.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory temporary;
  late LocalAppDatabase database;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('reader-local-db-test-');
    database = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async => temporary,
    );
    await database.open();
  });

  tearDown(() async {
    await database.close();
    await temporary.delete(recursive: true);
  });

  test('最近观看和阅读进度只写应用本机 SQLite', () async {
    const comic = Comic(
      uuid: 'comic-1',
      pathWord: 'comic-one',
      title: '现代魔女图鉴',
      authors: '伊咲宇多',
      comicRelativeDir: '现代魔女图鉴 - 伊咲宇多',
      coverRelativePath: '现代魔女图鉴 - 伊咲宇多/封面.jpg',
      source: ComicSource.dmzj,
      libraryOrder: 1168,
      titleSortKey: 'xiandaimonutujian',
    );
    const chapter = Chapter(
      uuid: 'chapter-1',
      comicUuid: 'comic-1',
      groupPathWord: 'local',
      groupName: '本地章节',
      title: '第1话',
      order: 1,
    );
    final viewedAt = DateTime(2026, 7, 28, 9, 30);

    await database.saveReadingState(
      RecentView(
        comic: comic,
        chapterUuid: chapter.uuid,
        chapterTitle: chapter.title,
        pageIndex: 7,
        pageCount: 28,
        viewedAt: viewedAt,
      ),
    );

    final recent = (await database.loadRecentViews()).single;
    expect(await database.loadReadProgress(chapter.uuid), 7);
    expect(recent.comic.title, comic.title);
    expect(recent.comic.source, ComicSource.dmzj);
    expect(recent.comic.libraryOrder, 1168);
    expect(recent.comic.titleSortKey, 'xiandaimonutujian');
    expect(recent.chapterTitle, '第1话');
    expect(recent.viewedAt, viewedAt);
  });

  test('筛选和排序偏好保存在本机数据库', () async {
    await database.setPreference('library_source_filter', 'both');
    await database.setPreference('library_sort_mode', 'titleInitial');

    expect(await database.preference('library_source_filter'), 'both');
    expect(await database.preference('library_sort_mode'), 'titleInitial');
  });

  test('主题颜色和深色模式保存在应用本机数据库', () async {
    final appearance = AppearanceController(database);
    await appearance.initialize();
    expect(appearance.themeColor, AppThemeColor.white);
    expect(appearance.brightnessMode, AppBrightnessMode.system);

    await appearance.setThemeColor(AppThemeColor.cream);
    await appearance.setBrightnessMode(AppBrightnessMode.dark);

    final restored = AppearanceController(database);
    await restored.initialize();
    expect(restored.themeColor, AppThemeColor.cream);
    expect(restored.brightnessMode, AppBrightnessMode.dark);
    appearance.dispose();
    restored.dispose();
  });

  test('清空下载任务只影响当前漫画库的本机任务记录', () async {
    const first = DownloadTask(
      chapterUuid: 'chapter-1',
      comicUuid: 'comic-1',
      comicPathWord: 'comic-one',
      comicTitle: '漫画一',
      authors: '作者',
      groupPathWord: 'default',
      groupName: '默认',
      chapterTitle: '第1话',
      chapterOrder: 1,
      state: DownloadState.queued,
    );
    const second = DownloadTask(
      chapterUuid: 'chapter-2',
      comicUuid: 'comic-2',
      comicPathWord: 'comic-two',
      comicTitle: '漫画二',
      authors: '作者',
      groupPathWord: 'default',
      groupName: '默认',
      chapterTitle: '第2话',
      chapterOrder: 2,
      state: DownloadState.completed,
      progress: 1,
    );

    await database.saveDownloadTask('library-a', first);
    await database.saveDownloadTask('library-a', second);
    await database.saveDownloadTask('library-b', first);
    await database.clearDownloadTasks('library-a');

    expect(await database.loadDownloadTasks('library-a'), isEmpty);
    expect(
      (await database.loadDownloadTasks('library-b')).single.chapterUuid,
      first.chapterUuid,
    );
  });
}
