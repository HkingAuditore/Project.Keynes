#!/usr/bin/env python3
"""CLM2 v9 / ECP2 59 fixture: exact continuation bytes and full eight-day replay."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
from check_committed_replay import continuation_scan
from check_golden_determinism import records
from run_regression_checks import ROOT, SHUTDOWN_LEAK

FIXTURE = ROOT / "Project/project-keynes/tests/runtime/fixtures/climate_save_v9"


def climate_section(data):
    # PKSR v5 command envelope and fixed 256 producer cursors. Reject layout drift.
    assert data[:4] == b"PKSR" and struct.unpack_from("<I", data, 4)[0] == 5
    offset = 89
    count = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    for _ in range(count):
        size = struct.unpack_from("<I", data, offset + 48)[0]
        offset += 52 + size
    assert data[offset:offset + 4] == b"PCQ1"
    offset = data.find(b"DPD2", offset + 4)
    assert offset >= 0
    size = struct.unpack_from("<I", data, offset + 4)[0]
    offset += 16 + size
    assert data[offset:offset + 4] == b"CLM2"
    size = struct.unpack_from("<I", data, offset + 4)[0]
    result = data[offset + 8:offset + 8 + size]
    assert len(result) == size and result[:4] == b"CLM2"
    assert struct.unpack_from("<I", result, 4)[0] == 9
    return result


def publication_section(data, wanted=8):
    assert data[:4] == b"ECP2" and struct.unpack_from("<II", data, 4) == (3, 59)
    offset = 28 + struct.unpack_from("<I", data, 24)[0]
    owned = None
    while offset < len(data):
        domain, size = struct.unpack_from("<II", data, offset)
        offset += 8
        assert offset + size <= len(data)
        if domain == 131072:
            assert owned is None
            owned = data[offset:offset + size]
        offset += size
    assert offset == len(data) and owned is not None
    assert owned[:4] == b"OSOA" and struct.unpack_from("<I", owned, 4)[0] == 3
    offset, publication = 40, None
    while offset < len(owned):
        block, size = struct.unpack_from("<II", owned, offset)
        offset += 8
        assert offset + size <= len(owned)
        if block == wanted:
            assert publication is None
            publication = owned[offset:offset + size]
        offset += size
    assert offset == len(owned) and publication is not None
    return publication


def compatibility_section(data):
    # The enclosing PKSV reader has already checked section checksums.
    offset = 89
    count = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    for _ in range(count):
        offset += 52 + struct.unpack_from("<I", data, offset + 48)[0]
    assert data[offset:offset + 4] == b"PCQ1"
    offset = data.find(b"CPD2", offset + 4)
    assert offset >= 0
    payload = None
    while offset < len(data) - 8:
        marker = data[offset:offset + 4]
        size = struct.unpack_from("<I", data, offset + 4)[0]
        assert offset + 16 + size <= len(data) - 8
        if marker == b"CPD2":
            assert payload is None
            payload = data[offset + 8:offset + 8 + size]
        offset += 16 + size
    assert offset == len(data) - 8 and payload is not None
    assert payload[:4] == b"CPD2" and struct.unpack_from("<I", payload, 12)[0] == 1
    offset = 92 + struct.unpack_from("<I", payload, 80)[0]
    count = struct.unpack_from("<I", payload, offset)[0]
    offset += 4 + count * 28
    for _ in range(2):
        count = struct.unpack_from("<I", payload, offset)[0]
        offset += 4
        for _ in range(count):
            offset += 37
            size = struct.unpack_from("<I", payload, offset)[0]
            offset += 4 + size
    size = struct.unpack_from("<I", payload, offset)[0]
    offset += 4
    assert offset + size + 8 == len(payload)
    return payload[offset:offset + size]


def host_transport(data):
    assert data[:4] == b"PKSR" and struct.unpack_from("<I", data, 4)[0] == 5
    offset = 89
    count = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    for _ in range(count):
        offset += 52 + struct.unpack_from("<I", data, offset + 48)[0]
    assert data[offset:offset + 4] == b"PCQ1"
    offset += 4 + 257 * 8 + 24
    offset += 4 + struct.unpack_from("<I", data, offset)[0]  # Economy commands
    size = struct.unpack_from("<I", data, offset)[0]
    wire = data[offset + 4:offset + 4 + size]
    assert wire[:4] == b"TCQ1" and len(wire) == size
    return wire


def military_index(data):
    # MILB v3 wraps the module-owned PKMI payload without changing its layout.
    assert struct.unpack_from("<II", data)[0:2] == (0x4d494c42, 3)
    size = struct.unpack_from("<I", data, 8)[0]
    wire = data[12:12 + size]
    assert wire[:4] == b"PKMI" and struct.unpack_from("<I", wire, 4)[0] == 2
    offset = 44
    while offset < len(wire):
        section, length = struct.unpack_from("<HI", wire, offset)
        offset += 6
        if section == 22: return wire[offset:offset + length]
        offset += length
    raise AssertionError("PKMI index continuation missing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    args.log_dir.mkdir(parents=True, exist_ok=False)
    metadata = json.loads((FIXTURE / "manifest.json").read_text())
    archive = FIXTURE / "day2.pksv"
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == metadata["archive_sha256"]
    saves = args.log_dir.resolve() / "saves"
    payloads = []
    sections = []
    publications = []
    resources = []
    compatibility = []
    mobility = []
    cadence = []
    population = []
    transport = []
    military = []
    forwarder = []
    for mode, slot in (("checkpoint", "manual_3"), ("resume", "manual_2")):
        if mode == "resume":
            shutil.copyfile(archive, saves / "manual_3.pksv")
        environment = os.environ.copy()
        environment.update(PK_COMMITTED_REPLAY_MODE=mode, PK_COMMITTED_REPLAY_DAYS="10",
                           PK_COMMITTED_REPLAY_ROUNDTRIP="1", PK_COMMITTED_REPLAY_EXPORT="1",
                           PK_SAVE_DIR=str(saves))
        log = args.log_dir / (mode + ".log")
        command = [args.godot, "--headless", "--path", str(ROOT / "Project/project-keynes"),
                   "--script", "res://tests/runtime/committed_view_replay_test.gd"]
        with log.open("w") as stream:
            code = subprocess.run(command, env=environment, stdout=stream,
                                  stderr=subprocess.STDOUT).returncode
        lines = log.read_text(errors="replace").splitlines()
        errors = [line for line in lines if "SCRIPT ERROR:" in line or "[FAIL]" in line
                  or line.startswith("ERROR:") or SHUTDOWN_LEAK.search(line)]
        values = records(lines, "COMMITTED_REPLAY_RESULT=")
        if code or errors or len(values) != 1:
            print(f"FAIL {mode}: exit={code}; errors={errors}; log={log}", flush=True)
            return 1
        payloads.append(values[0])
        sections.append(climate_section((saves / (slot + "-sections/simulation_runtime.bin")).read_bytes()))
        publications.append(publication_section((saves / (slot + "-sections/ecp2.bin")).read_bytes()))
        resources.append(publication_section((saves / (slot + "-sections/ecp2.bin")).read_bytes(), 9))
        mobility.append(publication_section((saves / (slot + "-sections/ecp2.bin")).read_bytes(), 10))
        cadence.append(publication_section((saves / (slot + "-sections/ecp2.bin")).read_bytes(), 11))
        population.append(publication_section((saves / (slot + "-sections/ecp2.bin")).read_bytes(), 12))
        transport.append(host_transport((saves / (slot + "-sections/simulation_runtime.bin")).read_bytes()))
        forwarder_wire = (saves / (slot + "-sections/pkmi.bin")).read_bytes()[-28:]
        assert forwarder_wire[:4] == b"MDJ1"
        forwarder.append(forwarder_wire)
        military.append(military_index((saves / (slot + "-sections/pkmi.bin")).read_bytes()))
        compatibility.append(compatibility_section((saves / (slot + "-sections/simulation_runtime.bin")).read_bytes()))
    for name, values in (("resources", resources), ("compatibility", compatibility), ("mobility", mobility), ("population", population), ("transport", transport), ("military_index", military), ("military_forwarder", forwarder)):
        assert values[0] == values[1], f"{name} checkpoint bytes changed on roundtrip"
        assert len(values[0]) == metadata[name + "_bytes"]
        assert hashlib.sha256(values[0]).hexdigest() == metadata[name + "_sha256"]
    # Fresh process measurements may differ. The loaded fixture must preserve
    # its six measured cadence lanes exactly until the next completed epoch.
    assert len(cadence[1]) == metadata["cadence_bytes"]
    assert hashlib.sha256(cadence[1]).hexdigest() == metadata["cadence_sha256"]
    assert publications[0] == publications[1], "ECP2 publication roundtrip bytes changed"
    assert len(publications[0]) == metadata["publication_bytes"]
    assert hashlib.sha256(publications[0]).hexdigest() == metadata["publication_sha256"]
    assert sections[0] == sections[1], "CLM2 fixture roundtrip bytes changed"
    assert hashlib.sha256(sections[0]).hexdigest() == metadata["climate_sha256"]
    scan = continuation_scan(payloads[0], payloads[1])
    (args.log_dir / "all-domain-scan.json").write_text(json.dumps(scan, indent=2) + "\n")
    rows = scan["rows"]
    good = len(rows) == 8 and [row["day"] for row in rows] == list(range(3, 11))
    domain_names = {"CLIMATE", "COUNTRY", "ECONOMY", "EFFECT", "EVENTS", "IDEOLOGY", "MODIFIER", "TRIGGER_INPUT"}
    good = good and all(set(row["domains"]) == domain_names and
                        all(item["equal"] for item in row["domains"].values()) for row in rows)
    good = good and all(all(item["equal"] for item in row["other"].values()) for row in rows)
    actual = [row["domains"]["CLIMATE"]["actual"] for row in rows]
    good = good and actual == metadata["climate_days_3_to_10"]
    print(f"{'PASS' if good else 'FAIL'} CLM2 v9: fixture read, exact {len(sections[0])}-byte roundtrip; "
          f"eight domains + whole hash/military/resources days 3..10; publication/resource/compatibility/mobility/population/transport/military-index bytes stable", flush=True)
    return 0 if good else 1


if __name__ == "__main__":
    raise SystemExit(main())
