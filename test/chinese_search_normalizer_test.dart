import 'package:copymanga_reader/services/chinese_search_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OpenCC 内置词典可双向转换常见漫画名', () async {
    final normalizer = ChineseSearchNormalizer();
    await normalizer.loadAssets();

    expect(normalizer.toSimplified('水星領航員'), '水星领航员');
    expect(normalizer.toTraditional('东京食尸鬼'), '東京食屍鬼');
    expect(
      normalizer.queryVariants('水星领航员'),
      containsAll(<String>['水星领航员', '水星領航員']),
    );
  });
}
