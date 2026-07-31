import 'comic.dart';

class RecentView {
  const RecentView({
    required this.comic,
    required this.chapterUuid,
    required this.chapterTitle,
    required this.pageIndex,
    required this.pageCount,
    required this.viewedAt,
  });

  final Comic comic;
  final String chapterUuid;
  final String chapterTitle;
  final int pageIndex;
  final int pageCount;
  final DateTime viewedAt;

  factory RecentView.fromDatabase(Map<String, Object?> row) {
    return RecentView(
      comic: Comic.fromDatabase({
        'comic_uuid': row['comic_uuid'],
        'path_word': row['path_word'],
        'title': row['title'],
        'authors': row['authors'],
        'comic_relative_dir': row['comic_relative_dir'],
        'cover_url': row['cover_url'],
        'cover_relative_path': row['cover_relative_path'],
        'source_kind': row['source_kind'],
        'library_order': row['library_order'],
        'title_sort_key': row['title_sort_key'],
      }),
      chapterUuid: row['chapter_uuid']?.toString() ?? '',
      chapterTitle: row['chapter_title']?.toString() ?? '',
      pageIndex: (row['page_index'] as num?)?.toInt() ?? 0,
      pageCount: (row['page_count'] as num?)?.toInt() ?? 0,
      viewedAt:
          DateTime.tryParse(row['viewed_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
