// hmd —— 极简阅读器（iOS 风格 / 大按钮 / 左手操作）
// 支持 md / txt / pdf / epub / docx；微信"用其他应用打开"可直接跳转。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
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
        title: 'MD阅读器',
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
      ? Mark(j['i'], j['t'], j['b'] ?? '', j['a'] ?? '', (j['c'] as num?)?.toInt() ?? 0,
          j['h'] == true, j['p'] == true, (j['n'] as num?)?.toInt() ?? 0)
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

// 以"前文+选中文字"为锚点定位；找不到（文档已改/文本跨标签）则放弃该标注的回显。
// ponytail: 选中文本在全文多次出现时取第一次（SelectionArea 拿不到选区位置）；
// 升级路径：解析 SelectableRegion 的 per-Selectable TextPosition。
int anchorOf(String fullText, Mark m) {
  final i = fullText.indexOf(m.before + m.text);
  return i < 0 ? -1 : i + m.before.length;
}

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
  MarkSyntax() : super(r'⟦([hus])⟧(.+?)⟦/\1⟧');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('hmdMark', match[2]!)..attributes['t'] = match[1]!);
    return true;
  }
}

class MarkBuilder extends MarkdownElementBuilder {

  @override
  Widget? visitElementAfterWithContext(
      BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final text = element.textContent;
    final st = preferredStyle ?? TextStyle(fontSize: appFont.value, height: 1.7);
    final t = element.attributes['t'];
    if (t == 'h' || t == 's') {
      return Container(
        decoration: BoxDecoration(
            color: (t == 'h' ? hlYellow : searchOrange).withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(3)),
        child: Text(text, style: st),
      );
    }
    // 自绘波浪线：TextDecoration 在部分场景渲染过细/被吞，改用 CustomPaint 保证可见
    return Stack(children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text, style: st),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SizedBox(height: 6, child: CustomPaint(painter: _WavyPainter())),
      ),
    ]);
  }
}

class _WavyPainter extends CustomPainter {
  const _WavyPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final p = Path()..moveTo(0, mid);
    const wave = 8.0, amp = 2.6;
    var x = 0.0;
    var up = true;
    while (x < size.width) {
      final next = x + wave / 2;
      p.quadraticBezierTo((x + next) / 2, up ? mid - amp : mid + amp, next, mid);
      x = next;
      up = !up;
    }
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..color = ulBlue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
    if (mounted) setState(() {});
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(path: p, title: rec.name),
    ));
    if (mounted) setState(() => _recent = loadRecent());
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
            const Text('MD 阅读器',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, height: 1.25)),
            const SizedBox(height: 4),
            const Text('微信里收到的 Markdown，也能舒服地看',
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
              const Padding(
                padding: EdgeInsets.only(left: 12, bottom: 8),
                child: Text('最近', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: iosGray)),
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
          ],
        ),
      ),
    );
  }

  Widget _row(RecentRec r, Color card) => InkWell(
        onTap: () => _open(r),
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
  bool _searchOpen = false;
  final _searchCtrl = TextEditingController();
  String _query = '';
  int _searchIdx = 0;

  DocKind get _kind => kindOf(widget.title);

  @override
  void initState() {
    super.initState();
    _marks = loadMarks(widget.title);
    debugPrint('hmd mark: loaded ${_marks.length} marks for ${widget.title}');
    if (widget.initialContent != null) {
      _content = widget.initialContent;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- 标注 ----

  Future<void> _addMark(String text, bool hl) async {
    text = text.trim();
    if (text.isEmpty || text.length > 500) return;
    final src = _kind == DocKind.epub ? _html!.join('\n') : (_content ?? '');
    final i = src.indexOf(text);
    if (i < 0) return;
    final b = src.substring((i - 16).clamp(0, src.length), i);
    final e = (i + text.length + 16).clamp(0, src.length);
    final a = src.substring(i + text.length, e);
    var page = 0;
    if (_kind == DocKind.epub) {
      page = _html!.indexWhere((h) => h.contains(b + text) || h.contains(text));
      if (page < 0) page = 0;
    }
    final m = Mark(DateTime.now().microsecondsSinceEpoch.toString(), text, b, a,
        DateTime.now().millisecondsSinceEpoch, hl, false, page);
    debugPrint('hmd mark: saved id=${m.id} page=$page marks=${_marks.length + 1}');
    setState(() => _marks = [..._marks, m]);
    await saveMarks(widget.title, _marks);
    _toast(hl ? '已高亮' : '已划线');
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
    _toast(hl ? '已高亮（第 $page 页）' : '已划线（第 $page 页）');
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

  // md/epub 共用：系统选择菜单加"划线/高亮"。
  // ponytail: SelectableRegionState 无公开的取选中文本 API，借道剪贴板
  // （copySelection → Clipboard.getData），副作用是覆盖系统剪贴板。
  Widget _selectable(Widget child) => SelectionArea(
        contextMenuBuilder: (context, selectableRegion) =>
            AdaptiveTextSelectionToolbar.buttonItems(
          anchors: selectableRegion.contextMenuAnchors,
          buttonItems: [
            ContextMenuButtonItem(
              label: '划线',
              onPressed: () {
                ContextMenuController.removeAny();
                _markFromSelection(selectableRegion, false);
              },
            ),
            ContextMenuButtonItem(
              label: '高亮',
              onPressed: () {
                ContextMenuController.removeAny();
                _markFromSelection(selectableRegion, true);
              },
            ),
          ],
        ),
        child: child,
      );

  Future<void> _markFromSelection(SelectableRegionState region, bool hl) async {
    // ignore: deprecated_member_use
    region.copySelection(SelectionChangedCause.toolbar);
    final t = (await Clipboard.getData('text/plain'))?.text ?? '';
    debugPrint('hmd mark: selected="${t.length > 40 ? t.substring(0, 40) : t}" hl=$hl');
    region.clearSelection();
    await _addMark(t, hl);
  }

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
          onPressed: () {
            _searchCtrl.clear();
            setState(() {
              _searchOpen = false;
              _query = '';
            });
          },
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
        return _selectable(ValueListenableBuilder<double>(
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
        ));
      default: // md / txt / docx
        if (_content == null) return loading;
        return _selectable(ValueListenableBuilder<double>(
          valueListenable: appFont,
          builder: (_, fs, _) {
            final blocks = splitBlocks(_content!);
            _searchHitBlocks.clear();
            final children = <Widget>[];
            for (final (bi, raw) in blocks.indexed) {
              // 收集区间：标注（锚点定位）+ 搜索命中，排序去重叠（后者丢弃），从后往前注入 token
              final spans = <(int, int, String)>[];
              for (final m in _marks.where((m) => !m.isPdf)) {
                final i = raw.indexOf(m.before + m.text);
                if (i >= 0) {
                  spans.add((i + m.before.length,
                      i + m.before.length + m.text.length, m.isHighlight ? 'h' : 'u'));
                }
              }
              for (final (s, e) in findMatches(raw, _query)) {
                spans.add((s, e, 's'));
              }
              spans.sort((a, b) => a.$1.compareTo(b.$1));
              final clean = <(int, int, String)>[];
              var prevEnd = -1;
              for (final sp in spans) {
                if (sp.$1 < prevEnd) continue;
                clean.add(sp);
                prevEnd = sp.$2;
              }
              var data = raw;
              GlobalKey? blockKey;
              for (final (s, e, t) in clean.reversed) {
                data = data.replaceRange(s, e, '⟦$t⟧${data.substring(s, e)}⟦/$t⟧');
                blockKey ??= _blockKeys[bi] ??= GlobalKey();
              }
              if (blockKey != null) {
                for (final m in _marks.where((m) => !m.isPdf)) {
                  if (raw.contains(m.before + m.text)) _markKeys[m.id] ??= blockKey;
                }
                _searchHitBlocks.addAll([
                  for (final sp in clean)
                    if (sp.$3 == 's') bi
                ]);
              }
              final w = Markdown(
                data: data,
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                styleSheet: _mdStyle(context, fs),
                inlineSyntaxes: [MarkSyntax()],
                builders: {'hmdMark': MarkBuilder()},
              );
              children.add(blockKey == null ? w : KeyedSubtree(key: blockKey, child: w));
              if (bi < blocks.length - 1) children.add(const SizedBox(height: 8));
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: children,
            );
          },
        ));
    }
  }

  static MarkdownStyleSheet _mdStyle(BuildContext c, double fs) {
    final base = MarkdownStyleSheet.fromTheme(Theme.of(c));
    return base.copyWith(
      p: base.p?.copyWith(fontSize: fs, height: 1.7),
      h1: base.h1?.copyWith(fontSize: fs * 1.6),
      h2: base.h2?.copyWith(fontSize: fs * 1.4),
      h3: base.h3?.copyWith(fontSize: fs * 1.2),
      listBullet: base.listBullet?.copyWith(fontSize: fs),
      code: base.code?.copyWith(fontSize: fs * 0.92),
      blockSpacing: 8,
    );
  }
}

// ---------- 标注面板（搜索 / 跳转 / 删除） ----------

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
