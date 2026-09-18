// strings.dart 最小自检：各语言键集合一致、占位符成对、语言切换与回退。
import 'package:flutter_test/flutter_test.dart';
import 'package:hmd/strings.dart';

void main() {
  test('各语言键集合一致且占位符成对出现', () {
    final zhKeys = kStrings['zh']!.keys.toSet();
    final ph = RegExp(r'\{(n|name)\}');
    for (final e in kStrings.entries) {
      expect(e.value.keys.toSet(), zhKeys, reason: e.key);
      for (final kv in e.value.entries) {
        expect(
          ph.allMatches(kv.value).map((m) => m.group(1)).toSet(),
          ph.allMatches(kStrings['zh']![kv.key]!).map((m) => m.group(1)).toSet(),
          reason: '${e.key}:${kv.key}',
        );
      }
    }
  });

  test('initStrings 按系统语言切换，未支持语言回退英文，缺键逐级回退', () {
    initStrings('zh_CN_#Hans');
    expect(s('cancel'), '取消');
    initStrings('en_US');
    expect(s('cancel'), 'Cancel');
    initStrings('ja_JP');
    expect(s('cancel'), 'キャンセル');
    initStrings('ko_KR');
    expect(s('search'), '검색');
    initStrings('de_DE');
    expect(s('cancel'), 'Abbrechen');
    initStrings('fr_FR');
    expect(s('cancel'), 'Annuler');
    initStrings('it_IT');
    expect(s('cancel'), 'Cancel'); // 未支持语言 → 英文
    expect(s('no_such_key'), 'no_such_key'); // 缺键回退到键名本身
  });
}
