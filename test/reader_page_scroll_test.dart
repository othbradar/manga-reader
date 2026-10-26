import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:copymanga_reader/controllers/reading_history_controller.dart';
import 'package:copymanga_reader/models/chapter.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/pages/reader_page.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:copymanga_reader/services/reader_image_metrics.dart';
import 'package:copymanga_reader/widgets/zoomable_viewport.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _comic = Comic(
  uuid: 'scroll-comic',
  pathWord: 'scroll',
  title: '滚动测试',
  authors: '测试',
);
const _chapter = Chapter(
  uuid: 'scroll-chapter',
  comicUuid: 'scroll-comic',
  groupPathWord: 'default',
  groupName: '默认',
  title: '第一话',
  order: 1,
);

class _History extends ReadingHistoryController {
  _History(this.savedPage)
    : super(LocalAppDatabase(factory: databaseFactoryFfi));
  final int savedPage;
  int lastPage = 0;

  @override
  Future<int> loadProgress(String chapterUuid) async => savedPage;

  @override
  Future<void> record({
    required Comic comic,
    required Chapter chapter,
    required int pageIndex,
    required int pageCount,
  }) async {
    lastPage = pageIndex;
  }
}

Future<void> _settleImages(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _open(
  WidgetTester tester,
  String path,
  _History history, {
  TargetPlatform platform = TargetPlatform.android,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<ReadingHistoryController>.value(
      value: history,
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        home: ReaderPage(comic: _comic, chapter: _chapter, archivePath: path),
      ),
    ),
  );
  for (
    var i = 0;
    i < 100 && find.byType(CustomScrollView).evaluate().isEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(find.byType(CustomScrollView), findsOneWidget);
  await _settleImages(tester);
}

void main() {
  late Directory temporary;
  late String zipPath;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('reader-scroll-test-');
    final images = <Uint8List>[];
    for (final (width, height) in [(200, 300), (200, 500), (300, 200)]) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      final png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      images.add(png);
      await File('${temporary.path}/$width-$height.png').writeAsBytes(png);
      image.dispose();
      picture.dispose();
    }
    final archive = Archive();
    for (var i = 0; i < 60; i++) {
      final png = images[i % images.length];
      archive.addFile(
        ArchiveFile('${i.toString().padLeft(3, '0')}.png', png.length, png),
      );
    }
    zipPath = '${temporary.path}/chapter.zip';
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));
  });

  tearDownAll(() => temporary.delete(recursive: true));

  test('读取不同尺寸页面的宽高比，不占用解码图片缓存', () async {
    final cache = PaintingBinding.instance.imageCache;
    final before = cache.currentSizeBytes;
    for (final (width, height) in [(200, 300), (200, 500), (300, 200)]) {
      expect(
        await readReaderImageAspectRatio(
          '${temporary.path}/$width-$height.png',
        ),
        width / height,
      );
    }
    expect(cache.currentSizeBytes, before);
    expect(
      await readReaderImageAspectRatio('${temporary.path}/missing.png'),
      readerPlaceholderAspectRatio,
    );
  });

  testWidgets('慢速滚动跨过图片缓存边界时不会自动跳回顶部', (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    final previousLimit = cache.maximumSizeBytes;
    cache.maximumSizeBytes = 0;
    addTearDown(() => cache.maximumSizeBytes = previousLimit);
    await _open(tester, zipPath, _History(0));
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    for (var i = 0; i < 450; i++) {
      final before = scroll.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(400, 300),
          scrollDelta: const Offset(0, 24),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        scroll.offset,
        closeTo(before + 24, 0.1),
        reason: '向后慢速滚动第$i次时位置突变',
      );
      if (i % 10 == 0) await _settleImages(tester);
    }
    for (var i = 0; i < 200; i++) {
      final before = scroll.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(400, 300),
          scrollDelta: const Offset(0, -24),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        scroll.offset,
        closeTo(before - 24, 0.1),
        reason: '向前慢速滚动第$i次时位置突变',
      );
      if (i % 10 == 0) await _settleImages(tester);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  });

  testWidgets('恢复到第11页后往前翻紧邻的是第10页', (tester) async {
    await _open(tester, zipPath, _History(10));
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(-100);
    await _settleImages(tester);
    final previousImage = find.byWidgetPredicate((widget) {
      if (widget is! Image) return false;
      final provider = widget.image;
      final file = provider is ResizeImage ? provider.imageProvider : provider;
      return file is FileImage && file.file.path.endsWith('page_000009.png');
    });
    expect(previousImage, findsOneWidget);
    expect(tester.getRect(previousImage).bottom, closeTo(100, 1));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform 单指慢速上下拖动跨页和阅读进度更新不会跳页', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cache = PaintingBinding.instance.imageCache;
      final previousLimit = cache.maximumSizeBytes;
      cache.maximumSizeBytes = 0;
      addTearDown(() => cache.maximumSizeBytes = previousLimit);
      final history = _History(10);
      await _open(tester, zipPath, history, platform: platform);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;

      for (final dy in [-6.0, 6.0]) {
        // Multiple low-velocity swipes go beyond the sliver/image cache and
        // return through the saved reading anchor, not just within one page.
        for (var swipe = 0; swipe < 24; swipe++) {
          final gesture = await tester.startGesture(
            Offset(195, dy < 0 ? 700 : 100),
            kind: PointerDeviceKind.touch,
          );
          await gesture.moveBy(Offset(0, dy.sign * 30));
          await tester.pump(const Duration(milliseconds: 100));
          // iOS softens the first movement after passing its drag threshold.
          await gesture.moveBy(Offset(0, dy));
          await tester.pump(const Duration(milliseconds: 50));
          for (var step = 0; step < 40; step++) {
            final before = scroll.offset;
            await gesture.moveBy(Offset(0, dy));
            await tester.pump(const Duration(milliseconds: 50));
            expect(scroll.offset, closeTo(before - dy, 0.1));
            if (step % 20 == 0) await _settleImages(tester);
          }
          await tester.pump(const Duration(milliseconds: 200));
          await gesture.up();
          await _settleImages(tester);
        }
      }
      // Backward reading replaces the saved progress; rebuilding from that
      // change must not move the immutable sliver anchor.
      expect(history.lastPage, lessThan(13));
      final finalOffset = scroll.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, closeTo(finalOffset, 0.1));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    });
  }

  testWidgets('切换原图缩放和单指斜拖时页面高度不会塌缩', (tester) async {
    await _open(tester, zipPath, _History(0));
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(6000);
    await _settleImages(tester);
    final zoom = tester.state<ZoomableViewportState>(
      find.byType(ZoomableViewport),
    );
    final beforeZoom = scroll.offset;
    zoom.zoomIn();
    final afterZoom = scroll.offset;
    expect(afterZoom, greaterThan(beforeZoom));
    await _settleImages(tester);
    expect(scroll.offset, closeTo(afterZoom, 0.1));
    final beforeX = zoom.translation.dx;
    final gesture = await tester.startGesture(const Offset(400, 300));
    for (var step = 0; step < 30; step++) {
      final before = scroll.offset;
      await gesture.moveBy(const Offset(3, -6));
      await tester.pump(const Duration(milliseconds: 50));
      expect(scroll.offset, closeTo(before + 6 / zoom.scale, 0.1));
    }
    await gesture.up();
    expect(zoom.translation.dx, greaterThan(beforeX));
    zoom.reset();
    final afterReset = scroll.offset;
    await _settleImages(tester);
    expect(scroll.offset, closeTo(afterReset, 0.1));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  });
}
