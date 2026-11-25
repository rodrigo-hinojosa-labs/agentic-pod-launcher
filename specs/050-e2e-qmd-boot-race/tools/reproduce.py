#!/usr/bin/env python3
"""Run the four isolated, induced 050 cases; never change the checkout.

Only the public three-option CLI runs Docker. The small functions and internal
``_hook`` command are also used by the scratch controls in T020. All evidence is
kept outside the checkout, including failed runs. No images or build caches are
removed. See ../contracts/evidence-protocol.md for the acceptance rules.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import uuid


BASELINE = "a45beaefaa68da17ce16d956351337bd5ce3b9d5"
TEST = "tests/docker-e2e-qmd.bats"
TITLE = "qmd e2e (037): a legacy vault-root collection migrates to wiki/-only on the first reindex tick"
SUPERVISOR = "docker/scripts/start_services.sh"
OVERLAY = (TEST, "tests/qmd-e2e-lock.bats", "tests/qmd-e2e-boot-race.bats",
           "tests/helper-qmd-e2e-boot-race.bash")
RUNTIME_ROOTS = ("docker", "modules", "scripts", "setup.sh", "VERSION", ".github")
ARCHIVE_PATHS = ".050-archive-runtime-paths.json"
SIGNAL_TIMEOUT = 90
CASE_TIMEOUT = 1800
CONTAINER = "qmd-migrate-e2e"


class EvidenceError(RuntimeError):
    """An inconclusive run, never the expected D1 reproduction."""


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args: list[str], *, cwd: Path | None = None,
            env: dict[str, str] | None = None, timeout: float = 30) -> str:
    try:
        result = subprocess.run(args, cwd=cwd, env=env, capture_output=True,
                                text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise EvidenceError(f"command unavailable or timed out: {args[0]}") from exc
    if result.returncode:
        # Commands here inspect public metadata, never credentials or environment.
        raise EvidenceError(f"command failed ({result.returncode}): {shlex.join(args)}\n"
                            + result.stderr[-2000:])
    return result.stdout


def claim_output_dir(path: Path, checkout: Path) -> Path:
    if not path.is_absolute():
        raise EvidenceError("--output-dir must be absolute")
    path, checkout = path.resolve(), checkout.resolve()
    if path == checkout or checkout in path.parents:
        raise EvidenceError("evidence must be outside the checkout")
    if path.exists() and (not path.is_dir() or any(path.iterdir())):
        raise EvidenceError("output directory must be new or empty")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    # Exclusive claim also rejects two coordinators targeting an empty directory.
    try:
        with (path / ".claimed").open("x") as handle:
            handle.write(str(os.getpid()) + "\n")
    except FileExistsError as exc:
        raise EvidenceError("evidence directory already claimed") from exc
    return path


def forbidden_path(name: str) -> bool:
    parts = PurePosixPath(name).parts
    return any(p in {".git", ".state", ".ssh", ".aws", ".env", "credentials",
                     "id_rsa", "id_ed25519"} or p.endswith((".pem", ".key"))
               for p in parts)


def archive_snapshot(root: Path, revision: str, destination: Path) -> None:
    """Archive tracked objects only; refuse secret/state paths before archiving."""
    names = command(["git", "ls-tree", "-rz", "--name-only", revision], cwd=root).split("\0")
    if any(forbidden_path(name) for name in names if name):
        raise EvidenceError("tracked archive contains a forbidden credential/state path")
    destination.mkdir()
    archive = destination.parent / (destination.name + ".tar")
    with archive.open("xb") as output:
        result = subprocess.run(["git", "archive", "--format=tar", revision], cwd=root,
                                stdout=output, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise EvidenceError("git archive failed")
    try:
        with tarfile.open(archive) as bundle:
            for member in bundle:
                name = PurePosixPath(member.name)
                if name.is_absolute() or ".." in name.parts or forbidden_path(member.name):
                    raise EvidenceError("unsafe archive member")
                target = destination.joinpath(*name.parts)
                if not target.resolve().is_relative_to(destination.resolve()):
                    raise EvidenceError("archive member escapes snapshot")
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    stream = bundle.extractfile(member)
                    if stream is None:
                        raise EvidenceError("unreadable archive member")
                    with stream, target.open("xb") as output:
                        shutil.copyfileobj(stream, output)
                    target.chmod(member.mode & 0o777)
                elif member.issym():
                    # Internal links are useful fixtures; special/hard links are not.
                    resolved = (target.parent / member.linkname).resolve()
                    if not resolved.is_relative_to(destination.resolve()):
                        raise EvidenceError("archive symlink escapes snapshot")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.symlink_to(member.linkname)
                else:
                    raise EvidenceError("unsupported archive member")
        write_json(destination / ARCHIVE_PATHS,
                   [name for name in names if name and PurePosixPath(name).parts[0] in RUNTIME_ROOTS])
    finally:
        archive.unlink(missing_ok=True)


def runtime_manifest(root: Path) -> dict[str, dict[str, object]]:
    """Hash only archive members or Git-tracked runtime files, never host caches."""
    if (root / ARCHIVE_PATHS).is_file():
        names = json.loads((root / ARCHIVE_PATHS).read_text())
    elif (root / ".git").exists():
        names = command(["git", "ls-files", "-z", "--", *RUNTIME_ROOTS], cwd=root).split("\0")
    else:
        raise EvidenceError("runtime root needs a Git index or archive member manifest")
    manifest = {}
    for name in sorted(filter(None, names)):
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts \
                or relative.parts[0] not in RUNTIME_ROOTS or forbidden_path(name):
            raise EvidenceError("invalid tracked runtime path")
        file = root / name
        if file.is_symlink():
            manifest[name] = {"link": os.readlink(file)}
        elif file.is_file():
            manifest[name] = {"sha256": digest(file), "executable": bool(file.stat().st_mode & 0o111)}
        else:
            raise EvidenceError("tracked runtime file is absent: " + name)
    if SUPERVISOR not in manifest:
        raise EvidenceError("supervisor missing from runtime snapshot")
    return manifest


def assert_runtime_equal(base: Path, candidate: Path) -> dict[str, dict[str, object]]:
    left, right = runtime_manifest(base), runtime_manifest(candidate)
    if left != right:
        changed = sorted(k for k in left.keys() | right.keys() if left.get(k) != right.get(k))
        raise EvidenceError("runtime differs from baseline: " + ", ".join(changed))
    return left


def replace_once(text: str, anchor: str, replacement: str) -> str:
    count = text.count(anchor)
    if count != 1:
        raise EvidenceError(f"anchor must be unique (found {count}): {anchor[:100]!r}")
    return text.replace(anchor, replacement, 1)


def legacy_body(text: str) -> tuple[str, str, str]:
    opening = '@test "' + TITLE + '" {\n'
    if text.count(opening) != 1:
        raise EvidenceError("legacy test title absent or ambiguous")
    before, rest = text.split(opening, 1)
    # This is a Bats test boundary, not any brace in a fixture heredoc.
    match = re.search(r"\n}\n(?=\n# 037 T037 \(Phase 4\.5 extension\))", rest)
    if match is None:
        raise EvidenceError("legacy test end absent or ambiguous")
    return before + opening, rest[:match.start()], rest[match.start():]


def baseline_markers(text: str) -> str:
    """Reconstruct the pre-fix, comment-only 050 anchors from unique originals."""
    prefix, body, suffix = legacy_body(text)
    if "# 050:" in body:
        raise EvidenceError("baseline already contains 050 anchors")
    original = body
    insertions = (
        ('  local D2=', '  # 050:fixture:begin\n  local D2='),
        ('  (cd "$D2" && docker compose build)', '  # 050:fixture:end\n  (cd "$D2" && docker compose build)'),
        ('  # boot must NOT have run collection setup', '  # 050:precondition:begin\n  # boot must NOT have run collection setup'),
        ('  [[ "$output" == *"SKIPPED"* ]]', '  [[ "$output" == *"SKIPPED"* ]]\n  # 050:precondition:end\n\n  # 050:observe:begin'),
        ('    rc1=0\n', '    # 050:tick1:begin\n    rc1=0\n'),
        ('    calls=$(in_container', '    # 050:tick1:end\n    calls=$(in_container'),
        ('  # order: remove -> add', '  # 050:observe:end\n  # 050:verify:begin\n  # order: remove -> add'),
        ('  [ "$output" = "$calls_before" ]', '  [ "$output" = "$calls_before" ]\n  # 050:verify:end'),
    )
    for anchor, replacement in insertions:
        body = replace_once(body, anchor, replacement)
    # Whitespace and comments can change; every original executable line stays.
    def executable_lines(value: str) -> list[str]:
        return [line for line in value.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    if executable_lines(body) != executable_lines(original):
        raise EvidenceError("baseline marker overlay changed executable lines")
    return prefix + body + suffix


def instrument_test(text: str, python: Path, coordinator: Path) -> str:
    prefix, body, suffix = legacy_body(text)
    for region in ("fixture", "precondition", "tick1", "observe", "verify"):
        for end in ("begin", "end"):
            if body.count(f"# 050:{region}:{end}") != 1:
                raise EvidenceError(f"missing/ambiguous 050 marker: {region}:{end}")
    hook = shlex.join([str(python), str(coordinator), "_hook"])
    def call(phase: str) -> str:
        return f'  {hook} {phase} "$D2"\n'
    # Common isolation only: never seed the setup marker in the baseline.
    old = 'schedule: "*/5 * * * *"'
    new = 'schedule: "0 0 31 2 *"'
    if old in body:
        body = replace_once(body, old, new)
    elif body.count(new) != 1:
        raise EvidenceError("common cron isolation anchor absent or ambiguous")
    fixture_end = "  # 050:fixture:end\n"
    body = replace_once(body, fixture_end, fixture_end + call("prepare"))
    build = '  (cd "$D2" && docker compose build)\n'
    redirected_build = '  (cd "$D2" && docker compose build) > "$BOOT_RACE_CASE_DIR/build.log" 2>&1\n'
    body = replace_once(body, build, redirected_build + call("after-build"))
    marker = "  # 050:precondition:begin\n"
    body = replace_once(body, marker, marker + call("before-inspect"))
    marker = "  # 050:precondition:end\n"
    body = replace_once(body, marker, marker + call("after-inspect"))
    # Capture the real inspection output without replacing any original assertion.
    start = body.index("  # 050:precondition:begin\n")
    end = body.index("  # 050:precondition:end\n")
    section = body[start:end]
    assertion = ('  [[ "$output" == *"SKIPPED"* ]]' if '"SKIPPED"' in section
                 else '  [ "$status" -eq 0 ]')
    section = replace_once(section, assertion,
                           f'  {hook} inspection-result "$D2" "$status" "$output"\n' + assertion)
    body = body[:start] + section + body[end:]
    marker = "    # 050:tick1:begin\n"
    body = replace_once(body, marker, marker + call("tick1"))
    # Preserve all fixtures for review. The isolated teardown validates labels and
    # tears down only this case's explicit Compose project, even on a failing test.
    text = prefix + body + suffix
    pattern = r"\nteardown\(\) \{\n.*?\n}\n(?=\n@test)"
    matches = list(re.finditer(pattern, text, flags=re.S))
    if len(matches) != 1:
        raise EvidenceError("teardown anchor absent or ambiguous")
    cleanup = (f'\nteardown() {{\n  {hook} cleanup '
               '"$TMP_TEST_DIR/agent-qmd-migrate-e2e"\n}\n')
    match = matches[0]
    text = text[:match.start()] + cleanup + text[match.end():]
    text = replace_once(text, "  TMPDIR=/tmp setup_tmp_dir\n",
                        '  TMP_TEST_DIR="$BOOT_RACE_CASE_DIR/workspace"\n'
                        '  mkdir -p "$TMP_TEST_DIR"\n  export TMP_TEST_DIR\n')
    return text


def event(case_dir: Path, name: str, **details: object) -> None:
    with (case_dir / "events.jsonl").open("a") as handle:
        # On macOS/Python 3.9 monotonic origins differ between processes. The
        # PID scopes that diagnostic clock; UTC makes cross-process events legible.
        handle.write(json.dumps({"event": name, "monotonic": time.monotonic(),
                                 "utc": datetime.now(timezone.utc).isoformat(),
                                 "pid": os.getpid(), **details}) + "\n")


def wait_signal(path: Path, timeout: float = SIGNAL_TIMEOUT) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.is_file():
            return path.read_text().strip()
        error = path.parent / "error"
        if error.is_file():
            raise EvidenceError("wrapper failed: " + error.read_text().strip())
        time.sleep(0.1)
    raise EvidenceError(f"signal expired after {timeout:g}s: {path.name}")


def docker(env: dict[str, str], *args: str) -> str:
    return command([env.get("BOOT_RACE_DOCKER", "docker"), *args], env=env)


def preflight_container(env: dict[str, str]) -> None:
    occupied = docker(env, "ps", "-aq", "--filter", f"name=^/{CONTAINER}$").strip()
    if occupied:
        raise EvidenceError(f"container name occupied: {CONTAINER}; left untouched")


def resource_inventory(project: str, env: dict[str, str]) -> list[dict[str, object]]:
    resources = []
    for kind, listing in (("container", ["ps", "-aq"]),
                          ("network", ["network", "ls", "-q"]),
                          ("volume", ["volume", "ls", "-q"])):
        ids = docker(env, *listing, "--filter", f"label=com.docker.compose.project={project}").split()
        for resource in ids:
            labels = ".Config.Labels" if kind == "container" else ".Labels"
            identifier = ".Name" if kind == "volume" else ".Id"
            fmt = ('{"id":{{json ' + identifier + '}},"name":{{json .Name}},"labels":{{json '
                   + labels + '}}}')
            data = json.loads(docker(env, kind, "inspect", "--format", fmt, resource))
            data["kind"] = kind
            resources.append(data)
    return resources


def validate_resource_identity(resources: list[dict[str, object]], project: str) -> None:
    for resource in resources:
        labels = resource.get("labels")
        if not isinstance(labels, dict) or labels.get("com.docker.compose.project") != project:
            raise EvidenceError("foreign or missing Compose label; cleanup refused")
        if not resource.get("id") or not resource.get("name"):
            raise EvidenceError("resource identity incomplete; cleanup refused")
        if resource.get("kind") == "container" and resource["name"] != "/" + CONTAINER:
            raise EvidenceError("unexpected container identity; cleanup refused")


def cleanup_project(case_dir: Path, env: dict[str, str]) -> None:
    config = json.loads((case_dir / "case.json").read_text())
    workspace = case_dir / "workspace" / "agent-qmd-migrate-e2e"
    control = workspace / ".e2e/050/control"
    if (control / "entered").exists() and not (control / "release").exists():
        (control / "release").write_text("cleanup\n")
    project = config["project"]
    resources = resource_inventory(project, env)
    validate_resource_identity(resources, project)
    event(case_dir, "cleanup-inventory", resources=resources)
    if resources:
        if not (workspace / "docker-compose.yml").is_file():
            raise EvidenceError("resources exist but fixture compose is absent; cleanup refused")
        with (case_dir / "cleanup.log").open("a") as output:
            process = subprocess.Popen([env.get("BOOT_RACE_DOCKER", "docker"), "compose", "-p", project,
                                        "down", "-v", "--remove-orphans"], cwd=workspace, env=env,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                returncode = process.wait(timeout=90)
            except subprocess.TimeoutExpired as exc:
                raise EvidenceError("own project cleanup expired") from exc
            finally:
                stop_process_group(process)
        if returncode:
            raise EvidenceError("own project cleanup failed")
    remaining = resource_inventory(project, env)
    write_json(case_dir / "cleanup.json", {"project": project, "before": resources, "remaining": remaining})
    if remaining:
        raise EvidenceError("own project cleanup incomplete")
    event(case_dir, "cleanup-complete")


def verify_setup(case_dir: Path, workspace: Path, source: str) -> None:
    control = workspace / ".e2e/050/control"
    rc = wait_signal(control / "returned")
    if rc != "0":
        raise EvidenceError(f"setup returned an invalid/nonzero result: {rc!r}")
    log = (control / "setup.log").read_text()
    expected = "setup: complete" if source == "base" else "setup: already done"
    if not re.search(r"\[qmd\] " + re.escape(expected) + r"(?:\s|$)", log):
        raise EvidenceError(f"setup outcome missing: {expected}")
    if not (workspace / ".state/.cache/qmd/.qmd-setup-ok").is_file():
        raise EvidenceError("setup returned without its real completed marker")
    if source == "candidate":
        engine = workspace / ".state/.cache/qmd/engine-calls.log"
        if engine.exists() and re.search(r"^collection (remove|add)(?:\s|$)", engine.read_text(), re.M):
            raise EvidenceError("candidate boot already replaced the collection")
        if (workspace / ".state/.cache/qmd/.qmd-collection-wiki").exists():
            raise EvidenceError("candidate boot already migrated")
    event(case_dir, "setup-returned", source=source, rc=0, outcome=expected)


def verify_boot(case_dir: Path, workspace: Path, config: dict[str, str], env: dict[str, str]) -> None:
    control = workspace / ".e2e/050/control"
    identity = dict(line.split("=", 1) for line in wait_signal(control / "identity").splitlines())
    if identity.get("mode") != "container" or identity.get("user") != "agent" \
            or not identity.get("uid", "").isdigit() or int(identity["uid"]) == 0:
        raise EvidenceError("wrapper did not run as the real agent")
    expected_sha = config["supervisor_sha256"]
    if wait_signal(control / "original.sha256") != expected_sha:
        raise EvidenceError("wrapper original supervisor hash differs")
    if not wait_signal(control / "boot-called").isdigit():
        raise EvidenceError("original main invocation missing")
    resources = resource_inventory(config["project"], env)
    validate_resource_identity(resources, config["project"])
    containers = [r for r in resources if r["kind"] == "container"]
    if len(containers) != 1:
        raise EvidenceError("expected exactly one own container")
    write_json(case_dir / "resources.json", resources)
    container_id = str(containers[0]["id"])
    runtime_identity = docker(env, "exec", "-u", "agent", container_id,
                              "sh", "-c", "id -un; id -u; uname -m").splitlines()
    if len(runtime_identity) != 3 or runtime_identity[0] != "agent" or runtime_identity[1] == "0":
        raise EvidenceError("container smoke failed agent identity")
    deadline = time.monotonic() + SIGNAL_TIMEOUT
    while time.monotonic() < deadline:
        # docker logs uses stderr for the supervisor's stderr; collect both once.
        result = subprocess.run([env.get("BOOT_RACE_DOCKER", "docker"), "logs", container_id], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        logs = result.stdout
        (case_dir / "boot.log").write_text(logs)
        if result.returncode == 0 and "[start_services] starting tmux session" in logs:
            event(case_dir, "boot-verified", identity=identity, runtime_identity=runtime_identity)
            return
        time.sleep(0.1)
    raise EvidenceError("original boot log signal expired")


def prepare_fixture(case_dir: Path, workspace: Path, config: dict[str, str]) -> None:
    instrumentation = workspace / ".e2e/050"
    instrumentation.mkdir(parents=True)
    (instrumentation / "control").mkdir()
    original = Path(config["snapshot"]) / SUPERVISOR
    if digest(original) != config["supervisor_sha256"]:
        raise EvidenceError("supervisor snapshot changed")
    shutil.copyfile(original, instrumentation / "start_services.original.sh")
    shutil.copyfile(Path(config["wrapper"]), instrumentation / "start-services-gate.sh")
    (instrumentation / "start-services-gate.sh").chmod(0o755)
    # One stable page, seeded before up, outside all gates/logs.
    page = workspace / ".state/.vault/wiki/concepts/migration.md"
    page.parent.mkdir(parents=True, exist_ok=True)
    page.write_text("# Legacy migration fixture\n\nA stable wiki page before boot.\n")
    compose = workspace / "docker-compose.yml"
    text = compose.read_text()
    mount = '      - ./:/workspace\n'
    text = replace_once(text, mount, mount +
                        '      - ./.e2e/050/start-services-gate.sh:/opt/agent-admin/scripts/start_services.sh:ro\n')
    environment = '    environment:\n'
    text = replace_once(text, environment, environment +
                        f'      BOOT_RACE_ORDER: "{config["order"]}"\n'
                        '      BOOT_RACE_CONTROL_DIR: "/workspace/.e2e/050/control"\n'
                        f'      BOOT_RACE_ORIGINAL_SHA256: "{config["supervisor_sha256"]}"\n')
    compose.write_text(text)
    event(case_dir, "prepared", workspace=str(workspace))


def run_hook(phase: str, workspace: Path, extra: list[str], env: dict[str, str]) -> None:
    case_dir = Path(env["BOOT_RACE_CASE_DIR"])
    config = json.loads((case_dir / "case.json").read_text())
    if env.get("COMPOSE_PROJECT_NAME") != config["project"]:
        raise EvidenceError("Compose project identity was not propagated")
    control = workspace / ".e2e/050/control"
    if phase == "prepare":
        prepare_fixture(case_dir, workspace, config)
    elif phase == "after-build":
        preflight_container(env)
        event(case_dir, "after-build")
        temporary = case_dir / ".post-build-start.tmp"
        temporary.write_text(str(time.monotonic()))
        temporary.replace(case_dir / "post-build-start")
    elif phase == "before-inspect":
        if not wait_signal(control / "entered").isdigit():
            raise EvidenceError("setup entered signal does not contain its PID")
        if config["order"] == "early":
            verify_setup(case_dir, workspace, config["source"])
        elif (control / "returned").exists() or (control / "release").exists():
            raise EvidenceError("late setup returned or was released before inspection")
        verify_boot(case_dir, workspace, config, env)
        event(case_dir, "before-inspect")
    elif phase == "inspection-result":
        if len(extra) != 2 or not extra[0].isdigit():
            raise EvidenceError("inspection result malformed")
        write_json(case_dir / "inspection.json", {"status": int(extra[0]), "output": extra[1]})
        event(case_dir, "inspection-result")
    elif phase == "after-inspect":
        event(case_dir, "inspection-passed")
        if config["order"] == "late":
            if (control / "returned").exists() or (control / "release").exists():
                raise EvidenceError("late setup returned/released before its original inspection passed")
            with (control / "release").open("x") as release:
                release.write("inspection-passed\n")
            event(case_dir, "release")
            verify_setup(case_dir, workspace, config["source"])
    elif phase == "tick1":
        # Re-check returned here too: a release alone must never allow a tick.
        if not (control / "returned").is_file() or (control / "returned").read_text().strip() != "0":
            raise EvidenceError("tick 1 attempted without successful real setup return")
        event(case_dir, "tick1")
    elif phase == "cleanup":
        cleanup_project(case_dir, env)
    else:
        raise EvidenceError("unknown coordinator hook")


def classify_case(case_dir: Path, returncode: int) -> dict[str, object]:
    config = json.loads((case_dir / "case.json").read_text())
    tap = (case_dir / "tap.log").read_text()
    events = [json.loads(line)["event"] for line in (case_dir / "events.jsonl").read_text().splitlines()]
    if (case_dir / "error").exists():
        raise EvidenceError((case_dir / "error").read_text().strip())
    plans = re.findall(r"^1\.\..*$", tap, re.M)
    results = re.findall(r"^(?:not )?ok [0-9]+(?: .*)?$", tap, re.M)
    if "Bail out!" in tap or re.search(r"#\s*skip\b", tap, re.I) \
            or plans != ["1..1"] or len(results) != 1:
        raise EvidenceError("Bats did not execute exactly one unskipped test")
    inspection = json.loads((case_dir / "inspection.json").read_text())
    expected = ("RAN" if config["order"] == "early" else "SKIPPED") if config["source"] == "base" else "LEGACY_PENDING"
    if inspection != {"status": 0, "output": expected}:
        raise EvidenceError("initial inspection failed for a different cause")
    for required in ("boot-verified", "before-inspect", "inspection-result", "setup-returned", "cleanup-complete"):
        if required not in events:
            raise EvidenceError("missing evidence event: " + required)
    if not (case_dir / "cleanup.json").is_file() or json.loads((case_dir / "cleanup.json").read_text())["remaining"]:
        raise EvidenceError("cleanup evidence missing or incomplete")
    d1 = config["source"] == "base" and config["order"] == "early"
    if d1:
        if returncode != 1 or not re.search(r"^not ok 1 " + re.escape(TITLE) + r"$", tap, re.M):
            raise EvidenceError("D1 did not fail as expected")
        assertion = '[[ "$output" == *"SKIPPED"* ]]'
        line = config["original_assertion_line"]
        if assertion not in tap or not re.search(r"\bline " + str(line) + r"\)", tap):
            raise EvidenceError("D1 red was not the original SKIPPED assertion")
        if "tick1" in events or "inspection-passed" in events:
            raise EvidenceError("D1 continued past the original assertion")
        if events.index("setup-returned") > events.index("before-inspect"):
            raise EvidenceError("early return order was not observed")
    else:
        if returncode != 0 or not re.search(r"^ok 1 " + re.escape(TITLE) + r"$", tap, re.M) or "tick1" not in events:
            raise EvidenceError("expected green case failed or did not reach tick 1")
        if config["order"] == "late":
            order = [events.index(name) for name in ("before-inspect", "inspection-result", "inspection-passed", "release", "setup-returned", "tick1")]
            if order != sorted(order) or len(set(order)) != len(order):
                raise EvidenceError("late returned was not observed between release and tick 1")
        elif events.index("setup-returned") > events.index("before-inspect"):
            raise EvidenceError("early return order was not observed")
    return {"accepted": True, "expected": "red-original-SKIPPED" if d1 else "green", "returncode": returncode}


def clean_environment(home: Path, endpoint: str, bash: str) -> dict[str, str]:
    home.mkdir(mode=0o700)
    docker_config = home / "docker"
    docker_config.mkdir(mode=0o700)
    tmp = home / "tmp"
    tmp.mkdir()
    return {"PATH": str(Path(bash).parent) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(home), "DOCKER_CONFIG": str(docker_config), "DOCKER_HOST": endpoint,
            "LC_ALL": "C", "LANG": "C", "TZ": "UTC", "TMPDIR": str(tmp),
            "DOCKER_E2E": "1", "AGENTIC_VERSIONS_OFFLINE": "1"}


def docker_endpoint() -> str:
    context = command(["docker", "context", "show"]).strip()
    endpoint = command(["docker", "context", "inspect", context,
                        "--format", "{{.Endpoints.docker.Host}}"]).strip()
    if not endpoint.startswith("unix:///") or any(c in endpoint for c in "\r\n"):
        raise EvidenceError("reproduction requires a local Unix Docker endpoint from the CLI context")
    return endpoint


def stop_process_group(process: subprocess.Popen[bytes]) -> None:
    # The leader may already have exited while a grandchild remains. Its private
    # process group is still ours; regular output files must not hide that leak.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def observe_case_deadline(deadline: float | None, marker_exists: bool,
                          parent_now: float) -> float | None:
    """Start the budget on the parent's first observation, never a child clock."""
    if deadline is None and marker_exists:
        return parent_now + CASE_TIMEOUT
    return deadline


def check_case_budget(case_dir: Path, deadline: float | None) -> float | None:
    parent_now = time.monotonic()
    observed = observe_case_deadline(deadline, (case_dir / "post-build-start").exists(), parent_now)
    if deadline is None and observed is not None:
        event(case_dir, "budget-started", budget_seconds=CASE_TIMEOUT, parent_deadline=observed)
    if observed is not None and parent_now > observed:
        raise EvidenceError(f"case exceeded {CASE_TIMEOUT}s after build")
    return observed


def copy_frozen_source(source: Path, destination: Path, frozen_bytes: bytes,
                       source_kind: str = "coordinator") -> None:
    """Reject edits during the matrix and copy the initially recorded bytes."""
    if source.read_bytes() != frozen_bytes:
        raise EvidenceError(source_kind + " source changed during matrix; mixed tool inputs refused")
    destination.write_bytes(frozen_bytes)


def run_case(case_dir: Path, config: dict[str, str], env: dict[str, str], bats: str) -> dict[str, object]:
    write_json(case_dir / "case.json", config)
    env = {**env, "COMPOSE_PROJECT_NAME": config["project"], "BOOT_RACE_CASE_DIR": str(case_dir)}
    preflight_container(env)
    process = None
    deadline = None
    try:
        with (case_dir / "tap.log").open("wb") as tap, (case_dir / "stderr.log").open("wb") as stderr:
            process = subprocess.Popen([bats, "--tap", "--print-output-on-failure", TEST,
                                        "-f", "^" + re.escape(TITLE) + "$"], cwd=config["snapshot"],
                                       env=env, stdout=tap, stderr=stderr, start_new_session=True)
            while process.poll() is None:
                deadline = check_case_budget(case_dir, deadline)
                time.sleep(0.2)
            check_case_budget(case_dir, deadline)
        rc = process.returncode
    finally:
        if process is not None:
            stop_process_group(process)
        cleanup_project(case_dir, env)
    return classify_case(case_dir, rc)


def main() -> int:
    coordinator_source = Path(__file__).resolve()
    coordinator_bytes = coordinator_source.read_bytes()
    coordinator_sha256 = hashlib.sha256(coordinator_bytes).hexdigest()
    if len(sys.argv) > 1 and sys.argv[1] == "_hook":
        try:
            run_hook(sys.argv[2], Path(sys.argv[3]), sys.argv[4:], dict(os.environ))
            return 0
        except (EvidenceError, OSError, ValueError, KeyError) as exc:
            case_dir = Path(os.environ["BOOT_RACE_CASE_DIR"])
            with (case_dir / "error").open("a") as error:
                error.write(str(exc) + "\n")
            print(f"050 harness: {exc}", file=sys.stderr)
            return 2
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="baseline commit object (never checked out)")
    parser.add_argument("--candidate-root", type=Path, required=True, help="absolute repository checkout")
    parser.add_argument("--output-dir", type=Path, required=True, help="new/empty evidence directory outside checkout")
    args = parser.parse_args()
    output = None
    try:
        if not args.candidate_root.is_absolute():
            raise EvidenceError("--candidate-root must be absolute")
        root = args.candidate_root.resolve()
        top = Path(command(["git", "rev-parse", "--show-toplevel"], cwd=root).strip()).resolve()
        if root != top:
            raise EvidenceError("candidate must be the repository root")
        output = claim_output_dir(args.output_dir, root)
        revision = command(["git", "rev-parse", "--verify", args.baseline + "^{commit}"], cwd=root).strip()
        if revision != BASELINE:
            raise EvidenceError("baseline must be the verified pre-050 commit " + BASELINE)
        head = command(["git", "rev-parse", "HEAD"], cwd=root).strip()
        base, candidate = output / "base", output / "candidate"
        archive_snapshot(root, revision, base)
        archive_snapshot(root, head, candidate)
        runtime = assert_runtime_equal(base, candidate)
        # Compare tracked working-tree runtime and reject nonignored new runtime
        # paths. Do not recursively scan ignored host caches/vendor directories.
        runtime_paths = command(["git", "ls-files", "-z", "--", *RUNTIME_ROOTS], cwd=root).split("\0")
        for name in filter(None, runtime_paths):
            actual, recorded = root / name, base / name
            if actual.is_symlink() or recorded.is_symlink():
                same = actual.is_symlink() and recorded.is_symlink() and os.readlink(actual) == os.readlink(recorded)
            else:
                same = actual.is_file() and recorded.is_file() and digest(actual) == digest(recorded) \
                    and bool(actual.stat().st_mode & 0o111) == bool(recorded.stat().st_mode & 0o111)
            if not same:
                raise EvidenceError("working-tree runtime differs: " + name)
        if command(["git", "ls-files", "--others", "--exclude-standard", "--", *RUNTIME_ROOTS], cwd=root).strip():
            raise EvidenceError("untracked runtime files are outside the test-only overlay")
        hashes = {}
        for name in OVERLAY:
            source = root / name
            if not source.is_file() or source.is_symlink():
                raise EvidenceError("authorized overlay missing or symlinked: " + name)
            hashes[name] = digest(source)
            shutil.copyfile(source, candidate / name)
        original_baseline = (base / TEST).read_text()
        (base / TEST).write_text(baseline_markers(original_baseline))
        wrapper = Path(__file__).with_name("start-services-gate.sh")
        if not wrapper.is_file() or wrapper.is_symlink():
            raise EvidenceError("wrapper missing")
        wrapper_bytes = wrapper.read_bytes()
        bash, bats = shutil.which("bash"), shutil.which("bats")
        if not bash or not bats:
            raise EvidenceError("bash and bats must be installed")
        bash_version = command([bash, "--version"]).splitlines()[0]
        if not re.search(r"version 5\.", bash_version):
            raise EvidenceError("matrix requires bash 5.x (original assertion must be active)")
        endpoint = docker_endpoint()
        environment = clean_environment(output / "home", endpoint, bash)
        # Some Desktop installs discover compose only via the original HOME's
        # plugin directory. Ask the CLI for that public path, never copy config.
        plugins = json.loads(command(["docker", "info", "--format", "{{json .ClientInfo.Plugins}}"], timeout=30))
        compose_dirs = sorted({str(Path(p["Path"]).parent) for p in plugins or []
                               if p.get("Name") == "compose" and p.get("Path")})
        if compose_dirs:
            write_json(Path(environment["DOCKER_CONFIG"]) / "config.json", {"cliPluginsExtraDirs": compose_dirs})
        versions = {"bash": bash_version, "bats": command([bats, "--version"], env=environment).strip(),
                    "docker": docker(environment, "version", "--format", "{{.Server.Version}}" ).strip(),
                    "compose": docker(environment, "compose", "version").strip(),
                    "architecture": docker(environment, "info", "--format", "{{.Architecture}}" ).strip()}
        write_json(output / "inputs.json", {"baseline": revision, "candidate_head": head, "tests": hashes,
                                           "supervisor_sha256": digest(base / SUPERVISOR), "runtime": runtime,
                                           "wrapper_sha256": hashlib.sha256(wrapper_bytes).hexdigest(), "coordinator_sha256": coordinator_sha256,
                                           "versions": versions, "docker_endpoint": endpoint})
        results = []
        for row, source, order in (("D1", "base", "early"), ("D2", "base", "late"),
                                   ("D3", "candidate", "early"), ("D4", "candidate", "late")):
            case_dir = output / row
            case_dir.mkdir()
            snapshot = case_dir / "snapshot"
            shutil.copytree(base if source == "base" else candidate, snapshot, symlinks=True)
            tool_dir = snapshot / ".e2e-050-tools"
            tool_dir.mkdir()
            coordinator = tool_dir / "reproduce.py"
            copy_frozen_source(coordinator_source, coordinator, coordinator_bytes)
            copy_frozen_source(wrapper, tool_dir / wrapper.name, wrapper_bytes, "wrapper")
            text = instrument_test((snapshot / TEST).read_text(), Path(sys.executable), coordinator)
            (snapshot / TEST).write_text(text)
            assertion = '  [[ "$output" == *"SKIPPED"* ]]'
            config = {"row": row, "source": source, "order": order, "snapshot": str(snapshot),
                      "wrapper": str(tool_dir / wrapper.name), "project": "qmd050-" + uuid.uuid4().hex[:16],
                      "supervisor_sha256": digest(snapshot / SUPERVISOR),
                      "test_sha256": digest(snapshot / TEST),
                      "original_assertion_line": next((i for i, line in enumerate(text.splitlines(), 1) if line == assertion), 0)}
            print(f"{row}: {source} {order}; project={config['project']}", flush=True)
            try:
                result = run_case(case_dir, config, environment, bats)
            except (EvidenceError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
                result = {"accepted": False, "classification": "harness-or-infrastructure", "error": str(exc)}
            results.append({"row": row, **result})
            write_json(case_dir / "result.json", results[-1])
            write_json(output / "summary.json", results)
            if not result["accepted"]:
                raise EvidenceError(f"{row} inconclusive: {result['error']}")
        print("D1-D4 accepted; evidence: " + str(output))
        return 0
    except (EvidenceError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
        if output:
            (output / "error").write_text(str(exc) + "\n")
        print(f"050 harness: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        if output:
            (output / "error").write_text("operator interrupted reproduction\n")
        print("050 harness: interrupted; evidence retained", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
