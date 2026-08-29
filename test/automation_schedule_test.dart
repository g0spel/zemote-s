import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/ui/automation_page.dart';

void main() {
  group('scheduleLabel', () {
    test('structured rules render in Chinese', () {
      expect(
          scheduleLabel({
            'scheduleRule': {'unit': 'minute', 'interval': 1}
          }),
          '每分钟');
      expect(
          scheduleLabel({
            'scheduleRule': {'unit': 'minute', 'interval': 5}
          }),
          '每 5 分钟');
      expect(
          scheduleLabel({
            'scheduleRule': {'unit': 'hour', 'interval': 2}
          }),
          '每 2 小时');
      expect(
          scheduleLabel({
            'scheduleRule': {'unit': 'day', 'interval': 1, 'hour': 9, 'minute': 5}
          }),
          '每天 09:05');
      expect(
          scheduleLabel({
            'scheduleRule': {'unit': 'week', 'weekday': 3, 'hour': 11, 'minute': 17}
          }),
          '周三 11:17');
    });

    test('falls back to the cron expression without a rule', () {
      expect(scheduleLabel({'cronExpr': '0 9 * * *'}), '0 9 * * *');
      expect(scheduleLabel(const {}), '—');
    });

    test('unknown rule units fall back too', () {
      expect(
          scheduleLabel({
            'cronExpr': '@daily',
            'scheduleRule': {'unit': 'fortnight'}
          }),
          '@daily');
    });
  });

  group('lifecycleLabel', () {
    test('non-active statuses map, active stays null', () {
      expect(lifecycleLabel('completed'), '已完成');
      expect(lifecycleLabel('failed'), '失败');
      expect(lifecycleLabel('paused'), '已暂停');
      expect(lifecycleLabel('active'), isNull);
      expect(lifecycleLabel(''), isNull);
    });
  });
}
