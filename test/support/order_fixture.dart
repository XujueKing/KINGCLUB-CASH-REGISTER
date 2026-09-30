// Local test-only records; never imported by application code.
Map<String, dynamic> orderFixture() => {
  'result': {
    'storeRef': 'test-store',
    'tableRef': 'test-000',
    'session': {
      'sessionRef': 'session-0',
      'status': 'open',
      'paymentTiming': 'prepay',
      'businessDate': '2026-09-29',
    },
    'observedAt': '2026-09-29T08:00:00.000Z',
    'nextAfterOrder': null,
    'orders': [
      <String, dynamic>{
        'orderRef': 'D00000000001',
        'status': 'pending',
        'currency': 'CNY',
        'totalCents': 1200,
        'createdAt': '2026-09-29T08:00:00.000000Z',
        'items': [
          <String, dynamic>{
            'productRef': 'test-product',
            'quantity': 2,
            'servedQuantity': 0,
            'remainingQuantity': 2,
            'priceCents': 600,
            'subtotalCents': 1200,
            'snapshot': {
              'revision': 1,
              'names': {
                'zh-CN': '测试商品',
                'en': 'Test product',
                'zh-TW': '測試商品',
                'th': 'สินค้าทดสอบ',
              },
              'specifications': {
                'zh-CN': '瓶',
                'en': 'Bottle',
                'zh-TW': '瓶',
                'th': 'ขวด',
              },
            },
          },
        ],
      },
    ],
  },
};
