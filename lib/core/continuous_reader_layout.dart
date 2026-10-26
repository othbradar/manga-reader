class ContinuousReaderLayout {
  const ContinuousReaderLayout({
    required this.pageCount,
    required this.anchorPage,
  }) : assert(pageCount >= 0),
       assert(anchorPage >= 0),
       assert(pageCount == 0 || anchorPage < pageCount);

  final int pageCount;
  final int anchorPage;

  int get beforeAnchorCount => anchorPage;

  int get fromAnchorCount => pageCount - anchorPage;

  int pageBeforeAnchor(int builderIndex) {
    if (builderIndex < 0 || builderIndex >= beforeAnchorCount) {
      throw RangeError.index(
        builderIndex,
        List<void>.filled(beforeAnchorCount, null),
      );
    }
    // Slivers before CustomScrollView.center grow in reverse: child zero is
    // directly above the anchor, not the first page of the chapter.
    return anchorPage - 1 - builderIndex;
  }

  int pageFromAnchor(int builderIndex) {
    if (builderIndex < 0 || builderIndex >= fromAnchorCount) {
      throw RangeError.index(
        builderIndex,
        List<void>.filled(fromAnchorCount, null),
      );
    }
    return anchorPage + builderIndex;
  }
}
