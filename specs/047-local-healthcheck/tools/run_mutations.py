#!/usr/bin/env python3
"""Run 047 mutations sequentially in disposable source copies, never the checkout."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time


SUITES = ["local-healthcheck-auth", "local-healthcheck-processes", "local-healthcheck-notices",
          "local-healthcheck", "sigpipe-boot-paths", "local-render", "regenerate", "ci-workflows"]


def digest(root):
    result = hashlib.sha256()
    paths = [root/name for name in ("setup.sh", "VERSION")]
    for name in ("modules", "scripts", "docker", "tests", ".github"):
        paths.extend(path for path in (root/name).rglob("*") if path.is_file() or path.is_symlink())
    for path in sorted(paths):
        name = path.relative_to(root).as_posix()
        if any(part in ("__pycache__", "node_modules", "vendor") for part in path.parts) or name.endswith(".pyc"):
            continue
        data = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
        mode=path.lstat().st_mode & 0o777
        result.update(name.encode() + b"\0" + str(mode).encode()+b"\0"+data)
    return result.hexdigest()


def copy_source(source, dest):
    dest.mkdir()
    for name in ("modules", "scripts", "docker", "tests", ".github", ".specify"):
        shutil.copytree(source/name, dest/name, symlinks=True,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "node_modules"))
    for name in ("setup.sh", "VERSION", "CLAUDE.md", "README.md", ".gitignore"):
        if (source/name).exists():
            shutil.copy2(source/name, dest/name)


def cleanup_registered(scratch):
    """Only registries produced in this run's explicit temporary directory."""
    groups = set()
    pids = set()
    for path in scratch.rglob("timeout-active-*"):
        try:fields = path.read_text().split()
        except FileNotFoundError:continue
        if len(fields)==2 and all(s.isdecimal() for s in fields):
            groups.add(int(fields[0]))
            pids.add(int(fields[1]))
    for path in scratch.rglob("owned-groups"):
        try:fields=path.read_text().split()
        except FileNotFoundError:continue
        groups.update(int(s) for s in fields if s.isdecimal())
    for path in scratch.rglob("owned-pids"):
        try:fields=path.read_text().split()
        except FileNotFoundError:continue
        pids.update(int(s) for s in fields if s.isdecimal())
    killed = []
    for group in groups:
        if group <= 1 or group == os.getpgrp():
            raise RuntimeError("invalid owned process group")
        try:
            # A process group may outlive its leader. Its own fresh registry,
            # under this invocation's private scratch, is the ownership proof.
            os.killpg(group, signal.SIGKILL)
            killed.append(group)
        except ProcessLookupError:
            pass
    for pid in pids:
        if pid <= 1 or pid in (os.getpid(),os.getppid()):
            raise RuntimeError("invalid owned process")
        try:
            os.kill(pid,signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline=time.monotonic()+3
    while groups or pids:
        for kind,values in (("group",groups),("pid",pids)):
            for number in list(values):
                try:
                    if kind=="group":os.killpg(number,0)
                    else:os.kill(number,0)
                except ProcessLookupError:
                    values.remove(number)
        if not groups and not pids:break
        if time.monotonic()>=deadline:
            raise RuntimeError("owned children still present after cleanup")
        time.sleep(0.02)
    return killed


def check_syntax(root, changed, shell):
    for name in changed:
        if name.endswith((".tpl", ".sh", ".bash")):
            subprocess.run([shell, "-n", str(root/name)], check=True, capture_output=True)
        if name == "tests/fixtures/local-healthcheck/timeout":
            subprocess.run(["perl", "-c", str(root/name)], check=True, capture_output=True)
        source = (root/name).read_text()
        if name.endswith("local-healthcheck-lib.sh.tpl"):
            # Compile every literal jq filter independently; runtime data errors
            # are fine here, a filter compilation failure is never a kill.
            for program in re.findall(r"\bjq[^\n']*'([^']*)'", source):
                probe = subprocess.run(["jq", "-n", "--argjson", "now", "0", "--arg", "op", "validate", program],
                                       capture_output=True, timeout=5)
                if probe.returncode == 3:
                    raise RuntimeError("invalid mutant jq filter")
        if name.endswith("local-healthcheck-integration.sh"):
            for program in re.findall(r"<<'PY'\n(.*?)\nPY", source, re.S):
                ast.parse(program)


def execute(root, shell, bats, pattern, evidence, label, timeout_s):
    scratch = evidence/(label+"-tmp")
    scratch.mkdir()
    private_bin = scratch/"bin"
    private_bin.mkdir()
    real_mktemp = shutil.which("mktemp")
    # BSD mktemp -d ignores TMPDIR. This test-only wrapper supplies a template
    # only for that form, keeping every owned fixture/registry discoverable.
    wrapper = private_bin/"mktemp"
    wrapper.write_text('#!/bin/sh\nif [ "$#" -eq 1 ] && [ "$1" = -d ]; then\n'
                       '  exec "'+real_mktemp+'" -d "$APL047_MUTATION_TMP/fixture.XXXXXX"\nfi\n'
                       'exec "'+real_mktemp+'" "$@"\n')
    wrapper.chmod(0o755)
    env = os.environ.copy()
    env.update(PATH=str(private_bin)+":"+str(Path(shell).parent)+":"+env["PATH"],
               LC_ALL="C", PYTHONDONTWRITEBYTECODE="1", AGENTIC_VERSIONS_OFFLINE="1",
               TMPDIR=str(scratch), BATS_TMPDIR=str(scratch), APL047_MUTATION_TMP=str(scratch))
    env.pop("DOCKER_E2E", None)
    names = ["tests/"+suite+".bats" for suite in SUITES]
    expected = sum(bool(re.search(pattern, name)) for path in names
                   for name in re.findall(r'^@test "([^"]+)"', (root/path).read_text(), re.M))
    if not expected:
        raise RuntimeError("empty catcher")
    out, err = evidence/(label+".tap"), evidence/(label+".err")
    start = time.monotonic()
    with out.open("w") as stdout, err.open("w") as stderr:
        proc = subprocess.Popen(["perl","-e",'$SIG{PIPE}="IGNORE"; exec @ARGV',shell, bats, "--tap", "--filter", pattern, *names], cwd=root,
                                env=env, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            try:
                rc = proc.wait(timeout=timeout_s)
            except subprocess.TimeoutExpired:
                rc = 124
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            cleaned = cleanup_registered(scratch)
    text = out.read_text()
    lines = text.splitlines()
    plan = next((int(line[3:]) for line in lines if re.fullmatch(r"1\.\.[0-9]+", line)), None)
    ok = sum(line.startswith("ok ") for line in lines)
    failed = sum(line.startswith("not ok ") for line in lines)
    infrastructure = bool(re.search(r"syntax error|command not found|unexpected synthetic command shape|Permission denied|OSError|Traceback", text))
    skipped = sum('# skip' in line.lower() for line in lines)
    valid = plan == expected and ok+failed == expected and not skipped and not infrastructure and err.stat().st_size == 0
    return dict(rc=rc, expected=expected, plan=plan, ok=ok, failed=failed, valid=valid,
                seconds=round(time.monotonic()-start,3), stderr_bytes=err.stat().st_size,
                cleaned_owned_groups=cleaned)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="Comma-separated IDs; default M00 and entire catalog")
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--control-evidence",type=Path,help="Reuse only a dual control from the identical source and runner")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    catalog = json.loads(Path(__file__).with_name("mutations.json").read_text())
    catalog.insert(0, dict(id="M00", changes=[], catchers=[]))
    selected = set(args.only.split(",")) if args.only else {row["id"] for row in catalog}
    if selected-{row["id"] for row in catalog}:
        parser.error("unknown mutation ID")
    bats = shutil.which("bats")
    if not bats:
        parser.error("bats missing")
    shells = [("bash5", "/opt/homebrew/bin/bash"), ("bash32", "/bin/bash")]
    if not all(Path(shell).is_file() for _,shell in shells):
        parser.error("this dual-bash evidence runner requires the documented macOS interpreters")
    evidence = args.evidence or Path(tempfile.mkdtemp(prefix="apl047-mutations-"))
    try:
        evidence.resolve().relative_to(repo)
    except ValueError:
        pass
    else:
        parser.error("evidence must remain outside the source checkout")
    if evidence.exists() and any(evidence.iterdir()):
        parser.error("evidence destination must be empty; preserve previous results")
    if args.control_evidence and evidence.resolve()==args.control_evidence.resolve():
        parser.error("evidence destination must differ from the control")
    evidence.mkdir(parents=True, exist_ok=True)
    before = digest(repo)
    runner_hash=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if "M00" not in selected:
        if not args.control_evidence:
            parser.error("select M00 or provide validated --control-evidence")
        previous=json.loads((args.control_evidence/"results.json").read_text())
        context=json.loads((args.control_evidence/"context.json").read_text())
        controls=[r for r in previous if r['id']=='M00' and r['verdict']=='control_pass' and r['source_hash']==before]
        if {r['bash'] for r in controls}!={'bash5','bash32'} or context.get('runner_hash')!=runner_hash:
            parser.error("control is missing, failed or from another source/runner")
    (evidence/"context.json").write_text(json.dumps(dict(source_hash=before, bats=bats,signal_mode="ignore",
        runner_hash=runner_hash,
        interpreters={label:subprocess.run([shell,"--version"],check=True,text=True,capture_output=True).stdout.splitlines()[0]
                      for label,shell in shells}),indent=2)+"\n")
    results = []
    for row in catalog:
        if row["id"] not in selected:
            continue
        work = evidence/(row["id"]+"-source")
        copy_source(repo, work)
        changed = set()
        for edit in row["changes"]:
            path = work/edit["file"]
            data = path.read_text()
            if data.count(edit["old"]) != 1:
                raise RuntimeError(row["id"]+": missing or ambiguous source anchor")
            path.write_text(data.replace(edit["old"], edit["new"], 1))
            changed.add(edit["file"])
        delta = {name:dict(before=hashlib.sha256((repo/name).read_bytes()).hexdigest(),
                           after=hashlib.sha256((work/name).read_bytes()).hexdigest()) for name in changed}
        if any(entry["before"]==entry["after"] for entry in delta.values()):
            raise RuntimeError("empty mutation")
        pattern = (r"^047 |^(healthcheck|G3|H-|H[1-4]|notify)|^036 US5" if row["id"]=="M00" else
                   row.get('pattern') or r"^047 ("+"|".join(map(re.escape,row["catchers"]))+"):")
        for label,shell in shells:
            check_syntax(work, changed, shell)
            result = execute(work, shell, bats, pattern, evidence, row["id"]+"-"+label,
                             900 if row["id"]=="M00" else 150)
            killed = result["valid"] and result["rc"]==1 and result["failed"]>0
            passed = result["valid"] and result["rc"]==0 and result["failed"]==0
            result.update(id=row["id"], bash=label, source_hash=before, mutation_hash=digest(work),
                          delta=delta, verdict="control_pass" if row["id"]=="M00" and passed else
                          "killed" if row["id"]!="M00" and killed else "survived_or_invalid")
            results.append(result)
            (evidence/"results.json").write_text(json.dumps(results,indent=2)+"\n")
            print(json.dumps({k:v for k,v in result.items() if k!="delta"}), flush=True)
            if row['id']=='M00' and result['verdict']!='control_pass':
                raise RuntimeError("control failed; no mutations permitted")
        shutil.rmtree(work)
    if digest(repo)!=before:
        raise RuntimeError("source changed during mutation run")
    return 0 if all(r["verdict"] in ("control_pass","killed") for r in results) else 1


if __name__ == "__main__":
    def interrupt(signum,_frame):
        raise SystemExit(128+signum)
    signal.signal(signal.SIGTERM,interrupt)
    signal.signal(signal.SIGINT,interrupt)
    raise SystemExit(main())
