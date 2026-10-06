# Collection destination report

Current update: [mixed-refund integration](2026-10-07-mixed-refund-release.md) supersedes the foundation-only status below. Backend execution/history/report are deployed and the new terminal UI has been installed on SUNMI with data retained.

The overview displays store-direct receipts, original platform payable, refund reduction and pending settlement from the existing report response. Unknown historical collection routes are counted for review; they are not inferred from current merchant configuration. No additional page request or client-side financial calculation is introduced.

Backend migrations 366-370 are deployed. Store-direct collections do not credit merchant virtual balances. The new mixed-refund allocation function is internal foundation only; the cashier must not advertise mixed refund completion until original asset restoration and recovery are integrated.

Validation: five report widget tests passed in all four languages; ARM32 release built and signed with the existing identity; SUNMI installation used install -r and retained login/data. No real refund executed.
