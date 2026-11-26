#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export EMBYVIEW_SCRIPT_DIR="${SCRIPT_DIR}" EMBYVIEW_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
exec python3 - "$@" <<'PY'
import argparse, ctypes, json, os, plistlib, pwd, re, shlex, shutil, signal, socket, subprocess, sys, tempfile, time

BUNDLE_ID, DEF_TARGET, DEF_BACKUP = "io.github.ump45nose.embyview", "~/Applications/EmbyView.app", "~/Library/Application Support/EmbyViewInstaller/backups"
run = lambda cmd, **kw: subprocess.run(cmd, capture_output=True, text=True, **kw)
emsg = lambda r: (r.stderr or r.stdout).strip()
def base_res(host, action, target):
    return {"host": host, "action": action, "status": "failed", "targetPath": target, "previousVersion": None, "installedVersion": None,
            "bundleId": BUNDLE_ID, "signatureVerified": False, "designatedRequirement": None, "continuityVerified": None,
            "desktopSessionAvailable": None, "launchedPid": None, "windowVisible": False, "windowCount": 0,
            "authorizationContinuity": "pending_runtime_check", "backupPath": None, "rollbackPerformed": False, "rollbackSucceeded": None, "error": None}
def emit(rep, rpath, code):
    out = json.dumps(rep, indent=2, ensure_ascii=False); print(out)
    if rpath: os.makedirs(os.path.dirname(os.path.abspath(rpath)), exist_ok=True); open(rpath, "w", encoding="utf-8").write(out + "\n")
    sys.exit(code)
def read_plist(app):
    p = os.path.join(app, "Contents/Info.plist")
    if not os.path.isfile(p): return None
    try:
        d = plistlib.load(open(p, "rb")); s, b = str(d.get("CFBundleShortVersionString") or ""), str(d.get("CFBundleVersion") or "")
        return {"bundleId": d.get("CFBundleIdentifier"), "version": f"{s}+{b}" if s and b else (s or b or None)}
    except Exception: return None
def designated_req(app):
    r = run(["codesign", "-d", "-r-", app]); m = re.search(r"designated\s*=>\s*(.+)", r.stdout) if r.returncode == 0 else None
    return m.group(1).strip() if m else None
def verify_app(app):
    if not os.path.isdir(app): return False, f"app bundle not found: {app}", None
    if not (info := read_plist(app)): return False, f"invalid or missing Info.plist in {app}", None
    if info["bundleId"] != BUNDLE_ID: return False, f"unexpected CFBundleIdentifier '{info['bundleId']}'", info
    if (v := run(["codesign", "--verify", "--deep", "--strict", app])).returncode != 0: return False, f"codesign verify failed: {emsg(v)}", info
    if not (req := designated_req(app)): return False, "missing designated requirement", info
    return True, None, info | {"designatedRequirement": req}
def find_pids(app):
    if not os.path.exists(app): return []
    pre = os.path.realpath(app) + "/Contents/MacOS/"
    return [int(p[0]) for l in run(["ps", "-eo", "pid=,comm="]).stdout.splitlines() if len(p := l.strip().split(None, 1)) == 2 and p[0].isdigit() and int(p[0]) != os.getpid() and os.path.realpath(p[1]).startswith(pre)]
def stop_running(app):
    for sig, ws in ((signal.SIGTERM, 5.0), (signal.SIGKILL, 1.0)):
        if not (pids := find_pids(app)): return
        for p in pids:
            try: os.kill(p, sig)
            except OSError: pass
        end = time.time() + ws
        while time.time() < end and find_pids(app): time.sleep(0.2)
def count_windows(pids):
    cg, cf, vp, i32, f64 = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"), ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"), ctypes.c_void_p, ctypes.c_int32, ctypes.c_double
    for fn, at, rt in ((cg.CGWindowListCopyWindowInfo, [ctypes.c_uint32, ctypes.c_uint32], vp), (cf.CFArrayGetCount, [vp], ctypes.c_long), (cf.CFArrayGetValueAtIndex, [vp, ctypes.c_long], vp), (cf.CFDictionaryGetValue, [vp, vp], vp), (cf.CFStringCreateWithCString, [vp, ctypes.c_char_p, ctypes.c_uint32], vp), (cf.CFNumberGetValue, [vp, ctypes.c_long, vp], ctypes.c_bool), (cf.CFBooleanGetValue, [vp], ctypes.c_bool), (cf.CFRelease, [vp], None)):
        fn.argtypes, fn.restype = at, rt
    ks = [cf.CFStringCreateWithCString(None, s.encode(), 0x08000100) for s in ("kCGWindowOwnerPID", "kCGWindowLayer", "kCGWindowIsOnscreen", "kCGWindowAlpha", "kCGWindowBounds", "Width", "Height")]
    arr, cnt, owner = cg.CGWindowListCopyWindowInfo(1 | 16, 0), 0, None
    try:
        for i in range(cf.CFArrayGetCount(arr) if arr else 0):
            d = cf.CFArrayGetValueAtIndex(arr, i); pv, lv, ov, av, bv = (cf.CFDictionaryGetValue(d, ks[j]) for j in range(5))
            if not (pv and lv): continue
            pid, lay, al, w, h = i32(), i32(), f64(1.0), f64(2.0), f64(2.0)
            cf.CFNumberGetValue(pv, 3, ctypes.byref(pid)); cf.CFNumberGetValue(lv, 3, ctypes.byref(lay))
            if pid.value not in pids or lay.value != 0 or (ov and not cf.CFBooleanGetValue(ov)): continue
            if av: cf.CFNumberGetValue(av, 6, ctypes.byref(al))
            if al.value <= 0: continue
            if bv:
                for kv, out in ((ks[5], w), (ks[6], h)):
                    if (v := cf.CFDictionaryGetValue(bv, kv)): cf.CFNumberGetValue(v, 6, ctypes.byref(out))
                if w.value <= 1 or h.value <= 1: continue
            cnt += 1; owner = owner or pid.value
    finally:
        if arr: cf.CFRelease(arr)
        for k in ks: cf.CFRelease(k)
    return cnt, owner
def verify_and_launch(app, skip, rep):
    ok, err, info = verify_app(app)
    rep.update(installedVersion=info["version"] if info else None, signatureVerified=ok, designatedRequirement=info["designatedRequirement"] if ok else rep["designatedRequirement"])
    if not ok: return False, err
    cu, user = run(["stat", "-f", "%Su", "/dev/console"]).stdout.strip(), pwd.getpwuid(os.getuid()).pw_name
    desk = bool(cu and cu == user and cu not in ("root", "loginwindow") and run(["pgrep", "-x", "WindowServer"]).returncode == 0)
    rep.update(desktopSessionAvailable=desk, launchedPid=None, windowVisible=False, windowCount=0)
    if skip or not desk: return True, None
    if (r := run(["open", "-n", app])).returncode != 0: return False, f"open failed: {emsg(r)}"
    end, last_pid = time.time() + 10.0, None
    while time.time() < end:
        if pids := find_pids(app):
            last_pid = pids[0]; cnt, owner = count_windows(set(pids))
            if cnt > 0: rep.update(launchedPid=owner or last_pid, windowVisible=True, windowCount=cnt); return True, None
        time.sleep(0.5)
    pids = find_pids(app); rep["launchedPid"] = pids[0] if pids else last_pid
    return False, "process running but no visible window within 10s" if pids else "app process did not stay alive within 10s"
def atomic_replace(src_app, target):
    parent = os.path.dirname(os.path.abspath(target)); os.makedirs(parent, exist_ok=True)
    stage, old = os.path.join(parent, f".EmbyView.stage.{os.getpid()}.app"), os.path.join(parent, f".EmbyView.old.{os.getpid()}.app")
    for p in (stage, old): shutil.rmtree(p, ignore_errors=True)
    if (r := run(["ditto", src_app, stage])).returncode != 0: raise RuntimeError(f"ditto stage failed: {emsg(r)}")
    moved = False
    try:
        if os.path.exists(target): os.rename(target, old); moved = True
        os.rename(stage, target)
    except Exception:
        if moved and not os.path.exists(target) and os.path.exists(old): os.rename(old, target)
        shutil.rmtree(stage, ignore_errors=True); raise
    shutil.rmtree(old, ignore_errors=True)
def run_remote(a):
    rep, sdir, rroot, ltmp, rtmp = base_res(a.host, "rollback" if a.rollback else "install", a.target or DEF_TARGET), os.environ["EMBYVIEW_SCRIPT_DIR"], os.environ["EMBYVIEW_REPO_ROOT"], tempfile.mkdtemp(prefix="embyview-remote-"), None
    fail = lambda msg: (rep.update(error=msg), emit(rep, a.report, 1))
    try:
        os.makedirs(os.path.join(ltmp, "scripts/embyview")); os.makedirs(os.path.join(ltmp, "macos/Runner"))
        shutil.copy2(os.path.join(sdir, "install-macos.sh"), os.path.join(ltmp, "scripts/embyview/install-macos.sh")); cmd = []
        if a.candidate:
            if not os.path.isfile(a.candidate): fail(f"candidate not found: {a.candidate}")
            cand, base = json.load(open(a.candidate, encoding="utf-8")), os.path.dirname(os.path.abspath(a.candidate))
            arch = cand.get("archivePath") or ""; arch = arch if os.path.isabs(arch) else os.path.normpath(os.path.join(base, arch))
            if not os.path.isfile(arch): fail(f"candidate archive not found: {arch}")
            for s, d in ((os.path.join(sdir, "sign-macos.sh"), "scripts/embyview/sign-macos.sh"), (os.path.join(rroot, "macos/Runner/Release.entitlements"), "macos/Runner/Release.entitlements"), (arch, os.path.basename(arch))): shutil.copy2(s, os.path.join(ltmp, d))
            open(os.path.join(ltmp, "release-candidate.json"), "w", encoding="utf-8").write(json.dumps(dict(cand, archivePath=os.path.basename(arch), appPath=None), indent=2) + "\n")
            cmd += ["--candidate", "__RTMP__/release-candidate.json"]
        elif a.app:
            if not os.path.isdir(a.app): fail(f"app not found: {a.app}")
            if (zr := run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", a.app, os.path.join(ltmp, "app.zip")])).returncode != 0: fail(f"ditto pack failed: {emsg(zr)}")
            cmd += ["--app", f"__RTMP__/unpacked/{os.path.basename(os.path.normpath(a.app))}"]
        else: cmd.append("--rollback")
        if (mr := run(["ssh", a.host, "mktemp -d /tmp/embyview-install.XXXXXX"])).returncode != 0: fail(f"ssh mktemp failed: {emsg(mr)}")
        rtmp = mr.stdout.strip(); p1 = subprocess.Popen(["tar", "-cf", "-", "-C", ltmp, "."], stdout=subprocess.PIPE)
        p2 = subprocess.run(["ssh", a.host, f"tar -xf - -C {shlex.quote(rtmp)}"], stdin=p1.stdout, capture_output=True, text=True); p1.stdout.close(); p1.wait()
        if p1.returncode != 0 or p2.returncode != 0: fail(f"remote transfer failed: {emsg(p2)}")
        rcmd = ["bash", f"{rtmp}/scripts/embyview/install-macos.sh", *(c.replace("__RTMP__", rtmp) for c in cmd)] + [x for fl, v in (("--identity", a.identity), ("--target", a.target), ("--backup-dir", a.backup_dir)) if v for x in (fl, v)] + (["--skip-launch"] if a.skip_launch else [])
        pre = f"mkdir -p {shlex.quote(rtmp + '/unpacked')} && ditto -x -k {shlex.quote(rtmp + '/app.zip')} {shlex.quote(rtmp + '/unpacked')} && " if a.app else ""
        rr = run(["ssh", a.host, pre + " ".join(shlex.quote(c) for c in rcmd)])
        try: data = json.loads(rr.stdout)
        except Exception: fail(f"remote execution failed: {emsg(rr)}")
        emit(data, a.report, rr.returncode)
    finally:
        shutil.rmtree(ltmp, ignore_errors=True)
        if rtmp: run(["ssh", a.host, f"python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' {shlex.quote(rtmp)}"])
def main():
    ap = argparse.ArgumentParser(prog="install-macos.sh")
    for fl in ("--host", "--app", "--candidate", "--identity", "--target", "--backup-dir", "--report"): ap.add_argument(fl)
    ap.add_argument("--rollback", action="store_true"); ap.add_argument("--skip-launch", action="store_true"); a = ap.parse_args()
    if sum(bool(x) for x in (a.app, a.candidate, a.rollback)) != 1: emit(base_res(a.host or socket.gethostname().split(".")[0], "install", a.target or DEF_TARGET) | {"error": "specify exactly one of --app, --candidate, or --rollback"}, a.report, 1)
    if a.host: run_remote(a)
    target, bdir = os.path.expanduser(a.target or DEF_TARGET), os.path.expanduser(a.backup_dir or DEF_BACKUP)
    bapp, had_prev = os.path.join(bdir, "previous.app"), os.path.isdir(target)
    prev_info, prev_req = (read_plist(target), designated_req(target)) if had_prev else (None, None)
    rep = base_res(socket.gethostname().split(".")[0], "rollback" if a.rollback else ("update" if had_prev else "install"), target)
    rep.update(previousVersion=prev_info["version"] if prev_info else None, backupPath=bapp if os.path.isdir(bapp) else None); tmp = tempfile.mkdtemp(prefix="embyview-install-work-")
    try:
        staged = os.path.join(tmp, "EmbyView.app")
        if a.rollback:
            rep["rollbackPerformed"] = True; ok, err, _ = verify_app(bapp) if os.path.isdir(bapp) else (False, f"backup not found: {bapp}", None)
            if not ok: rep.update(rollbackSucceeded=False, error=f"backup check failed: {err}"); emit(rep, a.report, 1)
            stop_running(target); atomic_replace(bapp, target); ok, err = verify_and_launch(target, a.skip_launch, rep)
            if prev_req and ok: rep["continuityVerified"] = run(["codesign", "--verify", "--strict", f"--test-requirement=={prev_req}", target]).returncode == 0
            rep.update(rollbackSucceeded=ok, status="ok" if ok else "failed", error=err); emit(rep, a.report, 0 if ok else 1)
        if a.candidate:
            sc = ["bash", os.path.join(os.environ["EMBYVIEW_SCRIPT_DIR"], "sign-macos.sh"), "--candidate", a.candidate, "--output", staged] + (["--identity", a.identity] if a.identity else []) + (["--previous-app", target] if prev_req else [])
            if (sr := run(sc)).returncode != 0:
                try: err = json.loads(sr.stdout).get("error") or sr.stderr
                except Exception: err = emsg(sr)
                rep["error"] = f"sign-macos.sh failed: {err}"; emit(rep, a.report, 1)
        else:
            if not os.path.isdir(a.app): rep["error"] = f"app not found: {a.app}"; emit(rep, a.report, 1)
            if (dr := run(["ditto", a.app, staged])).returncode != 0: rep["error"] = f"ditto failed: {emsg(dr)}"; emit(rep, a.report, 1)
        ok, err, info = verify_app(staged)
        if not ok: rep["error"] = f"staged verification failed: {err}"; emit(rep, a.report, 1)
        rep.update(designatedRequirement=info["designatedRequirement"], signatureVerified=True)
        if prev_req:
            cont = run(["codesign", "--verify", "--strict", f"--test-requirement=={prev_req}", staged]).returncode == 0; rep["continuityVerified"] = cont
            if not cont: rep["error"] = "designated requirement continuity check failed"; emit(rep, a.report, 1)
        stop_running(target)
        if had_prev:
            os.makedirs(bdir, exist_ok=True); tb = bapp + f".tmp.{os.getpid()}"; shutil.rmtree(tb, ignore_errors=True)
            if (br := run(["ditto", target, tb])).returncode != 0: raise RuntimeError(f"backup failed: {emsg(br)}")
            shutil.rmtree(bapp, ignore_errors=True); os.rename(tb, bapp); rep["backupPath"] = bapp
        atomic_replace(staged, target); ok, err = verify_and_launch(target, a.skip_launch, rep)
        if ok: rep["status"] = "ok"; emit(rep, a.report, 0)
        rep["error"] = err
        if rep["backupPath"] and os.path.isdir(rep["backupPath"]):
            rep["rollbackPerformed"] = True; stop_running(target); atomic_replace(rep["backupPath"], target)
            rok, rerr = verify_and_launch(target, a.skip_launch, rep)
            rep.update(rollbackSucceeded=rok, status="rolled_back" if rok else "failed", error=err if rok else f"{err}; rollback failed: {rerr}")
        emit(rep, a.report, 1)
    finally: shutil.rmtree(tmp, ignore_errors=True)
main()
PY
