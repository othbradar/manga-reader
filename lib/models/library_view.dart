import 'comic.dart';

enum ComicSourceFilter { all, dmzj, copyManga, both }

enum ComicSortMode { original, titleInitial }

extension ComicSourceFilterLabel on ComicSourceFilter {
  String get label => switch (this) {
    ComicSourceFilter.all => '全部',
    ComicSourceFilter.dmzj => '动漫之家独有',
    ComicSourceFilter.copyManga => '拷贝漫画独有',
    ComicSourceFilter.both => '两边都有',
  };

  bool accepts(Comic comic) => switch (this) {
    ComicSourceFilter.all => true,
    ComicSourceFilter.dmzj => comic.source == ComicSource.dmzj,
    ComicSourceFilter.copyManga => comic.source == ComicSource.copyManga,
    ComicSourceFilter.both => comic.source == ComicSource.both,
  };
}

extension ComicSortModeLabel on ComicSortMode {
  String get label => switch (this) {
    ComicSortMode.original => '原先顺序',
    ComicSortMode.titleInitial => '首字母',
  };
}
