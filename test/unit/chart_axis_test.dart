import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/shared/widgets/charts.dart';

void main() {
  test('niceAxisMax gives whole-number quarter intervals', () {
    expect(niceAxisMax(0), 100);
    expect(niceAxisMax(3), 4);
    expect(niceAxisMax(10), 16);
    expect(niceAxisMax(37), 40);
    expect(niceAxisMax(95), 100);
    expect(niceAxisMax(1234), 1600);
    expect(niceAxisMax(4100), 8000);
    for (final v in [1.0, 7.0, 55.0, 999.0, 12345.0, 87000.0]) {
      final max = niceAxisMax(v);
      expect(max, greaterThanOrEqualTo(v));
      final interval = max / 4;
      expect(interval, interval.roundToDouble(), reason: 'value $v');
    }
  });
}
