import 'package:flutter_test/flutter_test.dart';

import 'package:bpb/models/settings.dart';

void main() {
  test('chain proxy metadata survives JSON round-trip', () {
    const config = ChainProxy(
      id: 'test-id',
      name: 'Test config',
      link: 'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls#test',
      favorite: true,
      category: 'Work',
    );

    final restored = ChainProxy.parse(config.toJson());
    expect(restored, isNotNull);
    expect(restored!.id, config.id);
    expect(restored.name, config.name);
    expect(restored.link, config.link);
    expect(restored.favorite, isTrue);
    expect(restored.category, 'Work');
  });

  test('old chain proxy JSON remains compatible', () {
    final restored = ChainProxy.parse({
      'id': 'legacy',
      'name': 'Legacy config',
      'link': 'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls#legacy',
    });

    expect(restored, isNotNull);
    expect(restored!.favorite, isFalse);
    expect(restored.category, isNull);
  });
}
