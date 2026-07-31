import 'package:copymanga_reader/core/file_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('共享漫画库命名规则', () {
    test('漫画目录、章节 ZIP 和汇总封面保持桌面版格式', () {
      expect(comicDirectoryName('漫画名', '作者'), '漫画名 - 作者');
      expect(chapterArchiveName('漫画名', '作者', '第1话'), '漫画名 - 作者 - 第1话.zip');
      expect(coverFileName('漫画名', '作者'), '漫画名 - 作者 - 汇总.jpg');
    });

    test('过滤跨平台非法文件名字符', () {
      expect(safeFileName('A/B:C*D?'), 'A B C D');
    });

    test('章节页按自然数顺序排列', () {
      final names = ['10.jpg', '2.jpg', '1.jpg']..sort(naturalCompare);
      expect(names, ['1.jpg', '2.jpg', '10.jpg']);
    });

    test('识别无损压缩库使用的 JPEG XL 页面', () {
      expect(isImageName('001.jxl'), isTrue);
      expect(isImageName('002.JXL'), isTrue);
    });

    test('不信任 content-type，按魔数识别图片扩展名', () {
      expect(imageExtensionFromBytes([0xff, 0xd8, 0xff, 0x00]), 'jpg');
      expect(
        imageExtensionFromBytes([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]),
        'png',
      );
    });
  });
}
