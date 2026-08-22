// 最小自检：主页渲染 + Markdown 渲染 + 字号切换逻辑
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hmd/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await initPrefs();
    appFont.value = 18;
    appDark.value = false;
  });

  testWidgets('主页：标题与大按钮存在，无 recent 时空状态可见', (t) async {
    await t.pumpWidget(const HmdApp());
    await t.pumpAndSettle();
    expect(find.text('MD 阅读器'), findsOneWidget);
    expect(find.text('打开 .md 文件'), findsOneWidget);
    expect(find.text('还没有文档'), findsOneWidget);
  });

  testWidgets('阅读页：渲染 md 标题与正文', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme(Brightness.light),
      home: const ReaderScreen(
        path: 'test.md',
        title: '测试.md',
        initialContent: '# 一级标题\n\n你好，**世界**。\n\n- 列表项',
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('一级标题'), findsOneWidget);
    expect(find.text('你好，世界。'), findsOneWidget);
    expect(find.text('列表项'), findsOneWidget);
    expect(find.byIcon(Icons.text_increase_rounded), findsOneWidget);
  });

  testWidgets('阅读页：点 A+ 增大字号并持久化，到上限禁用', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme(Brightness.light),
      home: const ReaderScreen(
          path: 'test.md', title: '字号.md', initialContent: '正文'),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.text_increase_rounded));
    await t.pump();
    expect(appFont.value, 19);
    expect(prefs.getDouble('fontSize'), 19);

    appFont.value = 28; // 直接顶到上限，验证按钮禁用逻辑
    await t.pump();
    final btn = t.widget<IconButton>(
        find.ancestor(of: find.byTooltip('增大字号'), matching: find.byType(IconButton)));
    expect(btn.onPressed, isNull);
  });

  test('safeName 清理非法字符', () {
    expect(safeName('a/b\\c:d*e?f"g<h>i|.md'), 'a_b_c_d_e_f_g_h_i_.md');
  });
}
