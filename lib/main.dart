// hmd —— 极简阅读器（iOS 风格 / 大按钮 / 左手操作）
// 支持 md / txt / pdf / epub / docx；微信"用其他应用打开"可直接跳转。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:hmd/build_info.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

const iosBlue = Color(0xFF007AFF);
const lightBg = Color(0xFFF2F2F7);
const darkCard = Color(0xFF1C1C1E);
const iosGray = Color(0xFF8E8E93);
const minFont = 14.0, maxFont = 28.0;

// 阅读背景主题：key -> (背景, 卡片, 前景文字)
final themes = <String, (Color, Color, Color)>{
  'light': (lightBg, Colors.white, Colors.black),
  'dark': (Colors.black, darkCard, Colors.white),
  'paper': (const Color(0xFFFAF6EF), Colors.white, const Color(0xFF2C2A26)),
  'warm': (const Color(0xFFF5E9D3), const Color(0xFFFFF8E8), const Color(0xFF3A322A)),
  'green': (const Color(0xFFCDE8CF), const Color(0xFFDFF2E1), const Color(0xFF24352A)),
  'blue': (const Color(0xFFD9E7F2), const Color(0xFFE6F0F8), const Color(0xFF22313F)),
};
const themeNames = {
  'light': '浅色', 'dark': '深色', 'paper': '纸白', 'warm': '淡暖', 'green': '绿豆沙', 'blue': '淡青',
};

late SharedPreferences prefs;
final appFont = ValueNotifier<double>(18); // 阅读正文字号
// 阅读主题：light/dark + 4 种护眼底色（paper 纸白 / warm 淡暖 / green 绿豆沙 / blue 淡青）
final appTheme = ValueNotifier<String>('light');

Future<void> initPrefs() async {
  prefs = await SharedPreferences.getInstance();
  appFont.value = prefs.getDouble('fontSize') ?? 18;
  final t = prefs.getString('theme');
  if (t != null && themes.containsKey(t)) {
    appTheme.value = t;
  } else {
    appTheme.value = prefs.getBool('dark') == true ? 'dark' : 'light'; // 旧版 bool 迁移
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initPrefs();
  runApp(const HmdApp());
}

class HmdApp extends StatelessWidget {
  const HmdApp({super.key});

  static ThemeData theme(String key) {
    final (bg, card, fg) = themes[key]!;
    final dark = key == 'dark';
    return ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: ColorScheme.fromSeed(seedColor: iosBlue, brightness: dark ? Brightness.dark : Brightness.light)
          .copyWith(primary: iosBlue, surface: card),
      scaffoldBackgroundColor: bg,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: fg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: appTheme,
      builder: (_, key, _) => MaterialApp(
        title: 'MD+',
        theme: theme('light'),
        darkTheme: theme(key == 'light' ? 'dark' : key),
        themeMode: key == 'light' ? ThemeMode.light : ThemeMode.dark,
        home: const HomeScreen(),
      ),
    );
  }
}

// ---------- 最近列表（以文件名为键，副本存于应用 docs 目录） ----------

class RecentRec {
  final String name;
  final int openedAt;
  const RecentRec(this.name, this.openedAt);
  Map<String, dynamic> toJson() => {'n': name, 't': openedAt};
  static RecentRec? fromJson(dynamic j) =>
      j is Map && j['n'] is String ? RecentRec(j['n'] as String, (j['t'] as num).toInt()) : null;
}

// 每条独立 try 解析：脏数据只丢该条，不让整个应用崩溃
List<RecentRec> loadRecent() => (prefs.getStringList('recent') ?? const [])
    .map((s) {
      try {
        return RecentRec.fromJson(jsonDecode(s));
      } catch (_) {
        return null;
      }
    })
    .whereType<RecentRec>()
    .toList();

Future<void> saveRecent(List<RecentRec> l) =>
    prefs.setStringList('recent', l.map((r) => jsonEncode(r.toJson())).toList());

Future<Directory> docsDir() async {
  final d = Directory('${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}docs');
  await d.create(recursive: true);
  return d;
}

// ponytail: 同名文件直接覆盖旧副本。同一名字视为同一篇文档，简单可靠；
// 若将来要区分"同名不同内容"，升级路径是副本名加时间戳、RecentRec 存完整路径。
// 超长名截到 80 字符（中文 UTF-8 下仍低于 Android 255 字节文件名上限），保留扩展名。
String safeName(String n) {
  var s = n.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (s.length > 80) {
    final dot = s.lastIndexOf('.');
    final ext = dot > 0 && dot > s.length - 12 ? s.substring(dot) : '';
    s = '${s.substring(0, 80 - ext.length)}$ext';
  }
  return s;
}

// ---------- 多格式支持 ----------

enum DocKind { md, pdf, epub, docx }

DocKind kindOf(String name) {
  switch (name.toLowerCase().split('.').last) {
    case 'pdf':
      return DocKind.pdf;
    case 'epub':
      return DocKind.epub;
    case 'docx':
      return DocKind.docx;
    default:
      return DocKind.md; // md / markdown / mdown / txt
  }
}

IconData iconFor(String name) {
  switch (kindOf(name)) {
    case DocKind.pdf:
      return Icons.picture_as_pdf_outlined;
    case DocKind.epub:
      return Icons.menu_book_outlined;
    case DocKind.docx:
      return Icons.article_outlined;
    case DocKind.md:
      return Icons.description_outlined;
  }
}

String _xmlUnescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&'); // amp 最后处理，避免双重转义还原错乱

// ---------- 标注（划线 / 高亮，按文件持久化） ----------

const hlYellow = Color(0xFFFFE066); // 高亮色块
const ulBlue = Color(0xFF007AFF); // 划线

class Mark {
  final String id, text, before, after;
  final int createdAt;
  final bool isHighlight; // true=色块 false=下划线
  final bool isPdf;
  final int page; // pdf=页码；epub=章节序号；md/txt/docx=块序号
  const Mark(this.id, this.text, this.before, this.after, this.createdAt, this.isHighlight, this.isPdf, this.page);
  Map<String, dynamic> toJson() => {'i': id, 't': text, 'b': before, 'a': after, 'c': createdAt, 'h': isHighlight, 'p': isPdf, 'n': page};
  static Mark? fromJson(dynamic j) => j is Map && j['i'] is String && j['t'] is String
      ? Mark(j['i'], j['t'], j['b'] is String ? j['b'] : '', j['a'] is String ? j['a'] : '',
          (j['c'] as num?)?.toInt() ?? 0, j['h'] == true, j['p'] == true,
          (j['n'] as num?)?.toInt() ?? 0)
      : null;
}

List<Mark> loadMarks(String doc) => (prefs.getStringList('marks_$doc') ?? const [])
    .map((s) {
      try {
        return Mark.fromJson(jsonDecode(s));
      } catch (_) {
        return null;
      }
    })
    .whereType<Mark>()
    .toList();

Future<void> saveMarks(String doc, List<Mark> l) =>
    prefs.setStringList('marks_$doc', l.map((m) => jsonEncode(m.toJson())).toList());

// 按空行切块（段落级），fence（``` / ~~~）内的空行不切断，保护代码块完整性
List<String> splitBlocks(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  var inFence = false;
  for (final line in s.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('```') || t.startsWith('~~~')) inFence = !inFence;
    buf.writeln(line);
    if (!inFence && line.trim().isEmpty && buf.toString().trim().isNotEmpty) {
      out.add(buf.toString());
      buf.clear();
    }
  }
  final rest = buf.toString();
  if (rest.trim().isNotEmpty) out.add(rest);
  return out;
}

// ---------- Markdown 标注 token 渲染（⟦h⟧高亮 ⟦u⟧下划线 ⟦s⟧搜索命中） ----------

class MarkSyntax extends md.InlineSyntax {
  MarkSyntax() : super(r'\u27e6([hus])\u27e7(.+?)\u27e6/\1\u27e7');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final t = match[1]!;
    parser.addNode(md.Element.text(
        t == 'h' ? 'hmdH' : (t == 'u' ? 'hmdU' : 'hmdS'), match[2]!));
    return true;
  }
}

// 标注渲染：返回 RichText 而非普通 Widget——flutter_markdown 的 inline 合并器
// 会把 RichText 的 span 提取出来与相邻文本重新合并，排版与未标注时完全一致。
class MarkBuilder extends MarkdownElementBuilder {
  final String kind; // h 高亮 / u 波浪划线 / s 搜索
  MarkBuilder(this.kind);

  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final base = parentStyle ?? preferredStyle ?? TextStyle(fontSize: appFont.value, height: 1.7);
    // 仅搜索命中使用 span 样式（暂态）；标注（划线/高亮）视觉一律由矩形绘制层负责
    final st = base.copyWith(
        background: Paint()..color = (kind == 'h' ? hlYellow : searchOrange).withValues(alpha: 0.85));
    return RichText(text: TextSpan(text: element.textContent, style: st));
  }
}


const searchOrange = Color(0xFFFFB86B);

// epub：把搜索词包橙色 span（在标注注入之后的文本上做，从后往前避免位移）
String injectHtmlSearch(String html, String q) {
  if (q.isEmpty) return html;
  final hits = findMatches(html, q);
  var s = html;
  for (final (a, b) in hits.reversed) {
    s = s.replaceRange(a, b,
        '<span style="background-color:#FFB86B">${s.substring(a, b)}</span>');
  }
  return s;
}

// flutter_markdown 的 onSelectionChanged 回调 text 是整块全文，按 selection 区间截取选中部分
String selectedOf(String? text, TextSelection selection) {
  final src = text ?? '';
  if (selection.isCollapsed) return '';
  return src.substring(selection.start.clamp(0, src.length), selection.end.clamp(0, src.length));
}

// 大小写不敏感地找出全部匹配（非重叠）。toLowerCase 后长度变化的罕见字符不做处理。
List<(int, int)> findMatches(String text, String q) {
  if (q.isEmpty) return const [];
  final low = text.toLowerCase();
  final lq = q.toLowerCase();
  final out = <(int, int)>[];
  var i = 0;
  while ((i = low.indexOf(lq, i)) >= 0) {
    out.add((i, i + q.length));
    i += q.length;
  }
  return out;
}

// epub：把锚点处文本包上带样式的 span（text 含 HTML 转义字符时失配跳过）
String injectHtmlMarks(String html, Iterable<Mark> ms) {
  var s = html;
  for (final m in ms) {
    final i = s.indexOf(m.before + m.text);
    if (i < 0) continue;
    final start = i + m.before.length;
    final span = m.isHighlight
        ? '<span style="background-color:#FFE066">'
        : '<span style="text-decoration:underline;text-underline-offset:3px">';
    s = s.replaceRange(start, start + m.text.length, '$span${m.text}</span>');
  }
  return s;
}

// ponytail: docx 只抽段落文本（丢格式/图片/表格结构），够"读"用；
// 要保真排版需上 mammoth 类 HTML 转换，Dart 生态无成熟实现。
Future<String> extractDocxText(String path) async {
  final zip = ZipDecoder().decodeBytes(await File(path).readAsBytes());
  final doc = zip.findFile('word/document.xml');
  if (doc == null) return '';
  final xml = utf8.decode(doc.content as List<int>);
  final sb = StringBuffer();
  for (final para in RegExp(r'<w:p[ >].*?</w:p>|<w:p/>', dotAll: true).allMatches(xml)) {
    final line = RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true)
        .allMatches(para.group(0)!)
        .map((m) => m.group(1)!)
        .join();
    if (line.isNotEmpty) sb.writeln(_xmlUnescape(line));
  }
  return sb.toString();
}

// ponytail: 自写 EPUB 解析（zip + container.xml + opf 的 manifest/spine），
// 只取 spine 顺序的 xhtml 章节。不引 epubx 是因为它钉死 image 3.x，与 pdfrx 的
// image 4.x 冲突。加密/DRM 的 epub 不支持；升级路径是接入 epubx 修复版或自写完整 OPF 解析。
Future<List<String>> extractEpubHtml(String path) async {
  final zip = ZipDecoder().decodeBytes(await File(path).readAsBytes());
  final files = {for (final f in zip) f.name: f};

  // container.xml → OPF 路径
  var opfPath = '';
  final container = files['META-INF/container.xml'];
  if (container != null) {
    final m = RegExp(r'full-path="([^"]+)"').firstMatch(utf8.decode(container.content as List<int>));
    if (m != null) opfPath = m.group(1)!;
  }
  ArchiveFile? opf;
  if (opfPath.isNotEmpty) opf = zip.findFile(opfPath);
  if (opf == null) {
    for (final f in zip) {
      if (f.name.endsWith('.opf')) {
        opf = f;
        break;
      }
    }
  }
  if (opf == null) return const [];

  final xml = utf8.decode(opf.content as List<int>);
  final base = opf.name.contains('/') ? opf.name.substring(0, opf.name.lastIndexOf('/') + 1) : '';

  // manifest: id → href（逐属性抽取，不依赖属性顺序）
  final manifest = <String, String>{};
  for (final m in RegExp(r'<item\b[^>]*>').allMatches(xml)) {
    final tag = m.group(0)!;
    final id = RegExp(r'\bid="([^"]*)"').firstMatch(tag)?.group(1);
    final href = RegExp(r'\bhref="([^"]*)"').firstMatch(tag)?.group(1);
    if (id != null && href != null) manifest[id] = href;
  }
  final order = <String>[
    for (final m in RegExp(r'<itemref\b[^>]*>').allMatches(xml))
      if (RegExp(r'\bidref="([^"]*)"').firstMatch(m.group(0)!)?.group(1) case final idref?)
        ?manifest[idref]
  ];

  String? resolve(String href) {
    final p = base + href;
    if (files.containsKey(p)) return p;
    for (final k in files.keys) {
      if (k == href || k.endsWith('/$href')) return k;
    }
    return null;
  }

  final out = <String>[];
  if (order.isEmpty) {
    // 兜底：无 spine 时按文件名序输出全部 html
    for (final k in files.keys.toList()..sort()) {
      if (k.endsWith('.xhtml') || k.endsWith('.html')) {
        final c = utf8.decode(files[k]!.content as List<int>);
        if (c.trim().isNotEmpty) out.add(c);
      }
    }
    return out;
  }
  for (final href in order) {
    final f = resolve(href);
    if (f == null) continue;
    final c = utf8.decode(files[f]!.content as List<int>);
    if (c.trim().isNotEmpty) out.add(c);
  }
  return out;
}

// ---------- 主页 ----------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<RecentRec> _recent = [];
  StreamSubscription<List<SharedMediaFile>>? _sub;

  @override
  void initState() {
    super.initState();
    _recent = loadRecent();
    if (Platform.isAndroid || Platform.isIOS) {
      // 冷启动分享 + 运行中接收（微信"用其他应用打开"）
      ReceiveSharingIntent.instance.getInitialMedia().then(_ingestAll);
      _sub = ReceiveSharingIntent.instance.getMediaStream().listen(_ingestAll);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _ingestAll(List<SharedMediaFile> list) {
    for (final m in list) {
      if (m.path.isNotEmpty) {
        _ingestFile(m.path);
        return;
      }
    }
  }

  Future<void> _pick() async {
    final f = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['md', 'markdown', 'mdown', 'txt', 'pdf', 'epub', 'docx'],
    );
    final p = f?.path;
    if (p != null && p.isNotEmpty) await _ingestFile(p);
  }

  Future<void> _ingestFile(String src) async {
    final f = File(src);
    if (!await f.exists()) return _toast('无法访问该文件');
    final name = safeName(f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : '未命名.md');
    final dst = File('${(await docsDir()).path}${Platform.pathSeparator}$name');
    try {
      await f.copy(dst.path);
    } catch (_) {
      return _toast('导入失败');
    }
    await _open(RecentRec(name, DateTime.now().millisecondsSinceEpoch));
  }

  Future<void> _open(RecentRec rec) async {
    final p = '${(await docsDir()).path}${Platform.pathSeparator}${rec.name}';
    if (!await File(p).exists()) {
      setState(() => _recent.remove(rec));
      await saveRecent(_recent);
      return _toast('文件不存在，已从列表移除');
    }
    _recent
      ..removeWhere((r) => r.name == rec.name)
      ..insert(0, rec);
    if (_recent.length > 50) _recent.removeLast();
    await saveRecent(_recent);
    if (!mounted) return;
    setState(() {});
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(path: p, title: rec.name),
    ));
    if (mounted) setState(() => _recent = loadRecent());
  }

  // 删除单条记录：连同应用内文件副本与该文件的标注一起清理
  Future<void> _removeRec(RecentRec r) async {
    setState(() => _recent.removeWhere((x) => x.name == r.name));
    await saveRecent(_recent);
    await _purgeFiles([r.name]);
  }

  Future<void> _purgeFiles(List<String> names) async {
    final dir = (await docsDir()).path;
    for (final n in names) {
      try {
        await File('$dir${Platform.pathSeparator}$n').delete();
      } catch (_) {}
      try {
        await prefs.remove('marks_$n');
      } catch (_) {}
    }
  }

  Future<void> _confirmRemove(RecentRec r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条记录？'),
        content: Text('「${r.name}」的应用内副本与标注会一并删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true && mounted) await _removeRec(r);
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部记录？'),
        content: const Text('所有文件的应用内副本与标注会一并删除，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final names = [for (final r in _recent) r.name];
    setState(() => _recent.clear());
    await saveRecent(_recent);
    await _purgeFiles(names);
    _toast('已清空');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? darkCard : Colors.white;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
          children: [
            const Text('MD+',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, height: 1.25)),
            const SizedBox(height: 4),
            const Text('微信里收到的文档，都能舒服地看',
                style: TextStyle(fontSize: 14, color: iosGray)),
            const SizedBox(height: 22),
            SizedBox(
              height: 58,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: iosBlue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                onPressed: _pick,
                icon: const Icon(Icons.folder_open_outlined, size: 26),
                label: const Text('打开 .md 文件'),
              ),
            ),
            const SizedBox(height: 28),
            if (_recent.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
                decoration: BoxDecoration(
                    color: card, borderRadius: BorderRadius.circular(16)),
                child: const Column(children: [
                  Icon(Icons.file_open_outlined, size: 46, color: iosGray),
                  SizedBox(height: 12),
                  Text('还没有文档', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  SizedBox(height: 6),
                  Text('点上面的按钮选择文件；在微信里也可以\n选"用其他应用打开"直接跳到本应用',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: iosGray, height: 1.5)),
                ]),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 8),
                child: Row(children: [
                  const Text('最近',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: iosGray)),
                  const Spacer(),
                  TextButton(
                    onPressed: _confirmClearAll,
                    style: TextButton.styleFrom(
                        foregroundColor: iosGray,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 30),
                        textStyle: const TextStyle(fontSize: 13)),
                    child: const Text('清空'),
                  ),
                ]),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  color: card,
                  child: Column(children: [
                    for (var i = 0; i < _recent.length; i++) ...[
                      if (i > 0)
                        Container(height: 0.5, margin: const EdgeInsets.only(left: 58), color: card),
                      _row(_recent[i], card),
                    ],
                  ]),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Text(
              'MD+ v$appVersion · 构建 $buildDate',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: iosGray),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(RecentRec r, Color card) => Dismissible(
        key: ValueKey(r.name),
        direction: DismissDirection.endToStart, // 只左滑
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 22),
          color: Colors.redAccent,
          child: const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 26),
        ),
        onDismissed: (_) => _removeRec(r),
        child: InkWell(
          onTap: () => _open(r),
          onLongPress: () => _confirmRemove(r),
          child: Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: card,
            child: Row(children: [
              Icon(iconFor(r.name), size: 28, color: iosBlue),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(_fmtDate(r.openedAt), style: const TextStyle(fontSize: 13, color: iosGray)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 22, color: iosGray),
            ]),
          ),
        ),
      );

  static String _fmtDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    return sameDay
        ? '${two(d.hour)}:${two(d.minute)}'
        : '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

// ---------- 阅读页 ----------

class ReaderScreen extends StatefulWidget {
  final String path;
  final String title;
  // 测试注入用：绕过真实文件 IO（flutter_test 的 fake 时钟跑不了 dart:io）
  final String? initialContent;
  const ReaderScreen({super.key, required this.path, required this.title, this.initialContent});
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  String? _content; // md / docx 正文
  List<String>? _html; // epub 章节列表
  String? _error;
  List<Mark> _marks = [];
  final _markKeys = <String, GlobalKey>{}; // 标注 id -> 所在块的 key（md 系定位）
  final _blockKeys = <int, GlobalKey>{}; // md 块序号 -> key（搜索定位）
  final _searchHitBlocks = <int>[]; // 每个搜索命中所处的 md 块序号
  final _searchHitChapters = <int>[]; // 每个搜索命中所处的 epub 章序号
  final _chapterKeys = <int, GlobalKey>{}; // epub 章节定位
  final _pdfCtrl = PdfViewerController();
  PdfTextSearcher? _pdfSearcher;
  bool _pdfSel = false; // pdf 当前有选中文本
  String _mdSelText = ''; // md 当前选中文字（onSelectionChanged 记录，不依赖剪贴板）

  bool _searchOpen = false;
  final _searchCtrl = TextEditingController();
  String _query = '';
  int _searchIdx = 0;
  // 已标注文字的屏幕矩形（跨行多条）：波浪自绘 + 点击命中共用；
  // 用 ValueNotifier 只触发 CustomPaint 重绘，避免 setState 循环
  final _rectNotifier = ValueNotifier<List<(Mark, Rect)>>(const []);
  final _mdScroll = ScrollController();
  bool _measureScheduled = false;
  Offset? _lastTapDown;
  (Mark, Rect)? _tapMenuMark; // 点击标注弹出的工具条（mark + 锚矩形）
  Rect? _selAnchor; // 当前选区的锚矩形（选词工具条定位）
  String? _selCtx; // 选中处前后 16 字上下文（真实位置锚定，防同词首现错位）
  int _mdEpoch = 0; // 递增以强制重建 MarkdownBody，从而清除系统选区
  final _stackKey = GlobalKey(); // body Stack：矩形局部坐标系的基准
  Offset _stackOrigin = Offset.zero;

  DocKind get _kind => kindOf(widget.title);

  @override
  void initState() {
    super.initState();
    _marks = loadMarks(widget.title);
    _mdScroll.addListener(_scheduleMeasure);
    if (widget.initialContent != null) {
      _content = widget.initialContent;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _mdScroll.dispose();
    _rectNotifier.dispose();
    _pdfSearcher?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final f = File(widget.path);
    try {
      switch (_kind) {
        case DocKind.md:
          _content = await f.readAsString();
        case DocKind.docx:
          _content = await extractDocxText(widget.path);
          if (_content!.isEmpty) _error = '未能从文档中提取到文本';
        case DocKind.epub:
          _html = await extractEpubHtml(widget.path);
          if (_html!.isEmpty) _error = '未能解析此 EPUB 文件';
        case DocKind.pdf:
          break; // PdfViewer 自行加载
      }
    } on FileSystemException {
      _error = '文件不存在或无法读取';
    } on FormatException {
      // ponytail: 非 UTF-8 编码用 Latin-1 兜底（中文文档几乎都是 UTF-8，走不到这）
      try {
        _content = await f.readAsString(encoding: latin1);
      } catch (_) {
        _error = '文件编码无法识别';
      }
    } catch (_) {
      // zip 结构损坏、epub schema 异常等一切解析失败：给出可读提示而非崩溃
      _error = '打开失败：文件可能已损坏或格式不受支持';
    }
    if (mounted) setState(() {});
  }

  void _setFont(double v) {
    final n = v.clamp(minFont, maxFont);
    appFont.value = n;
    prefs.setDouble('fontSize', n);
  }

  // ---- 标注 ----

  Future<void> _addMark(String text, bool hl, [String? selCtx]) async {
    text = text.trim();
    if (text.isEmpty || text.length > 500) return;
    final src = _kind == DocKind.epub ? _html!.join('\n') : (_content ?? '');
    var i = src.indexOf(text);
    // 优先用选中处的直接上下文定位：同词在全文多处出现时，全文首现会标错位置
    if (selCtx != null && selCtx.contains(text)) {
      final ci = src.indexOf(selCtx);
      if (ci >= 0) i = ci + selCtx.indexOf(text);
    }
    if (i < 0) return;
    // 锚点截到同一行内：跨段的上下文会让渲染时的段内匹配失败
    final lineStart = i > 0 ? src.lastIndexOf('\n', i - 1) + 1 : 0;
    final lineEnd = src.indexOf('\n', i + text.length);
    final b = src.substring((i - 16).clamp(lineStart, src.length), i);
    final e = (i + text.length + 16).clamp(0, lineEnd < 0 ? src.length : lineEnd);
    final a = src.substring(i + text.length, e);
    var page = 0;
    if (_kind == DocKind.epub) {
      page = _html!.indexWhere((h) => h.contains(b + text) || h.contains(text));
      if (page < 0) page = 0;
    } else if (_kind != DocKind.pdf) {
      // 记录所在块序号：渲染时只标这一块，避免同文多处全部被标
      var off = 0;
      for (final blk in splitBlocks(src)) {
        if (i >= off && i < off + blk.length) break;
        off += blk.length;
        page++;
      }
    }
    final m = Mark(DateTime.now().microsecondsSinceEpoch.toString(), text, b, a,
        DateTime.now().millisecondsSinceEpoch, hl, false, page);
    setState(() => _marks = [..._marks, m]);
    await saveMarks(widget.title, _marks);
  }

  Future<void> _addPdfMark(bool hl) async {
    final d = _pdfCtrl.textSelectionDelegate;
    final text = (await d.getSelectedText()).trim();
    if (text.isEmpty || text.length > 500) return;
    int page = 1;
    try {
      final rs = await d.getSelectedTextRanges();
      if (rs.isNotEmpty) page = rs.first.pageNumber;
    } catch (_) {}
    await d.clearTextSelection();
    final m = Mark(DateTime.now().microsecondsSinceEpoch.toString(), text, '', '',
        DateTime.now().millisecondsSinceEpoch, hl, true, page);
    setState(() => _marks = [..._marks, m]);
    await saveMarks(widget.title, _marks);
  }

  Future<void> _deleteMark(Mark m) async {
    setState(() => _marks = _marks.where((x) => x.id != m.id).toList());
    await saveMarks(widget.title, _marks);
  }

  void _jumpTo(Mark m) {
    if (m.isPdf) {
      _pdfCtrl.goToPage(pageNumber: m.page);
      return;
    }
    final ctx = _kind == DocKind.epub
        ? _chapterKeys[m.page]?.currentContext
        : _markKeys[m.id]?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.2);
  }

  void _showMarksPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => MarksPanel(
        marks: List.of(_marks),
        onJump: (m) {
          Navigator.of(context).pop();
          _jumpTo(m);
        },
        onDelete: _deleteMark,
      ),
    );
  }

  // ---- 标注矩形系统：定位/绘制/点击命中全部基于同一套实测矩形 ----
  // 正文不注入任何标注样式（排版恒定）；渲染后测量每条标注文字的精确屏幕矩形：
  // 高亮=矩形画色块、划线=矩形画波浪，同文字多标注自然叠加互不冲突。
  void _scheduleMeasure() {
    if (_measureScheduled || !mounted) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted || _kind == DocKind.pdf) return;
      final oldAnchor = _selAnchor;
      final out = <(Mark, Rect)>[];
      _selAnchor = null; // 每次重测重定位选区锚点（循环外重置一次）
      for (final bi in _blockKeys.keys.toList()..sort()) {
        final ctx = _blockKeys[bi]?.currentContext;
        if (ctx == null) continue;
        // 有序收集块内全部文本渲染对象（visit 顺序即视觉顺序），渲染文本 == 原块文本
        final runs = <(int, int, dynamic)>[]; // (0, 文本长度, RenderObject)
        final ro = ctx.findRenderObject();
        final raw = <dynamic>[];
        void collect(RenderObject r) {
          if (r is RenderEditable || r is RenderParagraph) {
            raw.add(r);
          }
          r.visitChildren(collect);
        }
        if (ro is RenderEditable || ro is RenderParagraph) raw.add(ro);
        ro?.visitChildren(collect);
        var acc = 0;
        for (final r in raw) {
          final len = (r.text as InlineSpan).toPlainText().length;
          runs.add((acc, acc + len, r));
          acc += len;
        }
        if (runs.isEmpty) continue;
        // 直接在每个渲染对象自身的文本里锚定匹配，取其选择盒（不做全局偏移换算，
        // run 自己的文本与盒子天然同坐标系，杜绝错位）
        for (final r in runs.map((e) => e.$3)) {
          final runText = (r.text as InlineSpan).toPlainText();
          if (runText.isEmpty) continue;
          // 选区锚点：当前选中词在本 run 的顶矩形（选词工具条定位）
          if (_mdSelText.isNotEmpty && _selAnchor == null) {
            final si = runText.indexOf(_mdSelText);
            if (si >= 0) {
              final sbx = (r.getBoxesForSelection as dynamic)(
                  TextSelection(baseOffset: si, extentOffset: si + _mdSelText.length)) as List;
              if (sbx.isNotEmpty) {
                final b0 = sbx.first;
                final org = (r.localToGlobal as dynamic)(Offset.zero) as Offset;
                _selAnchor = Rect.fromLTWH(org.dx + b0.left, org.dy + b0.top,
                    b0.right - b0.left, b0.bottom - b0.top);
              }
            }
          }
          for (final m in _marks.where((m) => !m.isPdf && m.page == bi)) {
            var i = m.before.isEmpty ? -1 : runText.indexOf(m.before + m.text);
            i = i >= 0 ? i + m.before.length : runText.indexOf(m.text);
            if (i < 0) continue;
            final boxes = (r.getBoxesForSelection as dynamic)(
                TextSelection(baseOffset: i, extentOffset: i + m.text.length)) as List;
            final origin = (r.localToGlobal as dynamic)(Offset.zero) as Offset;
            for (final b in boxes) {
              out.add((m,
                  Rect.fromLTWH(origin.dx + b.left, origin.dy + b.top, b.right - b.left, b.bottom - b.top)));
            }
          }
        }
      }
      // 全局坐标转 body Stack 局部（绘制/命中/菜单定位统一同一坐标系）
      final so = _stackKey.currentContext?.findRenderObject() is RenderBox
          ? ((_stackKey.currentContext!.findRenderObject() as RenderBox).localToGlobal(Offset.zero))
          : Offset.zero;
      _stackOrigin = so;
      final local = [for (final (m, r) in out) (m, r.shift(-so))];
      if (mounted && !_sameRects(_rectNotifier.value, local)) _rectNotifier.value = local;
      if (mounted && _selAnchor != oldAnchor) setState(() {}); // 工具条出现/收起
    });
  }

  static bool _sameRects(List<(Mark, Rect)> a, List<(Mark, Rect)> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].$1.id != b[i].$1.id || a[i].$2 != b[i].$2) return false;
    }
    return true;
  }

  // 选词菜单动作：标注 + 清选区（重建 MarkdownBody）+ 收工具条
  void _markFromSelection(bool hl) {
    final t = _mdSelText;
    final ctx = _selCtx; // 真实选中处的前后文，杜绝同词在前文出现时标错位置
    setState(() {
      _mdSelText = '';
      _selAnchor = null;
      _mdEpoch++; // 重建清空系统选区
    });
    _addMark(t, hl, ctx);
  }

  // 点击已标注文字：弹与选词菜单同款的工具条（复制/删除）
  Mark? _hitMark(Offset pos) {
    for (final (m, r) in _rectNotifier.value) {
      if (r.inflate(10).contains(pos)) return m;
    }
    return null;
  }

  void _onBodyTap(Offset globalPos) {
    final pos = globalPos - _stackOrigin; // 命中判断用 Stack 局部坐标
    final m = _hitMark(pos);
    if (m == null) {
      if (_tapMenuMark != null) setState(() => _tapMenuMark = null);
      return;
    }
    final anchor = _rectNotifier.value.firstWhere((e) => e.$1.id == m.id).$2;
    // 两菜单互斥：长按标注文字会同时产生选区与命中，选词菜单必须让位，
    // 否则两菜单 clamp 到同一位置重叠，点"删除"实际误触下层"高亮"
    setState(() {
      _tapMenuMark = (m, anchor);
      _mdSelText = '';
      _selAnchor = null;
      _selCtx = null;
    });
  }

  // md 选择：flutter_markdown 的 selectable 内部用 SelectableText  // md 选择：flutter_markdown 的 selectable 内部用 SelectableText（与滚动协调正常），
  // 选中文本经 onSelectionChanged 直接回调，不依赖系统剪贴板（真机管控下不可靠）。
  void _onMdSelection(String? text, TextSelection selection, SelectionChangedCause? cause) {
    final t = selectedOf(text, selection);
    // 先更新选中处前后 16 字上下文（同词在不同位置重选时 t 相同但 ctx 不同，不能提前 return）
    if (t.isNotEmpty && text != null && !selection.isCollapsed) {
      final b = (selection.start - 16).clamp(0, text.length);
      final e = (selection.end + 16).clamp(0, text.length);
      _selCtx = text.substring(b, selection.start) + t + text.substring(selection.end, e);
    } else {
      _selCtx = null;
    }
    if (t == _mdSelText) return;
    if (mounted) {
      setState(() {
        _mdSelText = t;
        if (t.isEmpty) _selAnchor = null;
        if (t.isNotEmpty) _tapMenuMark = null; // 新选区时关点击菜单（互斥）
      });
    }
  }

  // 统一大工具条：选词菜单与点击标注菜单共用同一容器样式
  Widget markToolbar(List<(String, VoidCallback)> items) => Container(
        padding: const EdgeInsets.all(8), // 不设固定高，由内容自然撑起，杜绝文字被裁
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 3))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, item) in items.indexed)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
                // 自绘按钮：无框架内建约束，文字渲染稳定不被裁（InkWell/Material 在菜单容器中实测塌陷为 0 高）
                child: GestureDetector(
                  onTap: item.$2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F2F7),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(item.$1,
                        style: const TextStyle(fontSize: 16, color: Colors.black87)),
                  ),
                ),
              ),
          ],
        ),
      );

  // ---- 全文搜索 ----

  int get _searchTotal => _kind == DocKind.epub ? _searchHitChapters.length : _searchHitBlocks.length;

  void _onQueryChanged(String v) {
    setState(() {
      _query = v;
      _searchIdx = 0;
    });
    if (_kind == DocKind.pdf) {
      _pdfSearcher ??= PdfTextSearcher(_pdfCtrl);
      _pdfSearcher!.startTextSearch(v, caseInsensitive: true);
    }
  }

  Future<void> _stepSearch(int dir) async {
    if (_kind == DocKind.pdf) {
      final s = _pdfSearcher;
      if (s == null) return;
      if (dir > 0) {
        await s.goToNextMatch();
      } else {
        await s.goToPrevMatch();
      }
      return;
    }
    final n = _searchTotal;
    if (n == 0) return;
    setState(() => _searchIdx = (_searchIdx + dir + n) % n);
    final bi = _kind == DocKind.epub ? _searchHitChapters[_searchIdx] : _searchHitBlocks[_searchIdx];
    final ctx = _kind == DocKind.epub
        ? _chapterKeys[bi]?.currentContext
        : _blockKeys[bi]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.3);
    }
  }

  void _showThemeSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('背景色', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final e in themes.entries)
                    InkWell(
                      onTap: () {
                        appTheme.value = e.key;
                        prefs.setString('theme', e.key);
                        Navigator.of(context).pop();
                      },
                      child: Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          color: e.value.$1,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                              color: appTheme.value == e.key ? iosBlue : Colors.transparent,
                              width: 3),
                        ),
                        alignment: Alignment.center,
                        child: Text(themeNames[e.key]!,
                            style: TextStyle(color: e.value.$3, fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_searchOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searchOpen) _closeSearch();
      },
      child: _buildScaffold(),
    );
  }

  void _closeSearch() {
    _searchCtrl.clear();
    _pdfSearcher?.startTextSearch('');
    setState(() {
      _searchOpen = false;
      _query = '';
    });
  }

  Widget _buildScaffold() {
    final card = themes[appTheme.value]?.$2 ?? (Theme.of(context).brightness == Brightness.dark ? darkCard : Colors.white);
    return Scaffold(
      appBar: _searchOpen ? _searchAppBar() : AppBar(
        title: Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 22),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, size: 24),
            tooltip: '搜索',
            onPressed: () => setState(() => _searchOpen = true),
          ),
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined, size: 24),
            tooltip: '标注列表',
            onPressed: _showMarksPanel,
          ),
        ],
      ),
      body: _buildBody(),
      // 左手工具条：按钮集中左侧，右手拇指区域留给滚动。
      // pdf 无工具条——pdfrx 自带捏合缩放与翻页，字号/主题对固定版式无意义。
      bottomNavigationBar: _kind == DocKind.pdf ? null : SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: ValueListenableBuilder<double>(
            valueListenable: appFont,
            builder: (_, fs, _) => Container(
              height: 56,
              padding: const EdgeInsets.only(left: 6),
              decoration: BoxDecoration(
                  color: card, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                IconButton(
                  iconSize: 28,
                  onPressed: fs > minFont ? () => _setFont(fs - 1) : null,
                  icon: const Icon(Icons.text_decrease_rounded),
                  tooltip: '减小字号',
                ),
                IconButton(
                  iconSize: 28,
                  onPressed: fs < maxFont ? () => _setFont(fs + 1) : null,
                  icon: const Icon(Icons.text_increase_rounded),
                  tooltip: '增大字号',
                ),
                SizedBox(
                  height: 26,
                  child: VerticalDivider(width: 14, thickness: 0.5, color: Theme.of(context).brightness == Brightness.dark ? Colors.white24 : Colors.black12),
                ),
                IconButton(
                  iconSize: 26,
                  onPressed: _showThemeSheet,
                  icon: const Icon(Icons.palette_outlined),
                  tooltip: '背景色',
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _searchAppBar() {
    Widget counter;
    if (_kind == DocKind.pdf) {
      counter = _pdfSearcher == null
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: _pdfSearcher!,
              builder: (_, _) {
                final s = _pdfSearcher!;
                final cur = s.currentIndex;
                return Text('${cur == null ? 0 : cur + 1}/${s.matches.length}',
                    style: const TextStyle(fontSize: 14, color: iosGray));
              });
    } else {
      counter = Text('${_searchTotal == 0 ? 0 : _searchIdx + 1}/$_searchTotal',
          style: const TextStyle(fontSize: 14, color: iosGray));
    }
    return AppBar(
      titleSpacing: 0,
      leading: const SizedBox.shrink(),
      title: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: TextField(
          controller: _searchCtrl,
          autofocus: true,
          onChanged: _onQueryChanged,
          style: const TextStyle(fontSize: 17),
          decoration: const InputDecoration(
              hintText: '搜索正文…', border: InputBorder.none, isDense: true),
        ),
      ),
      actions: [
        Padding(padding: const EdgeInsets.only(right: 4), child: Center(child: counter)),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_up, size: 26),
          tooltip: '上一个',
          onPressed: () => _stepSearch(-1),
        ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down, size: 26),
          tooltip: '下一个',
          onPressed: () => _stepSearch(1),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 22),
          tooltip: '关闭搜索',
          onPressed: _closeSearch,
        ),
      ],
    );
  }

  Widget _buildBody() {
    final err = Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline_rounded, size: 46, color: iosGray),
        const SizedBox(height: 12),
        Text(_error ?? '', style: const TextStyle(fontSize: 16, color: iosGray)),
      ]),
    );
    final loading = const Center(child: CircularProgressIndicator(color: iosBlue));
    if (_error != null) return err;
    switch (_kind) {
      case DocKind.pdf:
        final darkPdf = Theme.of(context).brightness == Brightness.dark;
        return Stack(children: [
          PdfViewer.file(
            widget.path,
            controller: _pdfCtrl,
            params: PdfViewerParams(
              textSelectionParams: PdfTextSelectionParams(
                onTextSelectionChange: (s) {
                  if (mounted) setState(() => _pdfSel = s.hasSelectedText);
                },
              ),
            ),
          ),
          // 深色模式下压暗白纸页面，夜间阅读不刺眼
          if (darkPdf)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(color: Colors.black.withValues(alpha: 0.28)),
              ),
            ),
          if (_pdfSel)
            Positioned(
              left: 20,
              bottom: 24,
              child: Container(
                decoration: BoxDecoration(
                    color: iosBlue, borderRadius: BorderRadius.circular(24)),
                child: Row(children: [
                  TextButton(
                    onPressed: () => _addPdfMark(false),
                    child: const Text('划线', style: TextStyle(color: Colors.white, fontSize: 16)),
                  ),
                  TextButton(
                    onPressed: () => _addPdfMark(true),
                    child: const Text('高亮', style: TextStyle(color: Colors.white, fontSize: 16)),
                  ),
                ]),
              ),
            ),
        ]);
      case DocKind.epub:
        if (_html == null) return loading;
        // 命中需预计算：ListView.builder 惰性构建，滚到的章节才会 build
        _searchHitChapters.clear();
        for (var i = 0; i < _html!.length; i++) {
          _searchHitChapters.addAll(
              [for (var j = 0; j < findMatches(_html![i], _query).length; j++) i]);
        }
        // epub 不做选择标注（HtmlWidget 无内建选择；外挂 SelectionArea 会与滚动冲突）
        return ValueListenableBuilder<double>(
          valueListenable: appFont,
          builder: (_, fs, _) => ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            itemCount: _html!.length,
            itemBuilder: (_, i) {
              final k = _chapterKeys.putIfAbsent(i, GlobalKey.new);
              var injected = injectHtmlMarks(
                  _html![i], _marks.where((m) => !m.isPdf && m.page == i));
              injected = injectHtmlSearch(injected, _query);
              return Padding(
                key: k,
                padding: const EdgeInsets.only(bottom: 16),
                child: HtmlWidget(injected, textStyle: TextStyle(fontSize: fs, height: 1.7)),
              );
            },
          ),
        );
      default: // md / txt / docx
        if (_content == null) return loading;
        _scheduleMeasure(); // 每帧布局后重测标注矩形（波浪层与点击命中共用）
        return Stack(key: _stackKey, children: [
          // 标注绘制层（矩形已转 Stack 局部坐标）
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _MarkPainter(_rectNotifier)),
            ),
          ),
          Listener(
            onPointerUp: (e) {
              final dn = _lastTapDown;
              if (dn != null && (e.position - dn).distance < 10) {
                _onBodyTap(e.position);
              }
            },
            onPointerDown: (e) => _lastTapDown = e.position,
            child: ValueListenableBuilder<double>(
          valueListenable: appFont,
          builder: (_, fs, _) {
            final blocks = splitBlocks(_content!);
            _searchHitBlocks.clear();
            final children = <Widget>[];
            for (final (bi, raw) in blocks.indexed) {
              // 标注不再注入正文（视觉由矩形层绘制，定位零冲突）；仅搜索命中注入橙色 token。
              // 所有块统一挂 key：矩形测量与选区锚点需要遍历任意块
              final hits = findMatches(raw, _query);
              var data = raw;
              for (final (s, e) in hits.reversed) {
                data = data.replaceRange(s, e, '⟦s⟧${data.substring(s, e)}⟦/s⟧');
              }
              _searchHitBlocks.addAll([for (var j = 0; j < hits.length; j++) bi]);
              _blockKeys[bi] ??= GlobalKey();
              // MarkdownBody 无内部滚动视图；用滚动版 Markdown 会与外层 ListView 抢手势导致无法滚动
              final w = MarkdownBody(
                data: data,
                styleSheet: _mdStyle(context, fs),
                inlineSyntaxes: [MarkSyntax()],
                builders: {
                  'hmdH': MarkBuilder('h'),
                  'hmdU': MarkBuilder('u'),
                  'hmdS': MarkBuilder('s'),
                },
                selectable: true,
                onSelectionChanged: _onMdSelection,
                key: ValueKey('md-$_mdEpoch'),
                contextMenuBuilder: (_, _) => const SizedBox.shrink(),
              );
              final bk = _blockKeys[bi];
              children.add(bk == null ? w : KeyedSubtree(key: bk, child: w));
              if (bi < blocks.length - 1) children.add(const SizedBox(height: 8));
            }
            return ListView(
              controller: _mdScroll,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: children,
            );
          },
          ),
          ),
          // 选词工具条（划线/高亮）：出现在选中词上方，与点击菜单同款组件
          if (_mdSelText.isNotEmpty && _selAnchor != null)
            Positioned(
              left: (_selAnchor!.left - 40)
                  .clamp(8.0, MediaQuery.of(context).size.width - 250),
              top: (_selAnchor!.top - 76).clamp(96.0, double.infinity),
              child: markToolbar([
                ('划线', () => _markFromSelection(false)),
                ('高亮', () => _markFromSelection(true)),
              ]),
            ),
          // 点击标注弹出的工具条（与选词菜单同款），点其他处关闭
          if (_tapMenuMark != null)
            Positioned(
              left: (_tapMenuMark!.$2.left - 30)
                  .clamp(8.0, MediaQuery.of(context).size.width - 260),
              top: (_tapMenuMark!.$2.top - 70).clamp(96.0, double.infinity),
              child: markToolbar([
                ('复制', () {
                  Clipboard.setData(ClipboardData(text: _tapMenuMark!.$1.text));
                  setState(() => _tapMenuMark = null);
                }),
                ('删除', () {
                  final mk = _tapMenuMark!.$1;
                  setState(() => _tapMenuMark = null);
                  _deleteMark(mk);
                }),
              ]),
            ),
        ]);
    }
  }

  static MarkdownStyleSheet _mdStyle(BuildContext c, double fs) {
    final base = MarkdownStyleSheet.fromTheme(Theme.of(c));
    final ss = base.copyWith(
      p: base.p?.copyWith(fontSize: fs, height: 1.7),
      h1: base.h1?.copyWith(fontSize: fs * 1.6),
      h2: base.h2?.copyWith(fontSize: fs * 1.4),
      h3: base.h3?.copyWith(fontSize: fs * 1.2),
      listBullet: base.listBullet?.copyWith(fontSize: fs),
      code: base.code?.copyWith(fontSize: fs * 0.92),
      blockSpacing: 8,
    );
    return ss;
  }
}

// 标注绘制层：高亮=矩形色块，划线=矩形底部波浪；全部基于实测矩形，排版恒定
class _MarkPainter extends CustomPainter {
  final ValueNotifier<List<(Mark, Rect)>> notifier; // rects 已是画布局部坐标
  _MarkPainter(this.notifier) : super(repaint: notifier);

  @override
  void paint(Canvas canvas, Size size) {
    final wavePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..color = ulBlue;
    // 先画全部色块再画波浪（同文字双标注时黄底在上、波浪叠底）
    for (final (m, r) in notifier.value) {
      if (m.isHighlight) {
        final hlPaint = Paint()..color = hlYellow.withValues(alpha: 0.82);
        final rr = RRect.fromRectAndRadius(r.inflate(1), const Radius.circular(3));
        canvas.drawRRect(rr, hlPaint);
      }
    }
    for (final (m, r) in notifier.value) {
      if (m.isHighlight) continue;
      final y = r.bottom - 2;
      final path = Path()..moveTo(r.left, y);
      const wave = 9.0, amp = 2.8;
      var x = r.left;
      var up = true;
      while (x < r.right) {
        final next = x + wave / 2;
        path.quadraticBezierTo((x + next) / 2, up ? y - amp : y + amp, next, y);
        x = next;
        up = !up;
      }
      canvas.drawPath(path, wavePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => true;
}

// ---------- 标注面板（搜索 / 跳转 / 删除） ----------// ---------- 标注面板（搜索 / 跳转 / 删除） ----------

class MarksPanel extends StatefulWidget {
  final List<Mark> marks;
  final void Function(Mark) onJump;
  final void Function(Mark) onDelete;
  const MarksPanel({super.key, required this.marks, required this.onJump, required this.onDelete});
  @override
  State<MarksPanel> createState() => _MarksPanelState();
}

class _MarksPanelState extends State<MarksPanel> {
  String _q = '';
  late final List<Mark> _list = List.of(widget.marks);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? darkCard : Colors.white;
    final shown = _q.isEmpty ? _list : _list.where((m) => m.text.contains(_q)).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.62,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(children: [
            Text('标注（${_list.length}）',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, size: 22),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: '搜索标注内容…',
              prefixIcon: const Icon(Icons.search, size: 24),
              isDense: true,
              filled: true,
              fillColor: dark ? Colors.black : lightBg,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(
                  child: Text('暂无标注', style: TextStyle(color: iosGray, fontSize: 15)))
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final m = shown[i];
                    return Container(
                      color: card,
                      child: InkWell(
                        onTap: () => widget.onJump(m),
                        child: Row(children: [
                          Container(
                            width: 6,
                            height: 52,
                            color: m.isHighlight ? hlYellow : ulBlue,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.text,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 15, height: 1.4)),
                                  if (m.isPdf)
                                    Text('第 ${m.page} 页',
                                        style: const TextStyle(fontSize: 12, color: iosGray)),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, size: 22),
                            color: iosGray,
                            onPressed: () {
                              setState(() => _list.remove(m));
                              widget.onDelete(m);
                            },
                          ),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
