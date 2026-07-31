import 'package:copymanga_reader/widgets/zoomable_viewport.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('滚动模式放大后单指斜向拖动可同时横移并连续跨页', (tester) async {
    final key = GlobalKey<ZoomableViewportState>();
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    var scrollLocked = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ZoomableViewport(
            key: key,
            onTap: () {},
            onVerticalScroll: (delta) {
              final before = scrollController.offset;
              final position = scrollController.position;
              final target = (before + delta).clamp(
                position.minScrollExtent,
                position.maxScrollExtent,
              );
              scrollController.jumpTo(target);
              return target - before;
            },
            builder: (context, zoomed, locked) {
              scrollLocked = locked;
              return ListView(
                controller: scrollController,
                physics: locked
                    ? const NeverScrollableScrollPhysics()
                    : const ClampingScrollPhysics(),
                children: const [SizedBox(height: 1600)],
              );
            },
          ),
        ),
      ),
    );

    final first = await tester.startGesture(const Offset(150, 350), pointer: 1);
    await first.moveBy(const Offset(0, -25));
    final second = await tester.startGesture(
      const Offset(250, 350),
      pointer: 2,
    );
    await tester.pump();

    await first.moveTo(const Offset(100, 350));
    await second.moveTo(const Offset(300, 350));
    await tester.pump();

    expect(key.currentState!.scale, greaterThan(1.5));
    expect(scrollLocked, isTrue);

    await first.up();
    await second.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(scrollLocked, isTrue);

    final offsetBeforeZoomedScroll = scrollController.offset;
    final horizontalBeforePan = key.currentState!.translation.dx;
    await tester.drag(find.byType(ListView), const Offset(-100, -300));
    await tester.pumpAndSettle();

    expect(key.currentState!.scale, greaterThan(1.5));
    expect(
      key.currentState!.translation.dx,
      lessThan(horizontalBeforePan - 50),
    );
    expect(
      scrollController.offset,
      greaterThan(offsetBeforeZoomedScroll + 100),
    );
  });

  testWidgets('双击和工具栏缩放可以恢复到原始比例', (tester) async {
    final key = GlobalKey<ZoomableViewportState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ZoomableViewport(
            key: key,
            onTap: () {},
            builder: (_, _, _) => const SizedBox.expand(
              child: ColoredBox(key: Key('zoom-child'), color: Colors.black),
            ),
          ),
        ),
      ),
    );

    key.currentState!.zoomIn();
    await tester.pump();
    expect(key.currentState!.scale, closeTo(1.5, 0.001));

    key.currentState!.zoomOut();
    await tester.pump();
    expect(key.currentState!.scale, closeTo(1, 0.001));

    await tester.tap(find.byKey(const Key('zoom-child')));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.byKey(const Key('zoom-child')));
    await tester.pumpAndSettle();
    expect(key.currentState!.scale, closeTo(2.5, 0.001));

    await tester.pump(kDoubleTapTimeout);
    await tester.tap(find.byKey(const Key('zoom-child')));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.byKey(const Key('zoom-child')));
    await tester.pumpAndSettle();
    expect(key.currentState!.scale, closeTo(1, 0.001));
    await tester.pump(const Duration(milliseconds: 500));
  });
}
