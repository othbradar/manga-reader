import 'dart:convert';
import 'package:fast_gbk/fast_gbk.dart';

/// Keep the original line numbers: upstream section end positions are exclusive.
String decodeNovelText(List<int> data, {String encoding = 'UTF-8'}) {
  final normalized = encoding.toUpperCase().replaceAll('_', '-');
  final String text;
  if ({'GBK', 'GB2312'}.contains(normalized)) {
    text = gbk.decode(data);
  } else if (data.length >= 2 &&
      ((data[0] == 255 && data[1] == 254) ||
          (data[0] == 254 && data[1] == 255))) {
    final little = data[0] == 255;
    if (data.length.isOdd) throw const FormatException('UTF-16 小说文本被截断');
    text = String.fromCharCodes([
      for (var i = 2; i < data.length; i += 2)
        little ? data[i] | (data[i + 1] << 8) : (data[i] << 8) | data[i + 1],
    ]);
  } else if (!{'UTF-8', 'UTF8', 'ASCII', ''}.contains(normalized)) {
    throw FormatException('暂不支持小说编码 $encoding，未把乱码保存为下载成功');
  } else {
    text = utf8.decode(data).replaceFirst(RegExp('^\uFEFF'), '');
  }
  if (text.trim().isEmpty ||
      RegExp(r'^\s*<(?:!doctype|html)', caseSensitive: false).hasMatch(text)) {
    throw const FormatException('小说返回了空文本或错误页面');
  }
  return text;
}

List<String> novelLines(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

String localNovelPlainText(String text) {
  if (!RegExp(r'<(?:br|p|img)\b', caseSensitive: false).hasMatch(text)) {
    return text;
  }
  return text
      .replaceAll(RegExp(r'<br\s*/?>|</p>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'<img\b[^>]*>', caseSensitive: false),
        '\n[原文件中的在线插图]\n',
      )
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}
