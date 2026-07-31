enum ComicSource {
  dmzj('dmzj'),
  copyManga('copy_manga'),
  both('both');

  const ComicSource(this.databaseValue);

  final String databaseValue;

  static ComicSource fromDatabase(Object? value) {
    final raw = value?.toString();
    return ComicSource.values.firstWhere(
      (source) => source.databaseValue == raw,
      orElse: () => ComicSource.copyManga,
    );
  }
}

class Comic {
  const Comic({
    required this.uuid,
    required this.pathWord,
    required this.title,
    required this.authors,
    this.comicRelativeDir = '',
    this.coverUrl = '',
    this.coverRelativePath = '',
    this.alias = '',
    this.brief = '',
    this.status = '',
    this.lastChapter = '',
    this.downloadedChapters = 0,
    this.totalChapters = 0,
    this.isFavorite = false,
    this.source = ComicSource.copyManga,
    this.libraryOrder = 0,
    this.titleSortKey = '',
  });

  final String uuid;
  final String pathWord;
  final String title;
  final String authors;
  final String comicRelativeDir;
  final String coverUrl;
  final String coverRelativePath;
  final String alias;
  final String brief;
  final String status;
  final String lastChapter;
  final int downloadedChapters;
  final int totalChapters;
  final bool isFavorite;
  final ComicSource source;
  final int libraryOrder;
  final String titleSortKey;

  bool get hasDownloadedChapter => downloadedChapters > 0;
  String get stableIdentity {
    if (uuid.isNotEmpty) return uuid;
    if (pathWord.isNotEmpty) return 'path:$pathWord';
    return 'title:$title|$authors';
  }

  Comic copyWith({
    String? uuid,
    String? pathWord,
    String? title,
    String? authors,
    String? comicRelativeDir,
    String? coverUrl,
    String? coverRelativePath,
    String? alias,
    String? brief,
    String? status,
    String? lastChapter,
    int? downloadedChapters,
    int? totalChapters,
    bool? isFavorite,
    ComicSource? source,
    int? libraryOrder,
    String? titleSortKey,
  }) {
    return Comic(
      uuid: uuid ?? this.uuid,
      pathWord: pathWord ?? this.pathWord,
      title: title ?? this.title,
      authors: authors ?? this.authors,
      comicRelativeDir: comicRelativeDir ?? this.comicRelativeDir,
      coverUrl: coverUrl ?? this.coverUrl,
      coverRelativePath: coverRelativePath ?? this.coverRelativePath,
      alias: alias ?? this.alias,
      brief: brief ?? this.brief,
      status: status ?? this.status,
      lastChapter: lastChapter ?? this.lastChapter,
      downloadedChapters: downloadedChapters ?? this.downloadedChapters,
      totalChapters: totalChapters ?? this.totalChapters,
      isFavorite: isFavorite ?? this.isFavorite,
      source: source ?? this.source,
      libraryOrder: libraryOrder ?? this.libraryOrder,
      titleSortKey: titleSortKey ?? this.titleSortKey,
    );
  }

  factory Comic.fromDatabase(Map<String, Object?> row) {
    return Comic(
      uuid: _text(row['comic_uuid']),
      pathWord: _text(row['path_word']),
      title: _text(row['title']),
      authors: _text(row['authors']),
      comicRelativeDir: _text(row['comic_relative_dir']),
      coverUrl: _text(row['cover_url']),
      coverRelativePath: _text(row['cover_relative_path']),
      alias: _text(row['alias']),
      brief: _text(row['brief']),
      status: _text(row['status']),
      lastChapter: _text(row['last_chapter']),
      downloadedChapters: _integer(row['downloaded_chapters']),
      totalChapters: _integer(row['total_chapters']),
      isFavorite: _integer(row['is_favorite']) == 1,
      source: ComicSource.fromDatabase(row['source_kind']),
      libraryOrder: _integer(row['library_order']),
      titleSortKey: _text(row['title_sort_key']),
    );
  }

  factory Comic.fromApi(Map<String, dynamic> data, {bool favorite = false}) {
    final comic = data['comic'] is Map
        ? Map<String, dynamic>.from(data['comic'] as Map)
        : data;
    final authors = _names(comic['author']);
    final statusValue = comic['status'];
    final lastChapter = comic['last_chapter'] ?? comic['lastChapter'];
    return Comic(
      uuid: _text(comic['uuid']),
      pathWord: _text(comic['path_word'] ?? comic['pathWord']),
      title: _text(comic['name'] ?? comic['title']),
      authors: authors,
      coverUrl: _text(comic['cover']),
      alias: _text(comic['alias']),
      brief: _text(comic['brief']),
      status: statusValue is Map
          ? _text(statusValue['display'])
          : _text(statusValue),
      lastChapter: lastChapter is Map
          ? _text(lastChapter['name'])
          : _text(comic['last_chapter_name'] ?? lastChapter),
      isFavorite: favorite,
    );
  }

  static String _names(Object? value) {
    if (value is! List) return '';
    return value
        .map((item) {
          if (item is Map) return _text(item['name']);
          return _text(item);
        })
        .where((name) => name.isNotEmpty)
        .join('、');
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';

  static int _integer(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
