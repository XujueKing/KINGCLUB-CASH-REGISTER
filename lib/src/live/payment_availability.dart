// This release has no Alipay merchant account. Existing transaction records and
// recovery remain readable; only new direct collections are disabled.
const alipayDirectEnabled = bool.fromEnvironment('CASHIER_ALIPAY_DIRECT');
