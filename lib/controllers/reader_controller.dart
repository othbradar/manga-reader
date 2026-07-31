import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/chapter.dart';
import '../models/comic.dart';
import '../services/copy_client.dart';
import '../services/online_chapter_book.dart';
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
  Timer? _progressSaveTimer;
  Future<void> _progressWrite = Future<void>.value();
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
      } else {
        _onlineBook = await OnlineChapterBook.open(
          client: onlineClient,
          comicPathWord: comic.pathWord,
          chapterUuid: chapter.uuid,
        );
      }
      final saved = await history.loadProgress(chapter.uuid);
      currentPage = pageCount == 0 ? 0 : saved.clamp(0, pageCount - 1);
      if (isOnline && pageCount > 0) {
        unawaited(_onlineBook!.preloadAround(currentPage));
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
      notifyListeners();
    }
  }

  String? cachedPagePath(int index) {
    final book = _book;
    if (book != null) return book.pagePath(index);
    return _onlineBook?.cachedPagePath(index);
  }

  Future<String> ensurePagePath(int index) {
    final book = _book;
    if (book != null) return Future<String>.value(book.pagePath(index));
    final onlineBook = _onlineBook;
    if (onlineBook == null) throw StateError('阅读器尚未初始化');
    return onlineBook.pagePath(index);
  }

  void retryPage(int index) => _onlineBook?.retryPage(index);

  void changePage(int index) {
    if (pageCount == 0) return;
    final nextPage = index.clamp(0, pageCount - 1);
    if (nextPage == currentPage) return;
    currentPage = nextPage;
    if (isOnline) unawaited(_onlineBook!.preloadAround(nextPage));
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
    _progressSaveTimer?.cancel();
    if (pageCount > 0) _queueProgressWrite(currentPage);
    unawaited(_book?.close());
    super.dispose();
  }
}
