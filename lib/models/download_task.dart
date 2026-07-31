enum DownloadState { queued, downloading, paused, completed, failed }

class DownloadTask {
  const DownloadTask({
    required this.chapterUuid,
    required this.comicUuid,
    required this.comicPathWord,
    required this.comicTitle,
    required this.authors,
    required this.groupPathWord,
    required this.groupName,
    required this.chapterTitle,
    required this.chapterOrder,
    required this.state,
    this.progress = 0,
    this.errorMessage = '',
  });

  final String chapterUuid;
  final String comicUuid;
  final String comicPathWord;
  final String comicTitle;
  final String authors;
  final String groupPathWord;
  final String groupName;
  final String chapterTitle;
  final double chapterOrder;
  final DownloadState state;
  final double progress;
  final String errorMessage;

  DownloadTask copyWith({
    DownloadState? state,
    double? progress,
    String? errorMessage,
  }) {
    return DownloadTask(
      chapterUuid: chapterUuid,
      comicUuid: comicUuid,
      comicPathWord: comicPathWord,
      comicTitle: comicTitle,
      authors: authors,
      groupPathWord: groupPathWord,
      groupName: groupName,
      chapterTitle: chapterTitle,
      chapterOrder: chapterOrder,
      state: state ?? this.state,
      progress: progress ?? this.progress,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  factory DownloadTask.fromDatabase(Map<String, Object?> row) {
    final rawState = row['state']?.toString() ?? 'queued';
    return DownloadTask(
      chapterUuid: row['chapter_uuid']?.toString() ?? '',
      comicUuid: row['comic_uuid']?.toString() ?? '',
      comicPathWord: row['comic_path_word']?.toString() ?? '',
      comicTitle: row['comic_title']?.toString() ?? '',
      authors: row['authors']?.toString() ?? '',
      groupPathWord: row['group_path_word']?.toString() ?? 'default',
      groupName: row['group_name']?.toString() ?? '默认',
      chapterTitle: row['chapter_title']?.toString() ?? '',
      chapterOrder: (row['chapter_order'] as num?)?.toDouble() ?? 0,
      state: DownloadState.values.firstWhere(
        (state) => state.name == rawState,
        orElse: () => DownloadState.queued,
      ),
      progress: (row['progress'] as num?)?.toDouble() ?? 0,
      errorMessage: row['error_message']?.toString() ?? '',
    );
  }
}
