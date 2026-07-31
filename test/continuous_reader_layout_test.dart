import 'package:copymanga_reader/core/continuous_reader_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('恢复阅读页前后的页面仍保持自然顺序', () {
    const layout = ContinuousReaderLayout(pageCount: 6, anchorPage: 4);

    final pages = [
      for (var index = 0; index < layout.beforeAnchorCount; index++)
        layout.pageBeforeAnchor(index),
      for (var index = 0; index < layout.fromAnchorCount; index++)
        layout.pageFromAnchor(index),
    ];

    expect(pages, [0, 1, 2, 3, 4, 5]);
    expect(layout.pageBeforeAnchor(layout.beforeAnchorCount - 1), 3);
    expect(layout.pageFromAnchor(0), 4);
  });
}
