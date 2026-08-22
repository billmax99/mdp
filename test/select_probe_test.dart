import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hmd/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('长按正文弹出划线菜单', (t) async {
    SharedPreferences.setMockInitialValues({});
    await initPrefs();
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't选择.md',
        initialContent: '# 标\n\n你好世界正文内容OK好的',
      ),
    ));
    await t.pumpAndSettle();
    final target = find.text('你好世界正文内容OK好的').hitTestable();
    // ignore: avoid_print
    print('TEXT_FOUND: ${target.evaluate().length}');
    final rect = t.getRect(target.first);
    final g = await t.startGesture(rect.center);
    await t.pump(const Duration(milliseconds: 700)); // 超过长按阈值
    await g.up();
    await t.pumpAndSettle();
    final menu = find.text('划线').evaluate().length;
    // ignore: avoid_print
    print('MENU_ITEMS: $menu');
    expect(menu, greaterThan(0));
  });
}
