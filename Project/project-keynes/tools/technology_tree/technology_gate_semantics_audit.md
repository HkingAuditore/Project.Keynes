# Technology Gate Semantics Audit

Generated from `data/technology/technology_network.json` (schema 3).

## Summary

- Nodes: 361
- Nodes with reveal conditions: 315
- Nodes with research routes: 230
- Research routes fully implied by hard-prerequisite history: 0
- Reveal conditions fully implied by hard-prerequisite history: 0
- Nodes reusing a signal atom in reveal and a research route: 0
- Nodes whose reveal shares signal atoms with hard-prerequisite ancestors: 0
- Repeated reveal-formula groups: 74
- Unexplained repeated reveal-formula groups: 0
- Invalid/self/future route references: 0
- Nodes with non-distinct route types: 0
- Kingdom+ route coverage: 96.0%

A route is considered historically implied only when every atom required by its condition is already guaranteed by completed hard ancestors or their persistent discovery evidence. Disjunctions are treated conservatively: every branch must be guaranteed.

## Blocking Findings

### Fully Implied Reveal Conditions

- 无

### Fully Implied Research Routes

- 无

### Reveal And Route Signal Reuse

- 无

### Invalid Route References

- 无

## Design Review Findings

### Reveal Signal Reused From Hard-Prerequisite Ancestors

- 无

### Repeated Reveal Templates

- 无

## Gate Interpretation

- 核心知识只来自 hard_prerequisite_ids；揭示条件只描述观察到的问题或压力。
- 研究路线只描述解决问题所需能力，多个路线通过 ANY_OF 独立解释。
- route_exemption_reason 只允许用于真正的辨识节点或终端应用叶节点。

