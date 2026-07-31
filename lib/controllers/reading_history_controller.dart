import 'package:flutter/foundation.dart';

import '../models/chapter.dart';
import '../models/comic.dart';
import '../models/recent_view.dart';
import '../services/local_app_database.dart';

class ReadingHistoryController extends ChangeNotifier {
  ReadingHistoryController(this.database);

  final LocalAppDatabase database;

  List<RecentView> recentViews = const [];

  Future<void> initialize() async {
    recentViews = await database.loadRecentViews();
    notifyListeners();
  }

  Future<int> loadProgress(String chapterUuid) {
    return database.loadReadProgress(chapterUuid);
  }

  Future<void> record({
    required Comic comic,
    required Chapter chapter,
    required int pageIndex,
    required int pageCount,
  }) async {
    final maxPage = pageCount > 0 ? pageCount - 1 : 0;
    final view = RecentView(
      comic: comic,
      chapterUuid: chapter.uuid,
      chapterTitle: chapter.title,
      pageIndex: pageIndex.clamp(0, maxPage),
      pageCount: pageCount,
      viewedAt: DateTime.now(),
    );
    recentViews = [
      view,
      ...recentViews.where((item) => item.comic.uuid != comic.uuid),
    ];
    notifyListeners();
    await database.saveReadingState(view);
  }
}
