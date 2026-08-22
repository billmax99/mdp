// hmd —— 极简 Markdown 阅读器（iOS 风格 / 大按钮 / 左手操作）
// 场景：微信里收到的 .md 文件打不开。本应用可通过系统"用其他应用打开"
// 直接接收，或在应用内自行选择文件。文件会被复制到应用私有目录保存。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

const iosBlue = Color(0xFF007AFF);
const lightBg = Color(0xFFF2F2F7);
const darkCard = Color(0xFF1C1C1E);
const iosGray = Color(0xFF8E8E93);
const minFont = 14.0, maxFont = 28.0;

late SharedPreferences prefs;
final appFont = ValueNotifier<double>(18); // 阅读正文字号
final appDark = ValueNotifier<bool>(false);

Future<void> initPrefs() async {
  prefs = await SharedPreferences.getInstance();
  appFont.value = prefs.getDouble('fontSize') ?? 18;
  appDark.value = prefs.getBool('dark') ?? false;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initPrefs();
  runApp(const HmdApp());
}

class HmdApp extends StatelessWidget {
  const HmdApp({super.key});

  static ThemeData theme(Brightness b) {
    final dark = b == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: ColorScheme.fromSeed(seedColor: iosBlue, brightness: b)
          .copyWith(primary: iosBlue, surface: dark ? darkCard : Colors.white),
      scaffoldBackgroundColor: dark ? Colors.black : lightBg,
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? Colors.black : lightBg,
        foregroundColor: dark ? Colors.white : Colors.black,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: appDark,
      builder: (_, dark, _) => MaterialApp(
        title: 'MD阅读器',
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
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

List<RecentRec> loadRecent() => (prefs.getStringList('recent') ?? const [])
    .map((s) => RecentRec.fromJson(jsonDecode(s)))
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
      allowedExtensions: ['md', 'markdown', 'txt', 'mdown'],
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
        bottom: false,
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
            const Icon(Icons.description_outlined, size: 28, color: iosBlue),
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
  String? _content;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialContent != null) {
      _content = widget.initialContent;
    } else {
      _read();
    }
  }

  Future<void> _read() async {
    final f = File(widget.path);
    try {
      final t = await f.readAsString();
      if (mounted) setState(() => _content = t);
    } on FileSystemException {
      if (mounted) setState(() => _error = '文件不存在或无法读取');
    } on FormatException {
      // ponytail: 非 UTF-8 编码用 Latin-1 兜底（中文文档几乎都是 UTF-8，走不到这）
      try {
        final t = await f.readAsString(encoding: latin1);
        if (mounted) setState(() => _content = t);
      } catch (_) {
        if (mounted) setState(() => _error = '文件编码无法识别');
      }
    }
  }

  void _setFont(double v) {
    final n = v.clamp(minFont, maxFont);
    appFont.value = n;
    prefs.setDouble('fontSize', n);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? darkCard : Colors.white;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 22),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _error != null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline_rounded, size: 46, color: iosGray),
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(fontSize: 16, color: iosGray)),
              ]),
            )
          : _content == null
              ? const Center(child: CircularProgressIndicator(color: iosBlue))
              : ValueListenableBuilder<double>(
                  valueListenable: appFont,
                  builder: (_, fs, _) => Markdown(
                    data: _content!,
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    styleSheet: _mdStyle(context, fs),
                  ),
                ),
      // 左手工具条：按钮集中左侧，右手拇指区域留给滚动
      bottomNavigationBar: SafeArea(
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
                  child: VerticalDivider(width: 14, thickness: 0.5, color: dark ? Colors.white24 : Colors.black12),
                ),
                IconButton(
                  iconSize: 26,
                  onPressed: () {
                    appDark.value = !appDark.value;
                    prefs.setBool('dark', appDark.value);
                  },
                  icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                  tooltip: dark ? '浅色模式' : '深色模式',
                ),
              ]),
            ),
          ),
        ),
      ),
    );
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
    );
  }
}
