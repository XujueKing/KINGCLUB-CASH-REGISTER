import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/network/ccsop_crypto.dart';

void main() {
  test('large inventory response decrypts off the UI isolate and rejects tampering', () async {
    final key = SecretKey(List<int>.filled(32, 7));
    final value = {
      'result': {
        'products': List.generate(
          1500,
          (i) => {
            'name': '酒水$i',
            'specification': '700ml',
            'description': '商品资料' * 30,
          },
        ),
      },
    };
    final encrypted = await encrypt(key, value);
    expect(encrypted['ciphertext']!.length, greaterThan(128 * 1024));
    final request = SealedRequest({}, {}, key);
    expect(
      await request.openResponse({
        'status': 1,
        'code': 'success',
        'data': encrypted,
      }),
      value,
    );
    await expectLater(
      request.openResponse({
        'status': 1,
        'code': 'success',
        'data': {...encrypted, 'tag': b64(List<int>.filled(16, 0))},
      }),
      throwsException,
    );
  });
}
