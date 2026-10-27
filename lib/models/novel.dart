class Novel {
  const Novel({
    required this.uuid,
    required this.pathWord,
    required this.title,
    required this.authors,
    this.alias = '',
    this.brief = '',
    this.coverUrl = '',
    this.relativeDir = '',
    this.coverRelativePath = '',
    this.source = 'copy_manga',
    this.order = 0,
    this.titleSortKey = '',
    this.downloadedVolumes = 0,
  });

  final String uuid, pathWord, title, authors, alias, brief, coverUrl;
  final String relativeDir, coverRelativePath, source, titleSortKey;
  final int order, downloadedVolumes;
  bool get isLocal => pathWord.startsWith('local-');
  String get identity => uuid.isEmpty ? 'path:$pathWord' : uuid;

  factory Novel.fromApi(Map<String, dynamic> data) {
    final value = data['book'] is Map ? novelMap(data['book']) : data;
    return Novel(
      uuid: novelText(value['uuid']),
      pathWord: novelText(value['path_word']),
      title: novelText(value['name']),
      authors: novelNames(value['author']),
      alias: novelText(value['alias']),
      brief: novelText(value['brief']),
      coverUrl: novelText(value['cover']),
    );
  }

  factory Novel.fromRow(Map<String, Object?> row) => Novel(
    uuid: novelText(row['novel_uuid']),
    pathWord: novelText(row['path_word']),
    title: novelText(row['title']),
    authors: novelText(row['authors']),
    alias: novelText(row['alias']),
    brief: novelText(row['brief']),
    coverUrl: novelText(row['cover_url']),
    relativeDir: novelText(row['relative_dir']),
    coverRelativePath: novelText(row['cover_relative_path']),
    source: novelText(row['source_kind']),
    order: novelInt(row['library_order']),
    titleSortKey: novelText(row['title_sort_key']),
    downloadedVolumes: novelInt(row['downloaded_volumes']),
  );

  Map<String, Object?> toRow() => {
    'novel_uuid': uuid,
    'path_word': pathWord,
    'title': title,
    'authors': authors,
    'alias': alias,
    'brief': brief,
    'cover_url': coverUrl,
    'relative_dir': relativeDir,
    'cover_relative_path': coverRelativePath,
    'source_kind': source,
    'library_order': order,
    'title_sort_key': titleSortKey,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  };

  Novel withFiles({
    String? directory,
    String? cover,
    String? source,
    int? order,
    String? titleSortKey,
  }) => Novel(
    uuid: uuid,
    pathWord: pathWord,
    title: title,
    authors: authors,
    alias: alias,
    brief: brief,
    coverUrl: coverUrl,
    relativeDir: directory ?? relativeDir,
    coverRelativePath: cover ?? coverRelativePath,
    source: source ?? this.source,
    order: order ?? this.order,
    titleSortKey: titleSortKey ?? this.titleSortKey,
    downloadedVolumes: downloadedVolumes,
  );
}

class NovelVolume {
  const NovelVolume({
    required this.novelUuid,
    required this.id,
    required this.title,
    this.order = 0,
    this.textUrl = '',
    this.encoding = 'UTF-8',
    this.relativePath = '',
    this.downloaded = false,
    this.sections = const [],
  });
  final String novelUuid, id, title, textUrl, encoding, relativePath;
  final double order;
  final bool downloaded;
  final List<NovelSection> sections;

  factory NovelVolume.fromApi(Map<String, dynamic> value, String novelUuid) =>
      NovelVolume(
        novelUuid: novelUuid,
        id: novelText(value['id']),
        title: novelText(value['name']),
        order: (value['sort'] as num?)?.toDouble() ?? 0,
        textUrl: novelText(value['txt_addr']),
        encoding: novelText(value['txt_encoding']).isEmpty
            ? 'UTF-8'
            : novelText(value['txt_encoding']),
        sections: [
          for (final (i, item) in novelList(value['contents']).indexed)
            NovelSection.fromApi(novelMap(item), i),
        ],
      );

  factory NovelVolume.fromRow(
    Map<String, Object?> row, {
    List<NovelSection> sections = const [],
  }) => NovelVolume(
    novelUuid: novelText(row['novel_uuid']),
    id: novelText(row['volume_id']),
    title: novelText(row['title']),
    order: (row['volume_order'] as num?)?.toDouble() ?? 0,
    textUrl: novelText(row['txt_url']),
    encoding: novelText(row['txt_encoding']),
    relativePath: novelText(row['txt_relative_path']),
    downloaded: novelInt(row['is_downloaded']) == 1,
    sections: sections,
  );
}

class NovelSection {
  const NovelSection({
    required this.index,
    required this.title,
    this.type = 1,
    this.start = 0,
    this.end = 0,
    this.imageUrl = '',
    this.imagePath = '',
  });
  final int index, type, start, end;
  final String title, imageUrl, imagePath;
  bool get isImage => type == 2;
  factory NovelSection.fromApi(Map<String, dynamic> data, int index) =>
      NovelSection(
        index: index,
        title: novelText(data['name']),
        type: novelInt(data['content_type'], 1),
        start: novelInt(data['start_lines']),
        end: novelInt(data['end_lines']),
        imageUrl: novelInt(data['content_type']) == 2
            ? novelText(data['content'])
            : '',
      );
  factory NovelSection.fromRow(Map<String, Object?> row) => NovelSection(
    index: novelInt(row['section_index']),
    title: novelText(row['title']),
    type: novelInt(row['content_type'], 1),
    start: novelInt(row['start_line']),
    end: novelInt(row['end_line']),
    imageUrl: novelText(row['image_url']),
    imagePath: novelText(row['image_relative_path']),
  );
}

Map<String, dynamic> novelMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<dynamic> novelList(Object? value) => value is List ? value : const [];
String novelText(Object? value) => value?.toString() ?? '';
int novelInt(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse(novelText(value)) ?? fallback;
String novelNames(Object? value) => value is List
    ? value
          .map(
            (item) => item is Map ? novelText(item['name']) : novelText(item),
          )
          .where((x) => x.isNotEmpty)
          .join('、')
    : novelText(value);
