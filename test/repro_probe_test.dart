import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hmd/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('复刻模拟器场景：inj1+inj2 渲染', (t) async {
    SharedPreferences.setMockInitialValues({});
    await initPrefs();
    final m1 = Mark('inj1', '明月', '床前', '光', 1, false, false, 0);
    final m2 = Mark('inj2', 'great', 'is ', '. Fl', 2, true, false, 0);
    await saveMarks('测试.md', [m1, m2]);
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('green'),
      home: const ReaderScreen(
        path: 't.md',
        title: '测试.md',
        initialContent: '# 测试文档\n\nFlutter is great. Flutter rocks.\n\n床前明月光，疑是地上霜。\n\n## 第二章\n\n白日依山尽，黄河入海流。Flutter everywhere.\n',
      ),
    ));
    await t.pumpAndSettle();
    // 找带背景(黄)的 span 与带波浪线的 span
    bool hasBg = false, hasWavy = false;
    void scan(InlineSpan s) {
      if (s is TextSpan) {
        if (s.style?.background != null) hasBg = true;
        if (s.style?.decorationStyle == TextDecorationStyle.wavy) hasWavy = true;
        for (final c in s.children ?? const <InlineSpan>[]) {
          scan(c);
        }
      }
    }
    for (final w in find.byType(RichText).evaluate()) {
      scan((w.widget as RichText).text);
    }
    print('HAS_BG=$hasBg HAS_WAVY=$hasWavy');
    expect(hasBg, isTrue);
    expect(hasWavy, isTrue);
  });
}
