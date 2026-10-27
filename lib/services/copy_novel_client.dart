import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/novel.dart';
import 'chinese_search_normalizer.dart';
import 'copy_api_protocol.dart';
import 'copy_api_transport.dart';

/// Novel requests share the current transport/node/signature implementation.
/// Only favorites attach the account token; text and illustrations never do.
class CopyNovelClient {
  CopyNovelClient(this.transport, this.normalizer);
  final CopyApiTransport transport;
  final ChineseSearchNormalizer? normalizer;
  int get sessionRevision => transport.sessionRevision;

  Future<List<Novel>> search(String keyword, {int page = 1}) async {
    for (final variant
        in normalizer?.queryVariants(keyword) ?? [keyword.trim()]) {
      final result = novelMap(
        await transport.requestResults(
          CopyApiProtocol.novelSearchPath,
          query: CopyApiProtocol.searchQuery(
            keyword: variant,
            limit: 20,
            offset: (page - 1) * 20,
          ),
          validateResults: (data) => novelMap(data)['list'] is List,
        ),
      );
      final books = novelList(result['list'])
          .map((x) => Novel.fromApi(novelMap(x)))
          .where((x) => x.pathWord.isNotEmpty && x.title.isNotEmpty)
          .toList();
      if (books.isNotEmpty) return books;
    }
    return [];
  }

  Future<Novel> details(String pathWord) async {
    await transport.prepare();
    final result = novelMap(
      await transport.requestResults(
        CopyApiProtocol.novelDetailsPath(pathWord),
        query: CopyApiProtocol.comicDetailsQuery(
          inMainland: transport.inMainland,
        ),
        validateResults: (data) {
          final book = novelMap(novelMap(data)['book']);
          return novelText(book['uuid']).isNotEmpty &&
              novelText(book['path_word']) == pathWord;
        },
        invalidResultsMessage: '小说详情标识不匹配',
      ),
    );
    return Novel.fromApi(novelMap(result['book']));
  }

  Future<List<NovelVolume>> volumes(Novel book) async {
    // Original a7d0ac sends no paging/ordering query on /volumes.
    final result = novelMap(
      await transport.requestResults(
        CopyApiProtocol.novelVolumesPath(book.pathWord),
        validateResults: (data) => novelMap(data)['list'] is List,
      ),
    );
    final rows = novelList(result['list']).map(novelMap).toList();
    if (novelInt(result['total'], rows.length) > rows.length) {
      throw const CopyApiException('小说目录返回不完整，请稍后重试');
    }
    final volumes = rows.map((x) => NovelVolume.fromApi(x, book.uuid)).toList();
    if (volumes.any((v) => v.id.isEmpty)) {
      throw const CopyApiException('小说卷目录缺少标识');
    }
    return volumes;
  }

  Future<NovelVolume> content(Novel book, NovelVolume volume) async {
    final result = novelMap(
      await transport.requestResults(
        CopyApiProtocol.novelVolumePath(book.pathWord, volume.id),
        validateResults: (data) {
          final row = novelMap(novelMap(data)['volume']);
          return novelText(row['id']) == volume.id &&
              novelText(row['book_path_word']) == book.pathWord &&
              novelText(row['txt_addr']).startsWith('http');
        },
        invalidResultsMessage: '小说卷没有返回有效的文本地址',
      ),
    );
    return NovelVolume.fromApi(novelMap(result['volume']), book.uuid);
  }

  Future<List<Novel>> favorites() async => (await _pages(
    CopyApiProtocol.novelFavoritesPath,
    authenticated: true,
  )).map(Novel.fromApi).toList();

  Future<void> setFavorite(Novel book, bool value) async {
    if (book.uuid.isEmpty || book.pathWord.isEmpty || book.isLocal) {
      throw const CopyApiException('本地小说没有在线收藏标识');
    }
    await transport.requestResults(
      CopyApiProtocol.novelCollectPath,
      method: 'POST',
      authenticated: true,
      formEncoded: true,
      data: CopyApiProtocol.novelCollectBody(book.uuid, value),
    );
  }

  Future<List<Map<String, dynamic>>> _pages(
    String path, {
    bool authenticated = false,
  }) async {
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};
    var offset = 0;
    while (true) {
      final page = novelMap(
        await transport.requestResults(
          path,
          authenticated: authenticated,
          query: CopyApiProtocol.favoritesQuery(
            limit: 18,
            offset: offset,
            ordering: '-datetime_updated',
          ),
          validateResults: (data) => novelMap(data)['list'] is List,
        ),
      );
      final list = novelList(page['list']);
      final total = novelInt(page['total'], offset + list.length);
      if (list.isEmpty) {
        if (offset < total) throw const CopyApiException('小说目录分页提前结束，请重试');
        break;
      }
      final before = result.length;
      for (final item in list) {
        final row = novelMap(item);
        final book = row['book'] is Map ? novelMap(row['book']) : row;
        final id = novelText(book['id'] ?? book['uuid'] ?? book['path_word']);
        if (id.isNotEmpty && seen.add(id)) result.add(row);
      }
      offset += list.length;
      if (offset >= total) break;
      if (result.length == before) throw const CopyApiException('小说目录返回了重复分页');
    }
    return result;
  }

  Future<Uint8List> bytes(
    String url, {
    CancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) => transport.imageBytes(
    url,
    cancelToken: cancelToken,
    onReceiveProgress: onProgress,
  );
}
