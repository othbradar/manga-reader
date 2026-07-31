import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../core/file_names.dart';

class ZipBook {
  ZipBook._(this._temporaryDirectory, this._pages);

  final Directory _temporaryDirectory;
  final List<_ExtractedPage> _pages;

  static Future<ZipBook> open(String path) async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'copymanga_reader_',
    );
    try {
      final extracted = await Isolate.run(
        () => _extractPages(path, temporaryDirectory.path),
      );
      final pages = extracted
          .map((page) => _ExtractedPage(page[0], page[1]))
          .toList(growable: false);
      return ZipBook._(temporaryDirectory, pages);
    } catch (_) {
      await temporaryDirectory.delete(recursive: true);
      rethrow;
    }
  }

  int get length => _pages.length;

  String pageName(int index) => _pages[index].name;

  String pagePath(int index) => _pages[index].path;

  Future<Uint8List> bytes(int index) => File(pagePath(index)).readAsBytes();

  Future<void> close() async {
    if (await _temporaryDirectory.exists()) {
      await _temporaryDirectory.delete(recursive: true);
    }
  }
}

class _ExtractedPage {
  const _ExtractedPage(this.name, this.path);

  final String name;
  final String path;
}

List<List<String>> _extractPages(String archivePath, String outputDirectory) {
  final input = InputFileStream(archivePath);
  Archive? archive;
  try {
    archive = ZipDecoder().decodeStream(input);
    final pages =
        archive.files
            .where((file) => file.isFile && isImageName(file.name))
            .toList()
          ..sort((a, b) => naturalCompare(a.name, b.name));
    if (pages.isEmpty) {
      throw const FormatException('压缩包内没有可识别的漫画图片');
    }

    final extracted = <List<String>>[];
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      final extension = p.extension(page.name).toLowerCase();
      final outputPath = p.join(
        outputDirectory,
        'page_${index.toString().padLeft(6, '0')}$extension',
      );
      final output = OutputFileStream(outputPath);
      try {
        page.writeContent(output, freeMemory: true);
      } finally {
        output.closeSync();
      }
      if (File(outputPath).lengthSync() == 0) {
        throw FormatException('无法读取第 ${index + 1} 页');
      }
      extracted.add([page.name, outputPath]);
    }
    return extracted;
  } finally {
    if (archive != null) {
      for (final file in archive.files) {
        file.closeSync();
      }
    }
    input.closeSync();
  }
}
