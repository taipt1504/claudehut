---
type: regex
target: trace
pattern: '(interface|abstract class)\s+\w*(Ledger|Balance)\w*\b|class\s+\w*(Ledger|Balance)\w*(Factory|Registry|Strategy|Selector)\b'
match: not_contains
arm: both
---
