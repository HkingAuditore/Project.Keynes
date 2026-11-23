"""Verify every derived copy inside technology_network.json against its main data.

The network keeps several values that are *derived* from `hard_prerequisite_ids`
and the node list.  Nothing in the engine recomputes them, so editing a node
without refreshing the copies leaves the UI showing a tree that disagrees with
the rules -- exactly what happened when the assembly-line and threshing
prerequisites were changed:

  * `visual_edges`                 projection of the graph, drawn by the tree view
  * `knowledge_basis.required_ids` mirror of the prerequisites
  * `prerequisite_rationales`      one reason per prerequisite, positionally paired

Checks (all must pass):

  D1  visual_edges == wave_d_presentation.build_visual_edges(network)
  D2a every knowledge_basis.required_ids entry is a hard-prerequisite ancestor
  D2b every direct hard prerequisite appears in knowledge_basis.required_ids
      except the nodes listed in REQUIRED_ID_EXCEPTIONS (exact set; a stale
      entry is an error too, so the list cannot quietly rot)
  D3a prerequisite_rationales has exactly one entry per hard prerequisite
  D3b rationale i names prerequisite i (display name or technology id)
  D4a every hard prerequisite exists as a node
  D4b hard prerequisites precede their node in topological order
  D4c hard prerequisites are not from a later era

Exit 0 when clean, 1 when anything is off, naming the node or edge at fault.
Runs in well under a second: parse plus graph arithmetic, no engine, no I/O beyond
the network file.

Usage: python check_derived.py [--network PATH] [--quiet]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from wave_d_presentation import build_visual_edges  # noqa: E402

DEFAULT_NETWORK = (HERE.parents[1] / "Project" / "project-keynes"
                   / "data" / "technology" / "technology_network.json")

# knowledge_basis.required_ids deliberately points at an older ancestor instead of
# a direct prerequisite for this one node: pastoralism describes pastoralism
# better than horse_domestication does, and both are hard ancestors.  Exact set:
# an entry that no longer exists fails like an undeclared one, so this cannot
# silently absorb a newly drifted node.
REQUIRED_ID_EXCEPTIONS = {
    "tech.pastoral_networks": (
        "knowledge basis names the older ancestor tech.pastoralism instead of the "
        "direct prerequisite tech.horse_domestication; both are hard ancestors"),
}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    argv = sys.argv[1:]
    quiet = "--quiet" in argv
    path = DEFAULT_NETWORK
    from_stdin = "--stdin" in argv
    if "--network" in argv:
        path = Path(argv[argv.index("--network") + 1])

    if from_stdin:
        # Read bytes and decode explicitly: sys.stdin uses the locale encoding on
        # Windows, which would corrupt the non-ASCII display names in the network.
        network = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    else:
        network = load(path)
    label = "<staged>" if from_stdin else path.name
    nodes = network["nodes"]
    by_id = {node["id"]: node for node in nodes}
    order = {node["id"]: index for index, node in enumerate(nodes)}
    era_index = {era["id"]: index for index, era in enumerate(network["eras"])}

    problems: list[str] = []

    def fail(check: str, detail: str) -> None:
        problems.append("%s %s" % (check, detail))

    # ---------------------------------------------------------------- D1
    stored = network.get("visual_edges", [])
    wanted = build_visual_edges(network)

    def edge_key(edge):
        return (edge["kind"], edge["from"], edge["to"], edge.get("route_id", ""))

    stored_keys = {edge_key(edge) for edge in stored}
    wanted_keys = {edge_key(edge) for edge in wanted}
    for kind, source, target, route in sorted(stored_keys - wanted_keys):
        fail("D1", "stale visual edge %s%s: %s -> %s (no longer in the graph)"
             % (kind, " [%s]" % route if route else "", source, target))
    for kind, source, target, route in sorted(wanted_keys - stored_keys):
        fail("D1", "missing visual edge %s%s: %s -> %s"
             % (kind, " [%s]" % route if route else "", source, target))

    # --------------------------------------------------------------- ancestry
    ancestor_cache: dict[str, set] = {}

    def ancestors(tech_id: str) -> set:
        cached = ancestor_cache.get(tech_id)
        if cached is not None:
            return cached
        result = {tech_id}
        for prerequisite in by_id.get(tech_id, {}).get("hard_prerequisite_ids", []):
            if prerequisite in by_id:
                result |= ancestors(prerequisite)
        ancestor_cache[tech_id] = result
        return result

    seen_exceptions = set()
    for node in nodes:
        node_id = node["id"]
        prerequisites = node.get("hard_prerequisite_ids", [])
        rationales = node.get("prerequisite_rationales", [])

        # ------------------------------------------------------------ D4
        known = [p for p in prerequisites if p in by_id]
        for prerequisite in prerequisites:
            if prerequisite not in by_id:
                fail("D4a", "%s requires %s which is not a node" % (node_id, prerequisite))
            elif order[prerequisite] > order[node_id]:
                fail("D4b", "%s requires %s but that node comes later in the order"
                     % (node_id, prerequisite))
            elif era_index[by_id[prerequisite]["era_id"]] > era_index[node["era_id"]]:
                fail("D4c", "%s (%s) requires %s (%s), a later era"
                     % (node_id, node["era_id"], prerequisite, by_id[prerequisite]["era_id"]))

        # ------------------------------------------------------------ D3
        if len(rationales) != len(prerequisites):
            fail("D3a", "%s has %d rationales for %d prerequisites"
                 % (node_id, len(rationales), len(prerequisites)))
        for index, (prerequisite, rationale) in enumerate(zip(prerequisites, rationales)):
            display_name = by_id.get(prerequisite, {}).get("display_name", "")
            if display_name and display_name not in rationale and prerequisite not in rationale:
                fail("D3b",
                     "%s rationale #%d does not name its prerequisite %s (display name %r)"
                     % (node_id, index, prerequisite, display_name))

        # ------------------------------------------------------------ D2
        basis = (node.get("knowledge_basis") or {}).get("required_ids")
        if basis is None:
            fail("D2a", "%s has no knowledge_basis.required_ids" % node_id)
            continue
        reachable = ancestors(node_id) - {node_id}
        for required in basis:
            if required not in reachable:
                fail("D2a", "%s declares required_id %s which is not a hard ancestor"
                     % (node_id, required))
        if node_id in REQUIRED_ID_EXCEPTIONS:
            seen_exceptions.add(node_id)
            continue
        for prerequisite in known:
            if prerequisite not in basis:
                fail("D2b",
                     "%s hard prerequisite %s is absent from knowledge_basis.required_ids"
                     % (node_id, prerequisite))

    for declared in REQUIRED_ID_EXCEPTIONS:
        if declared not in seen_exceptions:
            fail("D2b", "exception %s no longer describes a node with a missing required_id"
                 % declared)

    # --------------------------------------------------------------- report
    if problems:
        for problem in problems:
            print(problem)
        print("FAILED: %d derived-copy problem(s) in %s" % (len(problems), label))
        return 1
    if not quiet:
        print("OK: %d nodes, %d visual edges, derived copies agree with the graph (%s)"
              % (len(nodes), len(stored), label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
