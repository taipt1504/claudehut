---
type: regex
target: trace
pattern: '(interface|abstract class)\s+\w*(Party|Kyc|Customer)\w*(Client|Gateway|Port|Provider|Strategy)\b|class\s+\w*(Kyc|Party)\w*(Factory|Strategy)\b'
match: not_contains
arm: both
---
