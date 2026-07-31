import 'package:flutter/services.dart';

/// Converts both sides of a search to the same Chinese character form.
///
/// The dictionaries are the character mappings from OpenCC. Manga titles and
/// authors keep their original spelling; only the separate search index is
/// normalized.
class ChineseSearchNormalizer {
  ChineseSearchNormalizer({
    Map<int, String>? traditionalToSimplified,
    Map<int, String>? simplifiedToTraditional,
  }) : _traditionalToSimplified = traditionalToSimplified ?? {},
       _simplifiedToTraditional = simplifiedToTraditional ?? {};

  static const dictionaryVersion = 'opencc-character-20260727-v1';

  Map<int, String> _traditionalToSimplified;
  Map<int, String> _simplifiedToTraditional;

  bool get isLoaded =>
      _traditionalToSimplified.isNotEmpty &&
      _simplifiedToTraditional.isNotEmpty;

  Future<void> loadAssets() async {
    final dictionaries = await Future.wait([
      rootBundle.loadString('assets/opencc/TSCharacters.txt'),
      rootBundle.loadString('assets/opencc/STCharacters.txt'),
    ]);
    _traditionalToSimplified = parseDictionary(dictionaries[0]);
    _simplifiedToTraditional = parseDictionary(dictionaries[1]);
  }

  String toSimplified(String value) =>
      _convert(value, _traditionalToSimplified);

  String toTraditional(String value) =>
      _convert(value, _simplifiedToTraditional);

  String normalize(String value) {
    return toSimplified(
      value,
    ).toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  List<String> queryVariants(String value) {
    final raw = value.trim();
    final variants = <String>[];
    for (final candidate in [raw, toSimplified(raw), toTraditional(raw)]) {
      if (candidate.isNotEmpty && !variants.contains(candidate)) {
        variants.add(candidate);
      }
    }
    return variants;
  }

  static Map<int, String> parseDictionary(String source) {
    final result = <int, String>{};
    for (final line in source.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final columns = trimmed.split(RegExp(r'\s+'));
      if (columns.length < 2) continue;
      final sourceRunes = columns.first.runes.toList(growable: false);
      if (sourceRunes.length != 1) continue;
      result[sourceRunes.single] = columns[1];
    }
    return result;
  }

  static String _convert(String value, Map<int, String> dictionary) {
    if (dictionary.isEmpty || value.isEmpty) return value;
    final output = StringBuffer();
    for (final rune in value.runes) {
      output.write(dictionary[rune] ?? String.fromCharCode(rune));
    }
    return output.toString();
  }
}
