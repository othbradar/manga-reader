import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../core/file_names.dart';
import 'jxl_codec.dart';

class ZipBook {
  ZipBook._(this._temporaryDirectory, this._pages);

  final Directory _temporaryDirectory;
  final List<_ExtractedPage> _pages;
  final Map<int, String> _displayPaths = {};
  final Map<int, Future<String>> _preparing = {};
  Future<void>? _closing;
  bool _closed = false;

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

  String pagePath(int index) => _displayPaths[index] ?? _pages[index].path;

  String? cachedDisplayPath(int index) =>
      _displayPaths[index] ??
      (JxlCodec.requiresConversion(_pages[index].path)
          ? null
          : _pages[index].path);

  Future<String> preparePagePath(int index) {
    if (_closed) return Future.error(StateError('章节已关闭'));
    final cached = cachedDisplayPath(index);
    if (cached != null) return Future.value(cached);
    return _preparing.putIfAbsent(index, () async {
      try {
        final source = _pages[index].path;
        final decoded = await JxlCodec.prepare(source, '$source.decoded');
        if (_closed) throw StateError('章节已关闭');
        _displayPaths[index] = decoded;
        return decoded;
      } finally {
        _preparing.remove(index);
      }
    });
  }

  Future<Uint8List> bytes(int index) => File(pagePath(index)).readAsBytes();

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    // Do not delete a directory while native workers are still writing into it.
    await Future.wait([
      for (final future in _preparing.values.toList())
        future.then<void>((_) {}, onError: (_) {}),
    ]);
    _displayPaths.clear();
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
