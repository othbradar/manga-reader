import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/file_names.dart';
import '../models/chapter.dart';
import '../models/comic.dart';
import '../models/download_task.dart';
import '../services/copy_client.dart';
import '../services/library_database.dart';

class ComicDownloadSelection {
  const ComicDownloadSelection({required this.comic, required this.chapters});

  final Comic comic;
  final Iterable<Chapter> chapters;
}

class DownloadController extends ChangeNotifier {
  DownloadController({
    required this.database,
    required this.client,
    this.pageDownloadMaxAttempts = 5,
    this.pageRetryBaseDelay = const Duration(milliseconds: 700),
  }) : assert(pageDownloadMaxAttempts > 0);

  final LibraryDatabase database;
  final CopyClient client;
  final int pageDownloadMaxAttempts;
  final Duration pageRetryBaseDelay;

  List<DownloadTask> tasks = const [];
  bool globalPaused = true;
  int imageDownloadConcurrency = 4;
  bool _processing = false;
  Completer<void>? _processingDone;
  bool _pauseRequested = false;
  CancelToken? _cancelToken;
  DateTime _lastProgressNotification = DateTime.fromMillisecondsSinceEpoch(0);

  int get queuedCount => tasks
      .where(
        (task) =>
            task.state == DownloadState.queued ||
            task.state == DownloadState.downloading,
      )
      .length;

  Future<void> initialize() async {
    imageDownloadConcurrency =
        int.tryParse(
          await database.setting('image_download_concurrency'),
        )?.clamp(1, 10) ??
        4;
    tasks = await database.loadDownloadTasks();
    globalPaused = !tasks.any((task) => task.state == DownloadState.queued);
    notifyListeners();
    if (!globalPaused) unawaited(resumeAll());
  }

  Future<void> setImageDownloadConcurrency(int value) async {
    final normalized = value.clamp(1, 10);
    if (imageDownloadConcurrency == normalized) return;
    imageDownloadConcurrency = normalized;
    notifyListeners();
    await database.setSetting(
      'image_download_concurrency',
      normalized.toString(),
    );
  }

  Future<int> enqueue(Comic comic, Iterable<Chapter> chapters) async {
    return enqueueBatch([
      ComicDownloadSelection(comic: comic, chapters: chapters),
    ]);
  }

  Future<int> enqueueBatch(Iterable<ComicDownloadSelection> selections) async {
    final existingIds = tasks.map((task) => task.chapterUuid).toSet();
    var added = 0;
    for (final selection in selections) {
      for (final chapter in selection.chapters) {
        if (chapter.isDownloaded || existingIds.contains(chapter.uuid)) {
          continue;
        }
        final task = DownloadTask(
          chapterUuid: chapter.uuid,
          comicUuid: selection.comic.uuid,
          comicPathWord: selection.comic.pathWord,
          comicTitle: selection.comic.title,
          authors: selection.comic.authors,
          groupPathWord: chapter.groupPathWord,
          groupName: chapter.groupName,
          chapterTitle: chapter.title,
          chapterOrder: chapter.order,
          state: DownloadState.queued,
        );
        await database.saveDownloadTask(task);
        added++;
        existingIds.add(chapter.uuid);
      }
    }
    tasks = await database.loadDownloadTasks();
    notifyListeners();
    return added;
  }

  Future<void> resumeAll() async {
    _pauseRequested = false;
    globalPaused = false;
    for (final task in tasks) {
      if (task.state == DownloadState.paused ||
          task.state == DownloadState.failed) {
        await database.updateDownloadTask(
          task.copyWith(state: DownloadState.queued, errorMessage: ''),
        );
      }
    }
    tasks = await database.loadDownloadTasks();
    notifyListeners();
    unawaited(_process());
  }

  Future<void> pauseAll() async {
    _pauseRequested = true;
    globalPaused = true;
    _cancelToken?.cancel('全局暂停');
    for (final task in tasks) {
      if (task.state == DownloadState.queued) {
        await database.updateDownloadTask(
          task.copyWith(state: DownloadState.paused),
        );
      }
    }
    final processingDone = _processingDone;
    if (processingDone != null) await processingDone.future;
    tasks = await database.loadDownloadTasks();
    notifyListeners();
  }

  Future<void> clearCompleted() async {
    await database.clearCompletedTasks();
    tasks = await database.loadDownloadTasks();
    notifyListeners();
  }

  Future<void> clearAllTasks() async {
    _pauseRequested = true;
    globalPaused = true;
    _cancelToken?.cancel('清空下载任务');
    final processingDone = _processingDone;
    if (processingDone != null) await processingDone.future;
    await database.clearDownloadTasks();
    tasks = const [];
    notifyListeners();
  }

  Future<void> retry(DownloadTask task) async {
    await database.updateDownloadTask(
      task.copyWith(state: DownloadState.queued, progress: 0, errorMessage: ''),
    );
    tasks = await database.loadDownloadTasks();
    notifyListeners();
    if (!globalPaused) unawaited(_process());
  }

  Future<void> _process() async {
    if (_processing || globalPaused) return;
    _processing = true;
    final processingDone = Completer<void>();
    _processingDone = processingDone;
    try {
      while (!globalPaused) {
        tasks = await database.loadDownloadTasks();
        final queued = tasks
            .where((task) => task.state == DownloadState.queued)
            .firstOrNull;
        if (queued == null) break;
        await _download(queued);
      }
    } finally {
      _processing = false;
      tasks = await database.loadDownloadTasks();
      notifyListeners();
      if (!processingDone.isCompleted) processingDone.complete();
      if (identical(_processingDone, processingDone)) {
        _processingDone = null;
      }
    }
  }

  Future<void> _download(DownloadTask source) async {
    var task = source.copyWith(
      state: DownloadState.downloading,
      errorMessage: '',
    );
    await database.updateDownloadTask(task);
    _publishTask(task, force: true);
    _cancelToken = CancelToken();
    try {
      final root = database.root;
      if (root == null) throw StateError('漫画库未打开');
      final content = await _loadChapterContentWithRetry(task);
      var pageUrls = List<String>.of(content.urls);
      final comicDirectory = Directory(
        p.join(root.path, comicDirectoryName(task.comicTitle, task.authors)),
      );
      await comicDirectory.create(recursive: true);
      final temporaryDirectory = Directory(
        p.join(root.path, '.download_tmp', task.chapterUuid),
      );
      await temporaryDirectory.create(recursive: true);
      final width = pageUrls.length.toString().length.clamp(3, 6);
      final pageProgress = List<double>.filled(pageUrls.length, 0);
      final existingPageStems = <String>{};
      await for (final entity in temporaryDirectory.list(followLinks: false)) {
        if (entity is File &&
            p.extension(entity.path).toLowerCase() != '.part') {
          existingPageStems.add(p.basenameWithoutExtension(entity.path));
        }
      }
      for (var index = 0; index < pageUrls.length; index++) {
        final stem = (index + 1).toString().padLeft(width, '0');
        if (existingPageStems.contains(stem)) pageProgress[index] = 1;
      }

      void publishCombinedProgress({bool force = false}) {
        final combined = pageProgress.fold<double>(
          0,
          (sum, progress) => sum + progress,
        );
        task = task.copyWith(progress: combined / pageProgress.length);
        _publishTask(task, force: force);
      }

      publishCombinedProgress(force: true);
      Future<void>? addressRefresh;

      Future<void> refreshPageAddresses() {
        final active = addressRefresh;
        if (active != null) return active;
        final refresh = () async {
          try {
            final refreshed = await _loadChapterContentWithRetry(
              task,
              maxAttempts: 2,
            );
            if (refreshed.urls.length != pageUrls.length) {
              throw CopyApiException(
                '刷新章节图片地址后页数发生变化'
                '（${pageUrls.length} → ${refreshed.urls.length}）',
              );
            }
            pageUrls = List<String>.of(refreshed.urls);
          } finally {
            addressRefresh = null;
          }
        }();
        addressRefresh = refresh;
        return refresh;
      }

      Future<void> downloadPage(int index) async {
        final stem = (index + 1).toString().padLeft(width, '0');
        Object? lastFailure;
        Uint8List? downloadedBytes;
        String? downloadedExtension;
        var attemptCount = 0;
        for (var attempt = 1; attempt <= pageDownloadMaxAttempts; attempt++) {
          attemptCount = attempt;
          if (_pauseRequested || globalPaused) {
            throw const _DownloadPaused();
          }
          try {
            final bytes = await client.imageBytes(
              pageUrls[index],
              cancelToken: _cancelToken,
              onReceiveProgress: (received, total) {
                if (total <= 0) return;
                pageProgress[index] = (received / total).clamp(0.0, 1.0);
                publishCombinedProgress();
              },
            );
            downloadedExtension = imageExtensionFromBytes(bytes);
            downloadedBytes = bytes;
            break;
          } on _DownloadPaused {
            rethrow;
          } catch (exception) {
            if (_pauseRequested || globalPaused) {
              throw const _DownloadPaused();
            }
            lastFailure = exception;
            if (attempt >= pageDownloadMaxAttempts ||
                !_isRetryablePageFailure(exception)) {
              break;
            }
            pageProgress[index] = 0;
            publishCombinedProgress(force: true);
            if (_shouldRefreshPageAddresses(exception, attempt)) {
              try {
                await refreshPageAddresses();
              } catch (_) {
                // The next image attempt may still succeed with the existing
                // address. Keep the original image failure for diagnostics.
              }
            }
            await _waitBeforeRetry(attempt, index);
          }
        }
        if (downloadedBytes == null || downloadedExtension == null) {
          throw CopyApiException(
            '第 ${index + 1}/${pageUrls.length} 页下载失败，'
            '已自动重试 ${attemptCount - 1} 次：$lastFailure',
          );
        }

        final partial = File(p.join(temporaryDirectory.path, '$stem.part'));
        final finalFile = File(
          p.join(temporaryDirectory.path, '$stem.$downloadedExtension'),
        );
        if (await partial.exists()) await partial.delete();
        await partial.writeAsBytes(downloadedBytes, flush: true);
        await partial.rename(finalFile.path);
        pageProgress[index] = 1;
        publishCombinedProgress(force: true);
        await database.updateDownloadTask(task);
      }

      var nextPageIndex = 0;
      Future<void> downloadWorker() async {
        while (nextPageIndex < pageUrls.length) {
          if (_pauseRequested || globalPaused) {
            throw const _DownloadPaused();
          }
          final index = nextPageIndex++;
          if (pageProgress[index] >= 1) continue;
          await downloadPage(index);
        }
      }

      final workerCount = imageDownloadConcurrency < pageUrls.length
          ? imageDownloadConcurrency
          : pageUrls.length;
      await Future.wait(List.generate(workerCount, (_) => downloadWorker()));

      final archiveName = chapterArchiveName(
        task.comicTitle,
        task.authors,
        task.chapterTitle,
      );
      final archive = File(p.join(comicDirectory.path, archiveName));
      final partialArchive = File('${archive.path}.partial');
      if (await partialArchive.exists()) await partialArchive.delete();
      final encoder = ZipFileEncoder();
      await encoder.zipDirectory(
        temporaryDirectory,
        filename: partialArchive.path,
      );
      if (await archive.exists()) await archive.delete();
      await partialArchive.rename(archive.path);
      final relative = p.relative(archive.path, from: root.path);
      await database.markChapterDownloaded(task, relative, pageUrls.length);
      try {
        await _cacheCover(task);
      } catch (exception) {
        debugPrint('封面缓存失败，不影响章节下载完成：$exception');
      }
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
      task = task.copyWith(
        state: DownloadState.completed,
        progress: 1,
        errorMessage: '',
      );
      await database.updateDownloadTask(task);
      _publishTask(task, force: true);
    } on _DownloadPaused {
      task = task.copyWith(state: DownloadState.paused);
      await database.updateDownloadTask(task);
      _publishTask(task, force: true);
    } catch (exception) {
      if (_pauseRequested || globalPaused) {
        task = task.copyWith(state: DownloadState.paused);
      } else {
        task = task.copyWith(
          state: DownloadState.failed,
          errorMessage: exception.toString(),
        );
      }
      await database.updateDownloadTask(task);
      _publishTask(task, force: true);
    } finally {
      _cancelToken = null;
      tasks = await database.loadDownloadTasks();
      notifyListeners();
    }
  }

  Future<ChapterContent> _loadChapterContentWithRetry(
    DownloadTask task, {
    int? maxAttempts,
  }) async {
    final attempts = maxAttempts ?? pageDownloadMaxAttempts;
    Object? lastFailure;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (_pauseRequested || globalPaused) throw const _DownloadPaused();
      try {
        return await client.chapterContent(
          comicPathWord: task.comicPathWord,
          chapterUuid: task.chapterUuid,
        );
      } on _DownloadPaused {
        rethrow;
      } catch (exception) {
        if (_pauseRequested || globalPaused) throw const _DownloadPaused();
        lastFailure = exception;
        if (attempt >= attempts) break;
        if (_shouldRefreshPageAddresses(exception, attempt)) {
          try {
            await client.refreshApiDomains();
          } catch (_) {
            // Retry the chapter request even if node discovery itself failed.
          }
        }
        await _waitBeforeRetry(attempt, 0);
      }
    }
    throw CopyApiException('获取章节图片地址失败，已自动重试：$lastFailure');
  }

  bool _isRetryablePageFailure(Object exception) {
    if (exception is FileSystemException || exception is ArgumentError) {
      return false;
    }
    return true;
  }

  bool _shouldRefreshPageAddresses(Object exception, int attempt) {
    if (attempt >= 2) return true;
    if (exception is CopyApiException &&
        const <int>{401, 403, 404, 410}.contains(exception.code)) {
      return true;
    }
    final message = exception.toString().toLowerCase();
    return message.contains('http 401') ||
        message.contains('http 403') ||
        message.contains('http 404') ||
        message.contains('身份认证') ||
        message.contains('unauthorized') ||
        message.contains('forbidden');
  }

  Future<void> _waitBeforeRetry(int failedAttempt, int pageIndex) async {
    final multiplier = 1 << (failedAttempt - 1).clamp(0, 3);
    final jitterMicros = pageRetryBaseDelay.inMicroseconds == 0
        ? 0
        : (pageIndex % 5) * (pageRetryBaseDelay.inMicroseconds ~/ 6);
    var remainingMicros =
        pageRetryBaseDelay.inMicroseconds * multiplier + jitterMicros;
    const sliceMicros = 250000;
    while (remainingMicros > 0) {
      if (_pauseRequested || globalPaused) throw const _DownloadPaused();
      final waitMicros = remainingMicros < sliceMicros
          ? remainingMicros
          : sliceMicros;
      await Future<void>.delayed(Duration(microseconds: waitMicros));
      remainingMicros -= waitMicros;
    }
  }

  Future<void> _cacheCover(DownloadTask task) async {
    final root = database.root;
    final comic = await database.loadComic(task.comicUuid);
    if (root == null || comic == null || comic.coverUrl.isEmpty) return;
    if (comic.coverRelativePath.isNotEmpty &&
        await File(
          absoluteLibraryPath(root.path, comic.coverRelativePath),
        ).exists()) {
      return;
    }
    final directory = Directory(
      p.join(root.path, comicDirectoryName(comic.title, comic.authors)),
    );
    await directory.create(recursive: true);
    final bytes = await client.imageBytes(comic.coverUrl);
    final extension = imageExtensionFromBytes(bytes);
    final file = File(
      p.join(
        directory.path,
        coverFileName(comic.title, comic.authors, extension: extension),
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    await database.setCoverRelativePath(
      comic.uuid,
      p.relative(file.path, from: root.path),
    );
  }

  void _publishTask(DownloadTask task, {bool force = false}) {
    final index = tasks.indexWhere(
      (current) => current.chapterUuid == task.chapterUuid,
    );
    if (index >= 0) {
      final updated = List<DownloadTask>.of(tasks);
      updated[index] = task;
      tasks = List<DownloadTask>.unmodifiable(updated);
    }
    final now = DateTime.now();
    if (force ||
        now.difference(_lastProgressNotification).inMilliseconds >= 250) {
      _lastProgressNotification = now;
      notifyListeners();
    }
  }
}

class _DownloadPaused implements Exception {
  const _DownloadPaused();
}
