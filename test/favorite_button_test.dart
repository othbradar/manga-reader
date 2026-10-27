import 'dart:async';

import 'package:copymanga_reader/widgets/favorite_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('收藏按钮先查询，防重复点击，取消需要确认', (tester) async {
    var selected = false;
    final writes = <bool>[];
    final pending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteButton(
            scope: 'account-one',
            loggedIn: true,
            loadSelected: () async => selected,
            setSelected: (value) async {
              writes.add(value);
              if (value) await pending.future;
              selected = value;
            },
            onLogin: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pump();
    await tester.tap(find.text('收藏'));
    expect(writes, [true]);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('已收藏'), findsOneWidget);
    await tester.tap(find.text('已收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(writes, [true]);
    await tester.tap(find.text('已收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '取消收藏'));
    await tester.pumpAndSettle();
    expect(writes, [true, false]);
    expect(find.text('收藏'), findsOneWidget);
  });

  testWidgets('不明确的写入失败只允许重新读取状态，不重发收藏', (tester) async {
    var reads = 0, writes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteButton(
            scope: 'account-one',
            loggedIn: true,
            loadSelected: () async => ++reads > 1,
            setSelected: (value) async {
              writes++;
              throw Exception('服务暂时不可用');
            },
            onLogin: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    await tester.tap(find.text('重试收藏状态'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(writes, 1);
    expect(find.text('已收藏'), findsOneWidget);
  });

  testWidgets('切换账号丢弃旧请求结果，未登录只打开登录页', (tester) async {
    final oldRead = Completer<bool>();
    var loggedIn = true;
    var account = 'old';
    var logins = 0;
    Widget build() => MaterialApp(
      home: Scaffold(
        body: FavoriteButton(
          scope: account,
          loggedIn: loggedIn,
          loadSelected: () =>
              account == 'old' ? oldRead.future : Future.value(false),
          setSelected: (_) async => fail('不应写入收藏'),
          onLogin: () async {
            logins++;
          },
        ),
      ),
    );
    await tester.pumpWidget(build());
    account = 'new';
    await tester.pumpWidget(build());
    oldRead.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('已收藏'), findsNothing);
    loggedIn = false;
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    expect(logins, 1);
  });
}
