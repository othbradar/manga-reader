class Chapter {
  const Chapter({
    required this.uuid,
    required this.comicUuid,
    required this.groupPathWord,
    required this.groupName,
    required this.title,
    required this.order,
    this.pageCount = 0,
    this.archiveRelativePath = '',
  });

  final String uuid;
  final String comicUuid;
  final String groupPathWord;
  final String groupName;
  final String title;
  final double order;
  final int pageCount;
  final String archiveRelativePath;

  bool get isDownloaded => archiveRelativePath.isNotEmpty;

  factory Chapter.fromDatabase(Map<String, Object?> row) {
    return Chapter(
      uuid: row['chapter_uuid']?.toString() ?? '',
      comicUuid: row['comic_uuid']?.toString() ?? '',
      groupPathWord: row['group_path_word']?.toString() ?? 'default',
      groupName: row['group_name']?.toString() ?? '默认',
      title: row['chapter_title']?.toString() ?? '',
      order: (row['chapter_order'] as num?)?.toDouble() ?? 0,
      pageCount: (row['page_count'] as num?)?.toInt() ?? 0,
      archiveRelativePath: row['archive_relative_path']?.toString() ?? '',
    );
  }

  factory Chapter.fromApi(
    Map<String, dynamic> row, {
    required String comicUuid,
    required String groupPathWord,
    required String groupName,
  }) {
    return Chapter(
      uuid: row['uuid']?.toString() ?? '',
      comicUuid: comicUuid,
      groupPathWord: row['group_path_word']?.toString() ?? groupPathWord,
      groupName: groupName,
      title: row['name']?.toString() ?? '',
      order:
          (row['ordered'] as num?)?.toDouble() ??
          double.tryParse(row['ordered']?.toString() ?? '') ??
          0,
      pageCount: (row['size'] as num?)?.toInt() ?? 0,
    );
  }
}
