"""Research-graph regression checks; positive evidence is assumed available.

This bounds knowledge reachability, not actual economy, geography or pacing.
"""
import json
import unittest

from techtree_lib import ERA_INDEX, NETWORK_PATH
from wave_d_presentation import build_visual_edges


def condition_met(condition, completed):
    if not condition:
        return True
    if "kind" in condition:
        return condition["id"] in completed if condition["kind"] == 0 else True
    values = [condition_met(child, completed) for child in condition.get("children", [])]
    operator = int(condition["operator"])
    if operator == 1:
        return all(values)
    if operator == 2:
        return any(values)
    if operator == 3:
        return sum(values) >= condition["required_count"]
    if operator in (4, 5):
        return not any(values)
    raise ValueError(condition)


def reachable(network, forbidden=()):
    forbidden = set(forbidden)
    completed = {node["id"] for node in network["nodes"]
                 if node.get("is_starter_eligible") or node.get("is_starting")}
    completed -= forbidden
    eras = {era["id"]: i for i, era in enumerate(network["eras"])}
    while True:
        before = len(completed)
        for node in network["nodes"]:
            if node["id"] in completed | forbidden:
                continue
            if not set(node["hard_prerequisite_ids"]) <= completed:
                continue
            if not condition_met(node.get("reveal_condition", {}), completed):
                continue
            routes = node.get("research_routes", [])
            if routes and not any(condition_met(route["condition"], completed) for route in routes):
                continue
            if node.get("is_milestone"):
                index = eras[node["era_id"]]
                era = network["eras"][index]
                if index and network["eras"][index - 1]["milestone_id"] not in completed:
                    continue
                if len(set(era["milestone_candidate_ids"]) & completed) < era["candidate_required"]:
                    continue
            completed.add(node["id"])
        if before == len(completed):
            return completed


class FoundationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.network = json.loads(NETWORK_PATH.read_text(encoding="utf-8"))
        cls.nodes = {node["id"]: node for node in cls.network["nodes"]}

    def test_no_research_without_institution(self):
        starters = {node["id"] for node in self.nodes.values()
                    if node.get("is_starter_eligible") or node.get("is_starting")}
        self.assertEqual(reachable(self.network, ["tech.early_knowledge_institution"]), starters)

    def test_full_knowledge_graph_remains_reachable(self):
        self.assertEqual(reachable(self.network), set(self.nodes))

    def test_order_eras_and_visual_edges_match(self):
        order = {node["id"]: i for i, node in enumerate(self.network["nodes"])}
        for node in self.nodes.values():
            for prerequisite in node["hard_prerequisite_ids"]:
                with self.subTest(target=node["id"], prerequisite=prerequisite):
                    self.assertLess(order[prerequisite], order[node["id"]])
                    self.assertLessEqual(ERA_INDEX[self.nodes[prerequisite]["era_id"]],
                                         ERA_INDEX[node["era_id"]])
        self.assertEqual(self.network["visual_edges"], build_visual_edges(self.network))

    def test_maize_research_routes_use_agricultural_practice(self):
        signals = {route["condition"]["id"] for route in
                   self.nodes["tech.maize_selection"]["research_routes"]}
        self.assertEqual(signals, {"development.employment.agriculture.10_90d",
                                   "development.output.agriculture.100_180d"})


if __name__ == "__main__":
    unittest.main()
