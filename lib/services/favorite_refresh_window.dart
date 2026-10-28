/// Original 3.0.9 collectOrdering / DatetimeModifierDown: 收藏时间倒序.
/// Do not stop on known IDs when ordering by *comic chapter update* time:
/// a newly collected old book may then be arbitrarily far down the list.
class FavoriteRefreshWindow {
  FavoriteRefreshWindow(Set<String> known) : known = Set.of(known);
  static const ordering = '-datetime_modifier';
  final Set<String> known;
  final Set<String> discovered = {};
  int _knownPages = 0;

  bool accept(List<String> ids, int total) {
    discovered.addAll(ids.where((id) => !known.contains(id)));
    if (ids.isNotEmpty && ids.every(known.contains)) {
      _knownPages++;
    } else {
      _knownPages = 0;
    }
    // Read an overlap page instead of stopping at a single familiar item.
    // A count gap means the imported cache is incomplete: keep paginating.
    return known.isNotEmpty &&
        _knownPages >= 2 &&
        known.length + discovered.length >= total;
  }
}
