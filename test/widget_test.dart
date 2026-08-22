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
    expect(find.text('MD 阅读器'), findsOneWidget);
    expect(find.text('打开 .md 文件'), findsOneWidget);
    expect(find.text('还没有文档'), findsOneWidget);
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

  testWidgets('阅读页：预置划线渲染为波浪线', (t) async {
    final m = Mark('m2', '世界', '你好，', '。', 1, false, false, 0);
    await saveMarks('t划线.md', [m]);
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't划线.md', initialContent: '# 标\n\n你好，世界。OK',
      ),
    ));
    await t.pumpAndSettle();
    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_WavyPainter'),
        findsOneWidget);
  });

  testWidgets('阅读页：预置标注渲染为高亮色块', (t) async {
    final m = Mark('m1', '世界', '你好，', '。', 1, true, false, 0);
    await saveMarks('t标注.md', [m]);
    await t.pumpWidget(MaterialApp(
      theme: HmdApp.theme('light'),
      home: const ReaderScreen(
        path: 't.md', title: 't标注.md', initialContent: '# 标\n\n你好，世界。OK',
      ),
    ));
    await t.pumpAndSettle();
    expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == hlYellow.withValues(alpha: 0.85)),
        findsOneWidget);
  });
}
