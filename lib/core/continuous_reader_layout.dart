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
    return builderIndex;
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
