import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hmd/main.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await initPrefs();
  });
  // 跨段选择→高亮：每块一条标注、共用 id（整组删除）
  testWidgets('跨段选择高亮拆段', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: '跨段.md',
        initialContent: '# 标\n\n第一段甲乙丙。\n\n第二段丁戊己。',
      ),
    ));
    await t.pumpAndSettle();
    final r1 = t.getRect(find.textContaining('第一段甲乙丙。'));
    final r2 = t.getRect(find.textContaining('第二段丁戊己。'));
    final g = await t.startGesture(Offset(r1.left + 30, r1.center.dy));
    await t.pump(const Duration(milliseconds: 700)); // 长按先选中词
    // 拖拽扩选跨段
    await g.moveTo(Offset(r1.right - 10, r1.center.dy), timeStamp: const Duration(milliseconds: 200));
    await g.moveTo(Offset(r2.left + 60, r2.center.dy), timeStamp: const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 100));
    await g.up();
    await t.pumpAndSettle();
    expect(find.text('高亮'), findsOneWidget);
    await t.tap(find.text('高亮'));
    await t.pumpAndSettle();
    final marks = loadMarks('跨段.md');
    expect(marks.length, 2); // 两块各一条
    expect(marks.first.id, marks.last.id); // 共用 id
    expect(marks.map((m) => m.page).toSet(), {1, 2});
  });
}
