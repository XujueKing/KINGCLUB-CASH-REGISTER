# Supplier procurement catalog

Inventory > Suppliers now has a Procurement catalog action. It makes one read through the existing inventory super API, then filters by category and name/specification locally without refetching. Supplier quoted units remain visible; missing quotations display Ask for quote. The dialog shows when the source collection is incomplete. No purchase, sale SKU, stock or menu publication occurs from viewing the catalog.

Validation: focused analysis passed; six inventory widget tests passed. Operational supplier data remains outside source control. Backend contract and storage are documented in ccsop-service's matching supplier-catalog document.

## Product reference quotations

Inventory product detail displays original supplier quote and packaging. Purchase starts with the matched per-unit reference price; switching supplier clears the previous quote price. Warning-policy editing retains quote evidence. Existing batch costs are not changed. Backend uses the existing inventory policy action and stored procedure, with no new page request.
