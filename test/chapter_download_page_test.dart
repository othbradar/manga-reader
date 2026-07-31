import 'package:copymanga_reader/models/chapter.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/pages/chapter_download_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('章节下载二级页只列缺章并支持全选和取消全选', (tester) async {
    const comic = Comic(
      uuid: 'comic-1',
      pathWord: 'comic-one',
      title: '测试漫画',
      authors: '作者',
    );
    const chapters = [
      Chapter(
        uuid: 'chapter-1',
        comicUuid: 'comic-1',
        groupPathWord: 'default',
        groupName: '默认',
        title: '第1话',
        order: 1,
      ),
      Chapter(
        uuid: 'chapter-2',
        comicUuid: 'comic-1',
        groupPathWord: 'default',
        groupName: '默认',
        title: '第2话',
        order: 2,
      ),
      Chapter(
        uuid: 'chapter-3',
        comicUuid: 'comic-1',
        groupPathWord: 'default',
        groupName: '默认',
        title: '已下载章节',
        order: 3,
        archiveRelativePath: '测试漫画/已下载章节.zip',
      ),
    ];

    await tester.pumpWidget(
      const MaterialApp(
        home: ChapterDownloadPage(
          comic: comic,
          chapters: chapters,
          initiallySelected: {'chapter-1'},
        ),
      ),
    );

    expect(find.text('已选 1 / 2'), findsOneWidget);
    expect(find.text('已下载章节'), findsNothing);

    await tester.tap(find.text('全选缺章'));
    await tester.pump();
    expect(find.text('已选 2 / 2'), findsOneWidget);
    expect(find.text('加入下载（2）'), findsOneWidget);

    await tester.tap(find.text('取消全选'));
    await tester.pump();
    expect(find.text('已选 0 / 2'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
}
