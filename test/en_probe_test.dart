import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hmd/main.dart';

void dump(InlineSpan s, int depth) {
  if (s is TextSpan) {
    var txt = s.text ?? '';
    if (txt.length > 24) txt = txt.substring(0, 24);
    print('${' ' * depth}span "$txt" bg=${s.style?.background != null} decor=${s.style?.decoration}');
    for (final c in s.children ?? const <InlineSpan>[]) {
      dump(c, depth + 2);
    }
  }
}

void main() {
  testWidgets('英文 token span 探针', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Markdown(
        data: 'Flutter is \u27e6h\u27e7great\u27e6/h\u27e7. Flutter rocks.',
        shrinkWrap: true,
        inlineSyntaxes: [MarkSyntax()],
        builders: {
          'hmdH': MarkBuilder('h'),
          'hmdU': MarkBuilder('u'),
          'hmdS': MarkBuilder('s'),
        },
      ),
    ));
    await t.pumpAndSettle();
    for (final w in find.byType(RichText).evaluate()) {
      print('=== RichText ===');
      dump((w.widget as RichText).text, 0);
    }
  });
}
