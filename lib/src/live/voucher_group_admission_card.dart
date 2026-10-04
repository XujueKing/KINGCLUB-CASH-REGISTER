import 'package:flutter/material.dart';

import '../strings.dart';

/// Table package preview only. All quantities come from the server; selecting
/// a person count neither redeems a voucher nor changes the seated population.
class VoucherGroupAdmissionCard extends StatefulWidget {
  const VoucherGroupAdmissionCard({
    super.key,
    required this.data,
    required this.language,
  });
  final Map<String, dynamic> data;
  final UiLanguage language;
  @override
  State<VoucherGroupAdmissionCard> createState() =>
      _VoucherGroupAdmissionCardState();
}

class _VoucherGroupAdmissionCardState extends State<VoucherGroupAdmissionCard> {
  String? variant;
  int? people;
  String text(String zh, String en, String tw, String th) =>
      switch (widget.language) {
        UiLanguage.zh => zh,
        UiLanguage.en => en,
        UiLanguage.tw => tw,
        UiLanguage.th => th,
      };
  @override
  Widget build(BuildContext context) {
    final portions = (widget.data['portions'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final matches = portions.where(
      (p) => p['variantRef'] == variant && p['people'] == people,
    );
    final portion = matches.isEmpty ? null : matches.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          text(
            '一券一人入场 · 整桌统一配酒',
            'One admission per voucher · Drinks per table',
            '一券一人入場 · 整桌統一配酒',
            'หนึ่งคนต่อคูปอง · เครื่องดื่มต่อโต๊ะ',
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          children: [
            for (final v in ['A', 'B'])
              ChoiceChip(
                label: Text(text('$v 套餐', 'Package $v', '$v 套餐', 'ชุด $v')),
                selected: variant == v,
                onSelected: (_) => setState(() => variant = v),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(text('整桌人数', 'People at the table', '整桌人數', 'จำนวนคนทั้งโต๊ะ')),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var n = 1; n <= 10; n++)
              ChoiceChip(
                key: ValueKey('admission-people-$n'),
                label: Text('$n'),
                selected: people == n,
                onSelected: (_) => setState(() => people = n),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (portion == null)
          Text(
            text(
              '选择套餐和人数查看配酒',
              'Choose package and people to preview',
              '選擇套餐和人數查看配酒',
              'เลือกชุดและจำนวนคนเพื่อดูรายการ',
            ),
          )
        else ...[
          Text(
            portion['portion'] == 'half'
                ? text(
                    '酒水软饮半份 · 小吃3份',
                    'Half drinks · 3 snacks',
                    '酒水軟飲半份 · 小吃3份',
                    'เครื่องดื่มครึ่งชุด · ของว่าง 3 ที่',
                  )
                : text(
                    '标准整桌份量',
                    'Standard table package',
                    '標準整桌份量',
                    'ชุดมาตรฐานสำหรับโต๊ะ',
                  ),
          ),
          for (final line in portion['lines'] as List? ?? [])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('${line['name']} × ${line['quantity']}'),
            ),
          if (portion['configured'] != true)
            Text(
              text(
                '商品规格待绑定，暂不能配发',
                'Product variants need binding before serving',
                '商品規格待綁定，暫不能配發',
                'ต้องเชื่อมรายการสินค้าก่อนจัดเสิร์ฟ',
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ],
    );
  }
}
