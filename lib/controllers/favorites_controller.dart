import 'package:flutter/foundation.dart';

import '../models/comic.dart';
import '../services/copy_client.dart';
import '../services/library_database.dart';

class FavoritesController extends ChangeNotifier {
  FavoritesController({required this.database, required this.client});

  final LibraryDatabase database;
  final CopyClient client;

  bool loading = false;
  String error = '';
  List<Comic> comics = const [];

  Future<void> loadCache() async {
    comics = await database.loadFavorites();
    notifyListeners();
  }

  Future<void> refresh() async {
    loading = true;
    error = '';
    notifyListeners();
    try {
      final remote = await client.favorites();
      await database.replaceFavorites(remote);
      comics = await database.loadFavorites();
    } on CopyApiException catch (exception) {
      error = exception.message;
    } catch (exception) {
      error = '收藏刷新失败：$exception';
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
