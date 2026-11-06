#!/usr/bin/env python3
"""Lexical cross-domain include/type ratchet (not a C++ compiler).

Counts each include target and each foreign type token per source file. Reviewed
header-to-implementation and economy implementation moves require matching
source reductions; moving a reference never authorizes copying it.
Header exposure and total occurrences can only decrease.
Comments/strings are ignored; conditional branches are all checked. The host,
protocol and generic adapters are outside business-domain ownership.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
DOMAINS = ("country", "economy", "effect", "ideology", "modifier", "trigger", "military", "family", "climate")
INCLUDE = re.compile(r'^\s*#\s*include\s*["<]([^">]+)[">]', re.M)
TOKEN = re.compile(r"\b[A-Za-z_]\w*\b")
NON_CODE = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|R"([^ ()\\\t\r\n]{0,16})\([\s\S]*?\)\1"|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'')

COUNTRY_WRITE_CALLS = {
    "acknowledge_economy_asset_peer_prepared", "acknowledge_economy_asset_peer_applied",
    "commit_economy_asset_transaction", "begin_economy_research_purchase",
    "begin_economy_fiscal_reserve", "begin_economy_fiscal_collect",
    "begin_economy_cash_to_cohort", "begin_economy_cash_from_cohort",
    "begin_economy_good_to_market", "begin_economy_good_from_market",
    "begin_economy_treasury_spend", "reserve_fiscal_cash", "collect_fiscal_cash",
}


def domain_of(path: str) -> str | None:
    stem = Path(path).stem
    # Family leaves are currently embedded under the economy prefix. Their
    # explicit ownership exposes, rather than hides, that coupling.
    if re.search(r"(?:^|_)family(?:_|$)", stem):
        return "family"
    for domain in DOMAINS:
        if re.match(rf"(?:native_|runtime_)?{domain}(?:_|$)", stem):
            return domain
    return None


def code_only(source: str) -> str:
    return NON_CODE.sub(lambda match: "\n" * match.group().count("\n"), source)


def type_domain(token: str, declared: dict[str, str]) -> str | None:
    if token in declared:
        return declared[token]
    for domain in DOMAINS:
        # Covers forward references and generated declarations without needing
        # a compilation database. Uppercase boundary avoids Countrywide etc.
        if re.match(rf"(?:Native|Runtime)?{domain.title()}(?:[A-Z_]|$)", token):
            return domain
    return None


def measure(root: Path, include_contracts: bool = False) -> dict[str, int]:
    paths = sorted(p for p in (root / "gdext/src").rglob("*")
                   if p.suffix in {".cpp", ".h", ".inc"} and ".gen." not in p.name)
    sources = {p: p.read_text(encoding="utf-8") for p in paths}
    declarations: dict[str, set[str]] = {}
    for path, source in sources.items():
        owner = domain_of(path.name)
        if owner:
            for symbol in re.findall(r"\b(?:class|struct|enum\s+class)\s+(\w+)[^;{}]*\{", code_only(source)):
                declarations.setdefault(symbol, set()).add(type_domain(symbol, {}) or owner)
    # Unqualified nested names such as Command/Stage exist in many domains.
    # Without C++ name resolution they cannot safely imply a foreign owner.
    declared = {symbol: next(iter(owners)) for symbol, owners in declarations.items()
                if len(owners) == 1}
    edges: Counter[str] = Counter()
    for path, source in sources.items():
        owner = domain_of(path.name)
        if not owner:
            continue
        name = path.relative_to(root).as_posix()
        # The only direct calls left on this connection are writes and the
        # adapter factory. Unknown calls fail closed instead of silently adding
        # another getter outside the reviewed read contract.
        if path.name.startswith("economy_runtime") and path.suffix == ".cpp":
            for method in re.findall(r"\b_country_runtime\s*->\s*(\w+)\s*\(", code_only(source)):
                if method not in COUNTRY_WRITE_CALLS and method not in {"read_view", "fiscal_return_port", "procurement_port"}:
                    edges[f"{name}|economy->country|direct_read:{method}"] += 1
        # Keep source offsets so a fake #include inside a raw string/comment
        # cannot become an edge. The real directive survives code_only().
        code = NON_CODE.sub(lambda m: "".join("\n" if c == "\n" else " " for c in m.group()), source)
        for match in INCLUDE.finditer(source):
            if not code[match.start():match.end()].lstrip().startswith("#"):
                continue
            target = match.group(1)
            peer = domain_of(target)
            if not include_contracts and owner == "economy" and target == "country_read_view.h":
                continue  # Reviewed read contract; no mutable runtime surface.
            if peer and peer != owner:
                edges[f"{name}|{owner}->{peer}|include:{target}"] += 1
        tokens = re.sub(r'^\s*#\s*include\b[^\n]*', "", code, flags=re.M)
        for match in TOKEN.finditer(tokens):
            token = match.group()
            peer = type_domain(token, declared)
            read_type = token == "CountryReadView" or (
                token == "Snapshot" and re.search(r"CountryReadView\s*::\s*$", tokens[:match.start()]))
            if owner == "economy" and read_type:
                if not include_contracts:
                    continue  # Exact read contract; still included in total metrics.
                if token == "Snapshot":
                    token = "CountryReadView::Snapshot"
            if peer and peer != owner:
                edges[f"{name}|{owner}->{peer}|type:{token}"] += 1
    return dict(sorted(edges.items()))


def violations(current: dict[str, int], baseline: dict[str, int]) -> list[str]:
    return [f"{key}: {count} > {baseline.get(key, 0)}" for key, count in current.items()
            if count > baseline.get(key, 0)]


def metrics(references: dict[str, int], contracts: dict[str, int] | None = None) -> dict:
    references = dict(Counter(references) + Counter(contracts or {}))
    return {
        "header_exposed": sum(n for k, n in references.items() if k.split('|')[0].endswith('.h')),
        "total": sum(references.values()),
        "keys": len(references),
        "domain_pairs": sorted({k.split('|')[1] for k in references}),
    }


def relocation_source(key: str, origin: str) -> str:
    path, pair, symbol = key.split('|')
    source = Path(origin)
    target = Path(path)
    # A header may feed its own implementation or a named implementation leaf.
    header_move = source.suffix == '.h' and (
        target.stem == source.stem or target.stem.startswith(source.stem + '_'))
    economy_move = (source.suffix == '.cpp' and
                    source.name.startswith('economy_runtime') and
                    target.name.startswith('economy_runtime') and
                    source != target and pair.split('->')[0] == 'economy')
    internal_header_move = (source.name == 'economy_runtime.h' and
        target.name.startswith('economy_runtime_internal_') and target.suffix == '.h'
        and pair.split('->')[0] == 'economy')
    bridge_move = (source.name == 'economy_runtime.cpp' and
        target.name == 'economy_runtime_internal_external_types.inc' and
        target.suffix == '.inc' and pair.split('->')[0] == 'economy')
    if (source.parent != target.parent or
            not (internal_header_move or bridge_move or (target.suffix == '.cpp' and (header_move or economy_move)))):
        raise ValueError(f"invalid relocation: {origin} -> {path}")
    return f"{origin}|{pair}|{symbol}"


def updated_baseline(current: dict[str, int], baseline: dict, moves: dict[str, str],
                     contracts: dict[str, int] | None = None) -> dict:
    contracts = contracts or {}
    previous = baseline['references']
    allowances = dict(previous)
    history = dict(baseline.get('relocations', {}))
    consumed: Counter[str] = Counter()
    for key, move in moves.items():
        header = move.get('moved_from') if isinstance(move, dict) else move
        mode = move.get('mode', 'reduction') if isinstance(move, dict) else 'reduction'
        source = relocation_source(key, header)
        growth = current.get(key, 0) - previous.get(key, 0)
        decrease = previous.get(source, 0) - current.get(source, 0)
        if growth <= 0:
            raise ValueError(f"relocation has no target growth: {key}")
        if mode == 'duplicate':
            if growth > previous.get(source, 0) or source in consumed:
                raise ValueError(f"invalid duplicate relocation: {key}")
        elif growth > decrease - consumed[source]:
            raise ValueError(f"relocation has no matching source reduction: {key}")
        else:
            consumed[source] += growth
        allowances[key] = current[key]
        history[key] = {
            'moved_from': header, 'mode': mode, 'source_before': previous[source],
            'source_after': current.get(source, 0),
            'target_before': previous.get(key, 0), 'moved_count': growth,
        }
    errors = violations(current, allowances)
    old_metrics = metrics(previous, baseline.get('contract_references', {}))
    new_metrics = metrics(current, contracts)
    for field in ('header_exposed', 'total'):
        if new_metrics[field] > old_metrics[field]:
            errors.append(f"{field}: {new_metrics[field]} > {old_metrics[field]}")
    if not set(new_metrics['domain_pairs']) <= set(old_metrics['domain_pairs']):
        errors.append('new domain pair')
    if errors:
        raise ValueError('\n'.join(errors))
    result = {'version': 2, 'metrics': new_metrics, 'references': current, 'contract_references': contracts, 'relocations': history}
    errors = baseline_errors(result)
    if errors:
        raise ValueError('\n'.join(errors))
    return result


def baseline_errors(baseline: dict) -> list[str]:
    errors = []
    references = baseline['references']
    if baseline.get('version') == 2 and baseline.get('metrics') != metrics(references, baseline.get('contract_references', {})):
        errors.append('baseline metrics do not match references')
    for key, count in baseline.get('contract_references', {}).items():
        path, pair, symbol = key.split('|')
        if (pair != 'economy->country' or domain_of(path) != 'economy' or count <= 0 or
                symbol not in {'include:country_read_view.h', 'type:CountryReadView',
                               'type:CountryReadView::Snapshot'}):
            errors.append(f'unreviewed read contract: {key}')
    for key, move in baseline.get('relocations', {}).items():
        try:
            source = relocation_source(key, move['moved_from'])
            mode = move.get('mode', 'reduction')
            source_reduction_invalid = (mode != 'duplicate' and
                    move['source_before'] - move['source_after'] < move['moved_count'])
            if (mode not in {'reduction', 'duplicate'} or move['moved_count'] <= 0 or move['target_before'] < 0 or
                    move['source_after'] < 0 or source_reduction_invalid or
                    (mode == 'duplicate' and move['moved_count'] > move['source_before']) or
                    references.get(source, 0) > move['source_after'] or
                    references.get(key, 0) > move['target_before'] + move['moved_count']):
                errors.append(f'invalid relocation evidence: {key}')
        except (ValueError, KeyError):
            errors.append(f'invalid relocation evidence: {key}')
    return errors


def measure_country_writes(root: Path) -> dict[str, int]:
    counts: Counter[str] = Counter()
    for path in sorted((root / "gdext/src").glob("economy_runtime*.cpp")):
        for method in re.findall(r"\b_country_runtime\s*->\s*(\w+)\s*\(", code_only(path.read_text())):
            if method in COUNTRY_WRITE_CALLS:
                counts[f"{path.relative_to(root).as_posix()}|{method}"] += 1
    return dict(sorted(counts.items()))


def country_write_errors(root: Path, baseline: dict[str, int]) -> list[str]:
    errors = violations(measure_country_writes(root), baseline)
    migrated = set(COUNTRY_WRITE_CALLS)
    migrated.add("begin_economy_fiscal_return")
    for path in sorted((root / "gdext/src").glob("economy_runtime*.cpp")):
        code = code_only(path.read_text())
        for method in sorted(migrated):
            if re.search(r"\b" + method + r"\b", code):
                errors.append(f"{path.name}: {method} must use the owner intent port")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--baseline', type=Path, default=Path(__file__).with_name('cpp_deps_baseline.json'))
    parser.add_argument('--write-baseline', action='store_true', help='tighten an existing baseline after validation')
    parser.add_argument('--moves', type=Path, help='reviewed JSON mapping new keys to their original headers or economy implementation files')
    args = parser.parse_args()
    current = measure(args.root)
    all_references = measure(args.root, include_contracts=True)
    contracts = dict(Counter(all_references) - Counter(current))
    baseline = json.loads(args.baseline.read_text(encoding='utf-8'))
    errors = baseline_errors(baseline)
    errors += country_write_errors(args.root, baseline.get("country_writes", {}))
    exceptions = baseline.get("country_write_exceptions", {})
    for key in baseline.get("country_writes", {}):
        if not isinstance(exceptions.get(key), str) or not exceptions[key].strip():
            errors.append(f"direct write lacks an explicit exception reason: {key}")
    if args.write_baseline and not errors:
        try:
            moves = json.loads(args.moves.read_text()) if args.moves else {}
            baseline = updated_baseline(current, baseline, moves, contracts)
            baseline["country_writes"] = measure_country_writes(args.root)
            baseline["country_write_exceptions"] = {k: exceptions[k] for k in baseline["country_writes"]}
            args.baseline.write_text(json.dumps(baseline, indent=2) + '\n', encoding='utf-8')
        except ValueError as error:
            errors.append(str(error))
    else:
        errors += violations(current, baseline['references'])
        for field in ('header_exposed', 'total'):
            allowed = metrics(baseline['references'], baseline.get('contract_references', {}))[field]
            if metrics(current, contracts)[field] > allowed:
                errors.append(f'{field} exceeds baseline {allowed}')
        old_pairs = metrics(baseline['references'], baseline.get('contract_references', {}))['domain_pairs']
        if not set(metrics(current, contracts)['domain_pairs']) <= set(old_pairs):
            errors.append('new domain pair')
    measured = metrics(current, contracts)
    print(f"Country direct writes remaining: {sum(measure_country_writes(args.root).values())}")
    print(f"C++ dependencies: {measured['keys']} reference keys ({len(current)} debt keys), header_exposed={measured['header_exposed']}, total={measured['total']}, {len(errors)} violations")
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
