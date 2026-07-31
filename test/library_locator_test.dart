import 'dart:io';

import 'package:copymanga_reader/core/file_names.dart';
import 'package:copymanga_reader/services/library_locator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('选择父目录时自动找到一层内的漫画库', () async {
    final temporary = await Directory.systemTemp.createTemp('locator-test-');
    addTearDown(() => temporary.delete(recursive: true));
    final manga = Directory('${temporary.path}/漫画');
    await manga.create();
    await File('${manga.path}/$libraryDatabaseName').writeAsBytes([1]);

    final found = await LibraryLocator.discover(temporary);

    expect(found?.path, manga.path);
  });
}
