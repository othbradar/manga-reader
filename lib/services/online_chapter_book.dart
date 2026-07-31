import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/file_names.dart';
import 'copy_client.dart';

typedef ChapterContentLoader = Future<ChapterContent> Function();
typedef OnlineImageLoader = Future<Uint8List> Function(String url);

class OnlineChapterBook {
  OnlineChapterBook._({
    required this.urls,
    required this._cacheDirectory,
    required this._imageLoader,
  });

  final List<String> urls;
  final Directory _cacheDirectory;
  final OnlineImageLoader _imageLoader;
  final Map<int, Future<String>> _pendingPages = {};
  final Map<int, String> _readyPages = {};

  static Future<OnlineChapterBook> open({
    required CopyClient client,
    required String comicPathWord,
    required String chapterUuid,
  }) {
    return openWithLoaders(
      chapterUuid: chapterUuid,
      contentLoader: () => client.chapterContent(
        comicPathWord: comicPathWord,
        chapterUuid: chapterUuid,
      ),
      imageLoader: client.imageBytes,
    );
  }

  static Future<OnlineChapterBook> openWithLoaders({
    required String chapterUuid,
    required ChapterContentLoader contentLoader,
    required OnlineImageLoader imageLoader,
    Directory? cacheRoot,
  }) async {
    final content = await contentLoader();
    if (content.urls.isEmpty) {
      throw const CopyApiException('章节没有返回可在线阅读的图片');
    }
    final root = cacheRoot ?? await getTemporaryDirectory();
    final chapterKey = sha256
        .convert(utf8.encode(chapterUuid))
        .toString()
        .substring(0, 24);
    final cacheDirectory = Directory(
      p.join(root.path, 'copy_manga_online_cache', chapterKey),
    );
    await cacheDirectory.create(recursive: true);
    return OnlineChapterBook._(
      urls: List<String>.unmodifiable(content.urls),
      cacheDirectory: cacheDirectory,
      imageLoader: imageLoader,
    );
  }

  int get length => urls.length;

  String? cachedPagePath(int index) {
    _checkIndex(index);
    final ready = _readyPages[index];
    if (ready != null) return ready;
    final expected = _pagePath(index);
    final file = File(expected);
    if (file.existsSync() && file.lengthSync() > 0) {
      _readyPages[index] = expected;
      return expected;
    }
    return null;
  }

  Future<String> pagePath(int index) {
    final cached = cachedPagePath(index);
    if (cached != null) return Future<String>.value(cached);
    return _pendingPages.putIfAbsent(index, () => _cachePage(index));
  }

  void retryPage(int index) {
    _checkIndex(index);
    _pendingPages.remove(index);
    _readyPages.remove(index);
  }

  Future<void> preloadAround(int index, {int radius = 2}) async {
    final first = (index - radius).clamp(0, length - 1);
    final last = (index + radius).clamp(0, length - 1);
    await Future.wait([
      for (var page = first; page <= last; page++)
        pagePath(page).then<void>((_) {}, onError: (_) {}),
    ]);
  }

  Future<String> _cachePage(int index) async {
    final finalPath = _pagePath(index);
    final finalFile = File(finalPath);
    final partialFile = File('$finalPath.part');
    try {
      final bytes = await _imageLoader(urls[index]);
      imageExtensionFromBytes(bytes);
      if (bytes.isEmpty) {
        throw FormatException('第 ${index + 1} 页返回空图片');
      }
      if (await partialFile.exists()) await partialFile.delete();
      await partialFile.writeAsBytes(bytes, flush: true);
      if (await finalFile.exists()) await finalFile.delete();
      await partialFile.rename(finalPath);
      _readyPages[index] = finalPath;
      return finalPath;
    } catch (_) {
      if (await partialFile.exists()) await partialFile.delete();
      rethrow;
    } finally {
      _pendingPages.remove(index);
    }
  }

  String _pagePath(int index) {
    final pageWidth = length.toString().length.clamp(3, 6);
    final pageNumber = (index + 1).toString().padLeft(pageWidth, '0');
    final urlKey = sha256
        .convert(utf8.encode(urls[index]))
        .toString()
        .substring(0, 20);
    return p.join(_cacheDirectory.path, 'page_${pageNumber}_$urlKey.image');
  }

  void _checkIndex(int index) {
    if (index < 0 || index >= length) {
      throw RangeError.index(index, urls, 'index');
    }
  }
}
