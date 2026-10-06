// 程序型网页嗅探与提示注入的最小自检（isJsAppHtml / jsAppNotice）。
import 'package:flutter_test/flutter_test.dart';
import 'package:hmd/main.dart';
import 'package:hmd/strings.dart';

void main() {
  test('嗅探：canvas 或大段内联脚本 → 程序型；小埋点脚本不误报', () {
    expect(isJsAppHtml('<body><canvas id="map"></canvas></body>'), isTrue);
    expect(isJsAppHtml('<body>x<script>${'v' * 1600}</script></body>'), isTrue);
    expect(
        isJsAppHtml(
            '<style>p{color:red}</style><p>正文</p><script>track();</script>'),
        isFalse);
  });

  test('注入：提示块紧跟 <body>；无 body 片段则前置；文案来自词表', () {
    final out = jsAppNotice('<html><body><p>壳</p></body></html>');
    expect(out, startsWith('<html><body><div style="border:1px solid'));
    expect(out, endsWith('<p>壳</p></body></html>'));
    final frag = jsAppNotice('<p>片段</p>');
    expect(frag, startsWith('<div style="border:1px solid'));
    expect(frag, contains(s('js_web_notice')));
  });
}
