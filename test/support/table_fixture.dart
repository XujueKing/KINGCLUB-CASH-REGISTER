// Synthetic records only for local tests; never imported by lib/.
Map<String, dynamic> tableFixture({int count = 1, String? next}) => {
  'result': {
    'store': {
      'storeRef': 'test-store',
      'storeName': 'Test store',
      'currency': 'CNY',
      'businessDate': '2026-09-29',
    },
    'operator': {
      'employeeRef': 'E00000000001',
      'displayName': 'Test employee',
      'permissions': ['workbench.read'],
    },
    'observedAt': '2026-09-29T08:00:00.000Z',
    'tables': [
      for (var i = 0; i < count; i++)
        <String, dynamic>{
          'tableRef': 'test-${i.toString().padLeft(3, '0')}',
          'tableName': 'Test table $i',
          'tableStatus': 'active',
          'minimumSeats': 1,
          'maximumSeats': 6,
          'session': {
            'sessionRef': 'session-$i',
            'status': 'open',
            'paymentTiming': 'postpay',
            'businessDate': '2026-09-28',
            'partySize': null,
            'partyRevision': 0,
            'elapsedMinutes': 125,
            'paidCents': 1201,
            'pendingCents': 7800,
            'paidOrders': 1,
            'pendingOrders': 1,
          },
        },
    ],
    'nextAfterTable': next,
  },
};
