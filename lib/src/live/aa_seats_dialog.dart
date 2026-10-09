import 'dart:convert';

import 'package:flutter/material.dart';

import '../strings.dart';
import 'table_snapshot.dart';

class AaSeatsDialog extends StatelessWidget {
  const AaSeatsDialog({
    super.key,
    required this.table,
    required this.language,
    required this.onRefresh,
  });
  final LiveTable table;
  final UiLanguage language;
  final Future<void> Function() onRefresh;
  String text(String zh, String en, String tw, String th) => switch (language) {
    UiLanguage.en => en,
    UiLanguage.tw => tw,
    UiLanguage.th => th,
    _ => zh,
  };
  @override
  Widget build(BuildContext context) {
    final party = table.aaParty!;
    return AlertDialog(
      title: Text('${table.name} · ${tr(language, 'tableKind_aa')}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text(
                  '总席位 ${party.capacity} · 已占座 ${party.confirmedCount} · 已入场 ${party.admittedCount}',
                  '${party.capacity} seats · ${party.confirmedCount} booked · ${party.admittedCount} admitted',
                  '總席位 ${party.capacity} · 已佔座 ${party.confirmedCount} · 已入場 ${party.admittedCount}',
                  '${party.capacity} ที่นั่ง · จอง ${party.confirmedCount} · เข้างาน ${party.admittedCount}',
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: List.generate(party.capacity, (i) {
                  final member = i < party.participants.length
                      ? party.participants[i]
                      : null;
                  final photo = member?['avatarBase64'];
                  final gender = member?['gender'];
                  final placeholder = Icon(
                    gender == 1
                        ? Icons.male
                        : gender == 2
                        ? Icons.female
                        : member != null
                        ? Icons.person_outline
                        : i < (party.capacity + 1) ~/ 2
                        ? Icons.male
                        : Icons.female,
                  );
                  return SizedBox(
                    width: party.capacity <= 8 ? 112 : 88,
                    child: Column(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: member == null
                                ? Colors.black12
                                : const Color(0xFFFACC15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: photo is String
                              ? Image.memory(
                                  base64Decode(photo),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => placeholder,
                                )
                              : placeholder,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          member?['name'] as String? ??
                              text('空位', 'Available', '空位', 'ว่าง'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (member != null)
                          Text(
                            member['admitted'] == true
                                ? text('已入场', 'Admitted', '已入場', 'เข้างานแล้ว')
                                : text('待入场', 'Expected', '待入場', 'รอเข้างาน'),
                            style: const TextStyle(fontSize: 11),
                          ),
                      ],
                    ),
                  );
                }),
              ),
              const SizedBox(height: 20),
              Text(
                text(
                  '席位随有效报名同步；顾客出示入场码核销后记为已入场。',
                  'Seats follow confirmed bookings. Scan the admission ticket to check in.',
                  '席位隨有效報名同步；顧客出示入場碼核銷後記為已入場。',
                  'ที่นั่งอัปเดตตามการจอง สแกนบัตรเพื่อเข้างาน',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: onRefresh,
          child: Text(text('刷新', 'Refresh', '重新整理', 'รีเฟรช')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(text('关闭', 'Close', '關閉', 'ปิด')),
        ),
      ],
    );
  }
}
