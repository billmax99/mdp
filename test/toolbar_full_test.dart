import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hmd/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('弹出框四功能完整链路：高亮→点击→复制→删除', (t) async {
    // mock 剪贴板平台通道（测试环境无真实通道会挂起）
    var lastCopied = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        lastCopied = (call.arguments as Map)['text'] as String;
        return null;
      }
      if (call.method == 'Clipboard.getData') return {'text': lastCopied};
      return null;
    });

    SharedPreferences.setMockInitialValues({});
    await initPrefs();
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't全链.md', initialContent: '# 标\n\n你好世界正文OK',
      ),
    ));
    await t.pumpAndSettle();

    // 1) 长按选词 → 选词工具条出现（文字真实可见）
    final g = await t.startGesture(t.getCenter(find.text('你好世界正文OK')));
    await t.pump(const Duration(milliseconds: 700));
    await g.up();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('划线'), findsOneWidget);
    expect(find.text('高亮'), findsOneWidget);
    expect(t.getSize(find.text('高亮')).height, greaterThan(12));

    // 2) 点高亮 → 保存
    await t.tap(find.text('高亮').first);
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(prefs.getStringList('marks_t全链.md'), isNotEmpty);

    // 3) 点击已标注 → 点击菜单 → 复制 → 剪贴板
    await t.pump(const Duration(milliseconds: 200));
    await t.tapAt(t.getCenter(find.text('你好世界正文OK')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(t.getSize(find.text('复制')).height, greaterThan(12));
    await t.tap(find.text('复制').first);
    await t.pump(const Duration(milliseconds: 300));
    final clip = await Clipboard.getData('text/plain');
    expect(clip?.text, isNotEmpty);

    // 4) 再点标注 → 删除 → 标注清空
    await t.pump(const Duration(milliseconds: 300));
    await t.tapAt(t.getCenter(find.text('你好世界正文OK')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('删除'), findsOneWidget);
    await t.tap(find.text('删除').first);
    await t.pumpAndSettle();
    expect(prefs.getStringList('marks_t全链.md'), isEmpty);
  });
}
