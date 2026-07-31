import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/widgets/comic_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('漫画库滚动条常显可拖动且不显示细轨道', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final comics = List.generate(
      60,
      (index) => Comic(
        uuid: 'comic-$index',
        pathWord: 'comic-$index',
        title: '漫画 $index',
        authors: '作者',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicGrid(
            comics: comics,
            coverPath: (_) => '',
            onOpen: (_) {},
            scrollController: controller,
            showScrollbar: true,
          ),
        ),
      ),
    );

    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.thumbVisibility, isTrue);
    expect(scrollbar.trackVisibility, isFalse);
    expect(scrollbar.interactive, isTrue);
    expect(controller.hasClients, isTrue);
  });
}
