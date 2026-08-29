import 'package:flutter_test/flutter_test.dart';

import 'package:zflow/ui/model_providers_page.dart';
import 'package:zflow/ui/usage_page.dart';

void main() {
  group('usage limit semantics', () {
    final unit5 = <String, dynamic>{
      'type': 'TIME_LIMIT', 'unit': 5, 'number': 1,
      'usage': 4000, 'currentValue': 8, 'remaining': 3992,
      'percentage': 1, 'nextResetTime': 1789467856997,
    };
    final unit3 = <String, dynamic>{
      'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 77,
      'nextResetTime': 1787148326188,
    };
    final unit6 = <String, dynamic>{
      'type': 'TOKENS_LIMIT', 'unit': 6, 'number': 1, 'percentage': 58,
      'nextResetTime': 1787394256998,
    };

    test('unit5 is the MCP quota row and carries the total in usage',
        () {
      expect(isMcpQuotaLimit(unit5), isTrue);
      expect(isMcpQuotaLimit(unit3), isFalse);
      expect(mcpQuotaTotal([unit5, unit3, unit6]), 4000);
    });

    test('window labels', () {
      expect(limitWindowLabel(unit3), '五小时剩余');
      expect(limitWindowLabel(unit6), '每周剩余');
    });

    test('TOKENS percentage is USED percent → remaining = 100 − used', () {
      expect(tokensRemainingPercent(unit3), 23);
      expect(tokensRemainingPercent(unit6), 42);
      expect(tokensRemainingPercent({'percentage': 100}), 0);
      expect(tokensRemainingPercent({}), isNull);
    });

    test('subscription times are ISO strings parsed to local format', () {
      final out = fmtIsoTime('2026-10-15T02:00:00.000Z');
      expect(out, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')));
      expect(fmtIsoTime(null), '-');
      expect(fmtIsoTime('not-a-date'), 'not-a-date');
    });
  });

  group('provider status (official-client alignment)', () {
    test('custom providers without enabled field are 已启用', () {
      final status = providerStatusOf({
        'id': 'fef59e36', 'name': 'Zai', 'apiKeyRequired': true,
        'apiKey': 'sk-xxx',
      });
      expect(status, ProviderStatus.enabled);
    });

    test('coding plan with enabled=true is 已启用', () {
      expect(
        providerStatusOf({
          'id': 'builtin:bigmodel-coding-plan', 'enabled': true,
          'apiKey': '',
        }),
        ProviderStatus.enabled,
      );
    });

    test('systemDisabledReason wins → 已停用', () {
      expect(
        providerStatusOf({
          'enabled': false,
          'systemDisabledReason': 'coding_plan_not_entitled',
        }),
        ProviderStatus.disabled,
      );
      expect(providerDisabledReasonText('coding_plan_not_entitled'),
          '无订阅资格');
      expect(providerDisabledReasonText('oauth_provider_inactive'),
          '登录已失效');
    });

    test('required but empty API key → 未配置', () {
      expect(
        providerStatusOf({
          'apiKeyRequired': true, 'apiKey': '',
        }),
        ProviderStatus.unconfigured,
      );
    });
  });

  group('primary provider (wire `source` field)', () {
    test('内置供应商(无 source / source 非 custom)→ 主供应商', () {
      expect(isPrimaryProvider({'id': 'builtin:bigmodel'}), isTrue);
      expect(
        isPrimaryProvider({
          'id': 'fef59e36', 'name': 'Zai', 'source': 'builtin',
        }),
        isTrue,
      );
    });

    test('自建供应商(source: custom)→ 非主', () {
      expect(
        isPrimaryProvider({
          'id': 'custom:abc', 'name': '我的中转', 'source': 'custom',
        }),
        isFalse,
      );
    });

    test('source 缺失视为非自建(主供应商默认展开)', () {
      expect(isPrimaryProvider({}), isTrue);
    });
  });
}
