import '../strings.dart';

String memberCopy(UiLanguage language, String zh, String en) {
  if (language == UiLanguage.zh) return zh;
  if (language == UiLanguage.en) return en;
  return memberTranslations[en]?[language == UiLanguage.tw ? 0 : 1] ?? en;
}

const memberTranslations = <String, List<String>>{
  'Could not load members. Retry.': [
    '會員列表載入失敗，請重試',
    'โหลดรายชื่อสมาชิกไม่ได้ โปรดลองใหม่',
  ],
  'Member details unavailable': ['會員資料暫不可用', 'ไม่สามารถดูข้อมูลสมาชิกได้'],
  'Added to this store': ['已加入本店會員', 'เพิ่มเป็นสมาชิกของร้านแล้ว'],
  'Refresh the member code and scan again': [
    '請顧客刷新會員碼後重掃',
    'รีเฟรชรหัสสมาชิกแล้วสแกนใหม่',
  ],
  'Store members': ['本店會員', 'สมาชิกของร้าน'],
  'Scan a member code to add to this store': [
    '掃會員碼，加入本店會員',
    'สแกนรหัสเพื่อเพิ่มสมาชิกของร้าน',
  ],
  'No members yet. Scan to add.': [
    '暫無會員，掃碼即可加入',
    'ยังไม่มีสมาชิก สแกนเพื่อเพิ่ม',
  ],
  'More': ['更多', 'เพิ่มเติม'],
  'Select a member or scan their code': [
    '選擇會員或掃描會員碼',
    'เลือกสมาชิกหรือสแกนรหัสสมาชิก',
  ],
  'Phone: ': ['手機號：', 'โทรศัพท์: '],
  'Not provided': ['暫無可用號碼', 'ยังไม่มีหมายเลข'],
  'Member card': ['會員儲值卡', 'บัตรเติมเงินสมาชิก'],
  'Principal': ['本金', 'ยอดเติมเงิน'],
  'Gift': ['贈送', 'โบนัส'],
  'Refund pending; balance temporarily frozen': [
    '退款處理中，餘額暫時凍結',
    'กำลังคืนเงิน ยอดถูกระงับชั่วคราว',
  ],
  'Recharge': ['充值', 'เติมเงิน'],
  'Refund': ['退款', 'คืนเงิน'],
  'Recharge history and status are below': [
    '下方為充值記錄與狀態',
    'ดูประวัติและสถานะการเติมเงินด้านล่าง',
  ],
  'History': ['充值記錄', 'ประวัติเติมเงิน'],
  'Recharge settings': ['充值設定', 'ตั้งค่าการเติมเงิน'],
  'Recharge history': ['充值記錄', 'ประวัติเติมเงิน'],
  'Refunded': ['已退款', 'คืนเงินแล้ว'],
  'Refund pending': ['退款處理中', 'กำลังคืนเงิน'],
  'Credited': ['已到帳', 'ได้รับเงินแล้ว'],
  'Awaiting payment / credit': ['待付款／到帳', 'รอชำระเงิน / รับยอด'],
  'Check refund': ['查詢退款', 'ตรวจสอบการคืนเงิน'],
  'Pay / check': ['收款／查詢', 'รับเงิน / ตรวจสอบ'],
  'Pay': ['充', 'เติม'],
  'New offer': ['新增檔位', 'เพิ่มรายการเติมเงิน'],
  'Close': ['關閉', 'ปิด'],
  'Recharge and gift': ['充值與贈送', 'เติมเงินและโบนัส'],
  'Cancel': ['取消', 'ยกเลิก'],
  'Enter a valid amount': ['請輸入有效金額', 'กรุณาระบุจำนวนเงินที่ถูกต้อง'],
  'Could not save. Retry.': ['儲存失敗，請重試', 'บันทึกไม่ได้ โปรดลองใหม่'],
  'Save': ['儲存', 'บันทึก'],
  'Add an offer in Recharge settings first': [
    '請先在充值設定中新增檔位',
    'เพิ่มรายการในตั้งค่าการเติมเงินก่อน',
  ],
  'Choose recharge amount': ['選擇充值金額', 'เลือกจำนวนเงินเติม'],
  'Recharge not prepared; check store payment settings': [
    '充值單未建立，請檢查本店支付設定',
    'สร้างรายการไม่ได้ โปรดตรวจสอบการตั้งค่ารับเงินของร้าน',
  ],
  'Select recharge': ['選擇充值記錄', 'เลือกรายการเติมเงิน'],
  'Refund to original payment': ['原路退款', 'คืนเงินไปยังช่องทางเดิม'],
  'Consumed': ['已消費', 'ใช้ไปแล้ว'],
  'Cancel gift': ['取消贈送', 'ยกเลิกโบนัส'],
  'Confirm refund': ['確認退款', 'ยืนยันคืนเงิน'],
  'Refund completed; gifts cancelled': [
    '退款完成，贈送已取消',
    'คืนเงินแล้วและยกเลิกโบนัสแล้ว',
  ],
  'Refund pending; check in history': [
    '退款處理中，可在記錄中查詢',
    'กำลังคืนเงิน ตรวจสอบได้ในประวัติ',
  ],
  'Refund not completed; check the original recharge': [
    '退款未完成，請查詢原充值記錄',
    'การคืนเงินยังไม่เสร็จ โปรดตรวจสอบรายการเดิม',
  ],
  'Checking recharge': ['正在查詢充值單', 'กำลังตรวจสอบรายการเติมเงิน'],
  'Show WeChat payment code': ['請出示微信付款碼', 'แสดงรหัสชำระเงิน WeChat'],
  'Checking payment': ['正在核對付款結果', 'กำลังตรวจสอบการชำระเงิน'],
  'Payment unconfirmed; check original order': [
    '暫未確認付款，請查詢原單',
    'ยังไม่ยืนยันการชำระ โปรดตรวจสอบรายการเดิม',
  ],
  'Customer WeChat payment code': ['顧客微信付款碼', 'รหัสชำระเงิน WeChat ของลูกค้า'],
  'Check payment': ['查詢付款', 'ตรวจสอบการชำระเงิน'],
};
