import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/chapter.dart';
import '../models/comic.dart';
import '../services/copy_client.dart';
import '../services/online_chapter_book.dart';
import '../services/reader_image_metrics.dart';
import '../services/zip_book.dart';
import 'reading_history_controller.dart';

enum ReaderDirection { horizontal, vertical }

class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.history,
    required this.comic,
    required this.chapter,
    required this.archivePath,
  }) : client = null;

  ReaderController.online({
    required this.history,
    required this.comic,
    required this.chapter,
    required this.client,
  }) : archivePath = null,
       assert(client != null);

  final ReadingHistoryController history;
  final Comic comic;
  final Chapter chapter;
  final String? archivePath;
  final CopyClient? client;

  ZipBook? _book;
  OnlineChapterBook? _onlineBook;
  final Map<int, double> _pageAspectRatios = {};
  final Map<int, Future<String>> _preparingPages = {};
  Timer? _progressSaveTimer;
  Future<void> _progressWrite = Future<void>.value();
  bool _disposed = false;
  bool loading = true;
  String error = '';
  int currentPage = 0;
  ReaderDirection direction = ReaderDirection.vertical;
  bool chromeVisible = false;

  int get pageCount => _book?.length ?? _onlineBook?.length ?? 0;

  bool get isOnline => client != null;

  Future<void> initialize() async {
    try {
      final onlineClient = client;
      if (onlineClient == null) {
        _book = await ZipBook.open(archivePath!);
        // Fix every local page's extent before laying out the two slivers.
        // Bounded header reads do not populate the decoded image cache.
        var nextPage = 0;
        await Future.wait([
          for (var worker = 0; worker < 4; worker++)
            () async {
              while (!_disposed && nextPage < pageCount) {
                await ensurePagePath(nextPage++);
              }
            }(),
        ]);
      } else {
        _onlineBook = await OnlineChapterBook.open(
          client: onlineClient,
          comicPathWord: comic.pathWord,
          chapterUuid: chapter.uuid,
        );
      }
      if (_disposed) return;
      final saved = await history.loadProgress(chapter.uuid);
      if (_disposed) return;
      currentPage = pageCount == 0 ? 0 : saved.clamp(0, pageCount - 1);
      if (isOnline && pageCount > 0) {
        unawaited(_preloadAround(currentPage));
      }
      await history.record(
        comic: comic,
        chapter: chapter,
        pageIndex: currentPage,
        pageCount: pageCount,
      );
    } catch (exception) {
      error = exception.toString();
    } finally {
      loading = false;
      if (_disposed) {
        await _book?.close();
      } else {
        notifyListeners();
      }
    }
  }

  String? cachedPagePath(int index) {
    if (!_pageAspectRatios.containsKey(index)) return null;
    final book = _book;
    if (book != null) return book.pagePath(index);
    return _onlineBook?.cachedPagePath(index);
  }

  Future<String> ensurePagePath(int index) {
    final cached = cachedPagePath(index);
    if (cached != null) return Future<String>.value(cached);
    return _preparingPages.putIfAbsent(
      index,
      () => _preparePage(index).whenComplete(() {
        _preparingPages.remove(index);
      }),
    );
  }

  double pageAspectRatio(int index) =>
      _pageAspectRatios[index] ?? readerPlaceholderAspectRatio;

  Future<String> _preparePage(int index) async {
    final book = _book;
    final onlineBook = _onlineBook;
    if (book == null && onlineBook == null) throw StateError('阅读器尚未初始化');
    final path = book?.pagePath(index) ?? await onlineBook!.pagePath(index);
    _pageAspectRatios[index] = await readReaderImageAspectRatio(path);
    return path;
  }

  void retryPage(int index) => _onlineBook?.retryPage(index);

  Future<void> _preloadAround(int index) async {
    final first = (index - 2).clamp(0, pageCount - 1);
    final last = (index + 2).clamp(0, pageCount - 1);
    await Future.wait([
      for (var page = first; page <= last; page++)
        ensurePagePath(page).then<void>((_) {}, onError: (_) {}),
    ]);
  }

  void changePage(int index) {
    if (pageCount == 0) return;
    final nextPage = index.clamp(0, pageCount - 1);
    if (nextPage == currentPage) return;
    currentPage = nextPage;
    if (isOnline) unawaited(_preloadAround(nextPage));
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(
      const Duration(milliseconds: 150),
      () => _queueProgressWrite(currentPage),
    );
    notifyListeners();
  }

  void _queueProgressWrite(int pageIndex) {
    _progressSaveTimer = null;
    _progressWrite = _progressWrite
        .catchError((_) {})
        .then(
          (_) => history.record(
            comic: comic,
            chapter: chapter,
            pageIndex: pageIndex,
            pageCount: pageCount,
          ),
        );
    unawaited(_progressWrite);
  }

  void toggleChrome() {
    chromeVisible = !chromeVisible;
    notifyListeners();
  }

  void setChromeVisible(bool visible) {
    if (chromeVisible == visible) return;
    chromeVisible = visible;
    notifyListeners();
  }

  void toggleDirection() {
    direction = direction == ReaderDirection.horizontal
        ? ReaderDirection.vertical
        : ReaderDirection.horizontal;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _progressSaveTimer?.cancel();
    if (!loading) {
      if (pageCount > 0) _queueProgressWrite(currentPage);
      unawaited(_book?.close());
    }
    super.dispose();
  }
}
