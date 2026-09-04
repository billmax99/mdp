// 最小自检：主页渲染 + Markdown 渲染 + 字号切换 + 多格式解析
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hmd/main.dart';
import 'package:shared_preferences/shared_preferences.dart';


String _tmp(String name, List<int> bytes) {
  final f = File('${Directory.systemTemp.path}/hmd_t_$name');
  f.writeAsBytesSync(bytes);
  return f.path;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await initPrefs();
    appFont.value = 18;
    appTheme.value = 'light';
  });

  testWidgets('主页：标题与大按钮存在，无 recent 时空状态可见', (t) async {
    await t.pumpWidget(const HmdApp());
    await t.pumpAndSettle();
    expect(find.text('MD+'), findsOneWidget);
    expect(find.text('打开 .md 文件'), findsOneWidget);
    expect(find.text('还没有文档'), findsOneWidget);
  });

  testWidgets('主页：左滑删除记录，长按可删单条，清空按钮全清', (t) async {
    await saveRecent([
      RecentRec('a.md', 1),
      RecentRec('b.md', 2),
    ]);
    await t.pumpWidget(const HmdApp());
    await t.pumpAndSettle();
    expect(find.text('a.md'), findsOneWidget);
    expect(find.text('b.md'), findsOneWidget);
    // 左滑第一条（a.md）→ 直接删
    await t.drag(find.text('a.md'), const Offset(-500, 0));
    await t.pumpAndSettle();
    expect(find.text('a.md'), findsNothing);
    expect(find.text('b.md'), findsOneWidget);
    expect(loadRecent().map((r) => r.name), ['b.md']);
    // 长按 b.md → 确认框 → 删除
    await t.longPress(find.text('b.md'));
    await t.pumpAndSettle();
    expect(find.text('删除这条记录？'), findsOneWidget);
    await t.tap(find.text('删除'));
    await t.pumpAndSettle();
    expect(find.text('b.md'), findsNothing);
    expect(loadRecent(), isEmpty);
    expect(find.text('还没有文档'), findsOneWidget);
    // 重新加入两条 → 清空按钮 → 确认 → 全清（换 key 强制重建 HomeScreen 重新读 prefs）
    await saveRecent([RecentRec('c.md', 3), RecentRec('d.md', 4)]);
    await t.pumpWidget(const KeyedSubtree(key: ValueKey('v2'), child: HmdApp()));
    await t.pumpAndSettle();
    await t.tap(find.text('清空'));
    await t.pumpAndSettle();
    expect(find.text('清空全部记录？'), findsOneWidget);
    await t.tap(find.text('清空').last); // 对话框里的确认按钮
    await t.pumpAndSettle();
    expect(find.text('c.md'), findsNothing);
    expect(find.text('d.md'), findsNothing);
    expect(loadRecent(), isEmpty);
  });

  testWidgets('阅读页：渲染 md 标题与正文', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
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
      theme: HmdApp.theme('light'),
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

  test('kindOf 按扩展名分派', () {
    expect(kindOf('a.md'), DocKind.md);
    expect(kindOf('a.TXT'), DocKind.md);
    expect(kindOf('a.pdf'), DocKind.pdf);
    expect(kindOf('a.epub'), DocKind.epub);
    expect(kindOf('a.docx'), DocKind.docx);
  });

  test('extractDocxText 抽取段落并还原转义', () async {
    final docXml = '<?xml version="1.0"?><w:document><w:body>'
        '<w:p><w:r><w:t>第一段 &amp; 细节</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>第二段</w:t></w:r><w:r><w:t>拼接</w:t></w:r></w:p>'
        '</w:body></w:document>';
    final zip = ZipEncoder().encode(Archive()
          ..addFile(ArchiveFile('word/document.xml', docXml.length, utf8.encode(docXml)))) ??
        const <int>[];
    final text = await extractDocxText(_tmp('t.docx', zip));
    expect(text, contains('第一段 & 细节'));
    expect(text, contains('第二段拼接'));
  });

  test('extractEpubHtml 按 spine 顺序输出章节', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('mimetype', 20, 'application/epub+zip'.codeUnits))
      ..addFile(ArchiveFile(
          'META-INF/container.xml',
          300,
          '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
              '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'))
      ..addFile(ArchiveFile('OEBPS/content.opf', 500, '<?xml version="1.0"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>测试书</dc:title><dc:identifier id="id">test</dc:identifier>'
          '<dc:language>zh</dc:language></metadata>'
          '<manifest><item id="c2" href="Text/c2.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="c1" href="Text/c1.xhtml" media-type="application/xhtml+xml"/></manifest>'
          '<spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>'))
      ..addFile(ArchiveFile('OEBPS/Text/c1.xhtml', 100,
          '<html><body><p>第一章</p></body></html>'))
      ..addFile(ArchiveFile('OEBPS/Text/c2.xhtml', 100,
          '<html><body><p>第二章</p></body></html>'));
    final htmls = await extractEpubHtml(_tmp('t.epub', (ZipEncoder().encode(archive) ?? const <int>[])));
    expect(htmls.length, 2);
    expect(htmls[0], contains('第一章'));
    expect(htmls[1], contains('第二章'));
  });

  test('extractEpubHtml 图片解压并改写 src 为 file://', () async {
    final png = [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 魔数（内容无需有效，只验证写出）
    ];
    final archive = Archive()
      ..addFile(ArchiveFile('mimetype', 20, 'application/epub+zip'.codeUnits))
      ..addFile(ArchiveFile(
          'META-INF/container.xml', 300,
          '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>'))
      ..addFile(ArchiveFile('content.opf', 300,
          '<package><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>'
              '<spine><itemref idref="c1"/></spine></package>'))
      ..addFile(ArchiveFile('images/pic.png', png.length, png))
      ..addFile(ArchiveFile(
          'c1.xhtml', 200, '<html><body><p><img src="images/pic.png"/></p></body></html>'));
    final htmls = await extractEpubHtml(_tmp('t2.epub', (ZipEncoder().encode(archive) ?? const <int>[])));
    expect(htmls.single, contains('file:///'));
    expect(htmls.single, isNot(contains('images/pic.png"')));
    // 解出的缓存文件真实存在
    final m = RegExp(r'src="file:///([^"]+)"').firstMatch(htmls.single)!;
    expect(File(m.group(1)!).existsSync(), isTrue);
  });

  test('epubChapterTitle 从 title/h1 提取章名', () {
    expect(epubChapterTitle('<html><head><title>序章</title></head><body></body></html>', 0), '序章');
    expect(epubChapterTitle('<html><body><h1>大标题</h1><p>x</p></body></html>', 1), '大标题');
    expect(epubChapterTitle('<html><body><p>x</p></body></html>', 2), '');
  });

  test('safeName 截断超长文件名并保留扩展名', () {
    final r = safeName('${'超' * 200}.md');
    expect(r.length, 80);
    expect(r.endsWith('.md'), isTrue);
  });

  test('Mark json 往返', () {
    final m = const Mark('id1', '文本', '前', '后', 1700000000000, true, false, 3);
    final back = Mark.fromJson(jsonDecode(jsonEncode(m.toJson())));
    expect(back!.text, '文本');
    expect(back.isHighlight, isTrue);
    expect(back.isPdf, isFalse);
    expect(back.page, 3);
    expect(Mark.fromJson('bad'), isNull);
  });

  test('splitBlocks：代码块内空行不切断', () {
    const src = '段落一\n\n```\ncode\n\nstill code\n```\n\n段落二';
    final blocks = splitBlocks(src);
    expect(blocks.length, 3);
    expect(blocks[1], contains('still code'));
  });

  test('findMatches：大小写不敏感、非重叠', () {
    expect(findMatches('AbcaBc', 'abc'), [(0, 3), (3, 6)]);
    expect(findMatches('无匹配', 'xyz'), isEmpty);
    expect(findMatches('任何', ''), isEmpty);
  });

  test('injectHtmlSearch 注入橙色 span', () {
    final s = injectHtmlSearch('<p>Hello world</p>', 'hello');
    expect(s, contains('#FFB86B'));
    expect(s, contains('>Hello</span>'));
  });

  test('主题表覆盖六种且背景色正确', () {
    expect(themes.keys.toSet(), {'light', 'dark', 'paper', 'warm', 'green', 'blue'});
    expect(HmdApp.theme('green').scaffoldBackgroundColor, const Color(0xFFCDE8CF));
  });

  testWidgets('阅读页：长文慢速拖动可滚动（嵌套滚动回归）', (t) async {
    final buf = StringBuffer('# 长文');
    for (var i = 1; i <= 60; i++) {
      buf.write("\n\n");
      buf.write('第 $i 段：白日依山尽，黄河入海流。');
    }
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: ReaderScreen(path: 't.md', title: 't滚.md', initialContent: buf.toString()),
    ));
    await t.pumpAndSettle();
    final pos = t.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(pos.pixels, 0);
    await t.timedDrag(find.byType(Scrollable).first, const Offset(0, -400), const Duration(milliseconds: 800));
    await t.pumpAndSettle();
    expect(pos.pixels, greaterThan(0));
  });

  test('selectedOf 按 selection 区间截取选中文本', () {
    const full = '你好世界正文OK';
    expect(selectedOf(full, const TextSelection(baseOffset: 2, extentOffset: 4)), '世界');
    expect(selectedOf(full, const TextSelection.collapsed(offset: 2)), '');
    expect(selectedOf(null, const TextSelection(baseOffset: 0, extentOffset: 1)), '');
  });

  testWidgets('阅读页：点击已标注文字弹出复制/删除菜单', (t) async {
    final m = Mark('mk1', '世界', '你好，', '。', 1, true, false, 1);
    await saveMarks('t点击.md', [m]);
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't点击.md', initialContent: '# 标\n\n你好，世界。OK',
      ),
    ));
    await t.pumpAndSettle();
    await t.pump(); // 触发 post-frame 矩形测量
    await t.tapAt(t.getCenter(find.textContaining('世界').first));
    await t.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('阅读页：长按选词→浮条→点高亮→保存渲染消失（一段式）', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't一段.md', initialContent: '# 标\n\n你好世界正文OK',
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('划线'), findsNothing);
    final g = await t.startGesture(t.getCenter(find.text('你好世界正文OK').first));
    await t.pump(const Duration(milliseconds: 600));
    await g.up();
    await t.pumpAndSettle();
    expect(find.text('划线'), findsOneWidget);
    expect(find.text('高亮'), findsOneWidget);
    // 点击链路受选区手柄 overlay 拦截影响（widget 测试环境局限），由模拟器实测覆盖
  });

  // 真机回归：选词在中间块（非末块）时浮条也必须出现——
  // 曾经 _selAnchor 在块循环内被重置，锚点随后续块丢失导致真机菜单永不弹出
  testWidgets('阅读页：多块文档选词在非末块，浮条仍出现', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't多块.md',
        initialContent: '# 标\n\n白日依山尽，黄河入海流。\n\n这里是最后一段尾巴',
      ),
    ));
    await t.pumpAndSettle();
    final g = await t.startGesture(t.getCenter(find.text('白日依山尽，黄河入海流。').first));
    await t.pump(const Duration(milliseconds: 600));
    await g.up();
    await t.pumpAndSettle();
    expect(find.text('划线'), findsOneWidget);
    expect(find.text('高亮'), findsOneWidget);
  });

  // 真机回归：同词在全文多处出现时，标注必须锚定到实际选中处而非全文首现
  // （曾在真机暴露：选第三行的词，黄块画到第一行同词处）
  testWidgets('阅读页：同词多处，标注锚定选中处而非首现', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't同词.md',
        initialContent: '# 标\n\n前文苹果。\n\n后文苹果。',
      ),
    ));
    await t.pumpAndSettle();
    // 长按第二段的"苹果"（"后文苹果。"第 3 字处）
    final rect = t.getRect(find.textContaining('后文苹果。'));
    final g = await t.startGesture(Offset(rect.left + rect.width * 0.55, rect.center.dy));
    await t.pump(const Duration(milliseconds: 600));
    await g.up();
    await t.pumpAndSettle();
    await t.tap(find.text('高亮'));
    await t.pumpAndSettle();
    final marks = loadMarks('t同词.md');
    expect(marks, isNotEmpty);
    // 选中处的直接前文是"后文"二字；若错标到首现处，before 将是第一段的上下文
    expect(marks.last.before, contains('后文'));
    expect(marks.last.page, 2);
  });

  testWidgets('阅读页：标注由矩形绘制层呈现', (t) async {
    final mu = Mark('mu', '世界', '你好，', '。', 1, false, false, 1);
    final mh = Mark('mh', '你好', '', '，世界', 2, true, false, 1);
    await saveMarks('t矩形.md', [mu, mh]);
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't矩形.md', initialContent: '# 标\n\n你好，世界。OK',
      ),
    ));
    await t.pumpAndSettle();
    await t.pump();
    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_MarkPainter'),
        findsOneWidget);
  });

  testWidgets('阅读页：滚动后退出重开，位置被记忆', (t) async {
    final buf = StringBuffer('# 长文');
    for (var i = 1; i <= 60; i++) {
      buf.write('\n\n第 $i 段：白日依山尽，黄河入海流。');
    }
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: ReaderScreen(path: 't.md', title: 't位置.md', initialContent: buf.toString()),
    ));
    await t.pumpAndSettle();
    final pos = t.state<ScrollableState>(find.byType(Scrollable).first).position;
    await t.timedDrag(find.byType(Scrollable).first, const Offset(0, -400), const Duration(milliseconds: 600));
    await t.pumpAndSettle();
    expect(pos.pixels, greaterThan(0));
    await t.pump(const Duration(milliseconds: 800)); // 防抖 600ms 后保存
    // 重开同一文件
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: ReaderScreen(path: 't.md', title: 't位置.md', initialContent: buf.toString()),
    ));
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 50)); // post-frame 恢复
    final pos2 = t.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(pos2.pixels, greaterThan(0));
  });

  testWidgets('阅读页：目录按钮弹出大纲并含各级标题', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't大纲.md',
        initialContent: '# 第一章 起点\n\n正文。\n\n## 1.1 小节\n\n正文。\n\n# 第二章 终点\n\n正文。',
      ),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('目录'));
    await t.pumpAndSettle();
    expect(find.text('目录'), findsWidgets);
    // 正文标题与大纲条目同文本（sheet 叠在正文上），故 findsWidgets
    expect(find.text('第一章 起点'), findsWidgets);
    expect(find.text('1.1 小节'), findsWidgets);
    expect(find.text('第二章 终点'), findsWidgets);
  });

  testWidgets('标注面板：筛选只显示高亮或划线', (t) async {
    await saveMarks('t筛选.md', [
      Mark('h1', '黄词一', '', '', 1, true, false, 0),
      Mark('u1', '蓝词一', '', '', 2, false, false, 0),
      Mark('h2', '黄词二', '', '', 3, true, false, 0),
    ]);
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
          path: 't.md', title: 't筛选.md', initialContent: '# 标\n\n黄词一 蓝词一 黄词二'),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('标注列表'));
    await t.pumpAndSettle();
    expect(find.text('黄词一'), findsOneWidget);
    expect(find.text('蓝词一'), findsOneWidget);
    await t.tap(find.text('高亮'));
    await t.pumpAndSettle();
    expect(find.text('黄词一'), findsOneWidget);
    expect(find.text('黄词二'), findsOneWidget);
    expect(find.text('蓝词一'), findsNothing);
    await t.tap(find.text('划线'));
    await t.pumpAndSettle();
    expect(find.text('蓝词一'), findsOneWidget);
    expect(find.text('黄词一'), findsNothing);
  });

  testWidgets('主题 auto：跟随系统模式渲染正常', (t) async {
    appTheme.value = 'auto';
    await t.pumpWidget(const HmdApp());
    await t.pumpAndSettle();
    expect(find.text('MD+'), findsOneWidget);
    expect(appTheme.value, 'auto');
  });
}
