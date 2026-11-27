#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_env_kc="${EMBYVIEW_SIGN_KEYCHAIN-}"
[[ -f "${HOME}/.config/embyview/signing.env" ]] && source "${HOME}/.config/embyview/signing.env"
export EMBYVIEW_SIGN_KEYCHAIN="${_env_kc:-${EMBYVIEW_SIGN_KEYCHAIN:-}}"
export EMBYVIEW_SCRIPT_DIR="${SCRIPT_DIR}" EMBYVIEW_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
exec 3<&0
exec python3 - "$@" <<'PY'
import argparse, ctypes, json, os, plistlib, pwd, re, shlex, shutil, signal, socket, subprocess, sys, tempfile, time

BUNDLE_ID, DEF_TARGET, DEF_BACKUP = "io.github.ump45nose.embyview", "~/Applications/EmbyView.app", "~/Library/Application Support/EmbyViewInstaller/backups"
KEYCHAIN_SERVICE = "flutter_secure_storage_service"
KEYCHAIN_ACCT_PREFIXES = ("embyview.", "server_token_", "client_cert_")
KEYCHAIN_ACCT_EXACT = {"mtls_client_cert_hosts"}
REQ_ENTS = ("com.apple.security.app-sandbox", "com.apple.security.cs.allow-jit", "com.apple.security.network.client",
            "com.apple.security.network.server", "com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope")
def run(cmd, **kw):
    if "input" not in kw: kw.setdefault("stdin", subprocess.DEVNULL)
    return subprocess.run(cmd, capture_output=True, text=True, **kw)
emsg = lambda r: (r.stderr or r.stdout).strip()
def rm_any(p):
    if os.path.islink(p) or os.path.isfile(p):
        try: os.unlink(p)
        except OSError: pass
    else: shutil.rmtree(p, ignore_errors=True)
def base_res(host, action, target):
    return {"host": host, "action": action, "status": "failed", "targetPath": target, "previousVersion": None, "installedVersion": None,
            "bundleId": BUNDLE_ID, "signatureVerified": False, "designatedRequirement": None, "continuityVerified": None,
            "keychainAccessUpdated": None, "keychainItemsMatched": 0, "keychainItemsUpdated": 0, "keychainPartitionId": None,
            "desktopSessionAvailable": None, "launchedPid": None, "windowVisible": False, "windowCount": 0,
            "authorizationContinuity": "pending_runtime_check", "backupPath": None, "rollbackPerformed": False, "rollbackSucceeded": None, "error": None}
def emit(rep, rpath, code):
    out = json.dumps(rep, indent=2, ensure_ascii=False); print(out)
    if rpath: os.makedirs(os.path.dirname(os.path.abspath(rpath)), exist_ok=True); open(rpath, "w", encoding="utf-8").write(out + "\n")
    sys.exit(code)
def read_kc_pass(from_stdin):
    pw = ""
    try:
        if from_stdin:
            with os.fdopen(3, "r", encoding="utf-8") as f:
                pw = f.readline().rstrip("\r\n")
        else:
            os.close(3)
    except OSError:
        pass
    return pw if from_stdin else os.environ.get("EMBYVIEW_KEYCHAIN_PASSWORD", "")
def resolve_keychain(arg):
    raw = arg or os.environ.get("EMBYVIEW_SIGN_KEYCHAIN") or run(["security", "default-keychain", "-d", "user"]).stdout.strip().strip('"')
    return os.path.expanduser(raw) if raw else ""
def sec_i(commands, timeout=20):
    lines = []
    q = lambda s: '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    for sub, args in commands:
        if any("\n" in x or "\r" in x for x in args):
            return subprocess.CompletedProcess(["security"], 1, "", f"{sub}: invalid newline in argument")
        lines.append(f"{sub} " + " ".join(q(x) for x in args))
    return run(["security", "-q", "-i"], input="\n".join(lines) + "\n", timeout=timeout)
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
def app_partition_id(app):
    dv = run(["codesign", "-dvvv", app]).stderr
    if (tm := re.search(r"^TeamIdentifier=(.+)$", dv, re.M)) and tm.group(1).strip() not in ("", "not set"):
        return f"teamid:{tm.group(1).strip()}"
    if (cm := re.search(r"^CDHash=([0-9A-Fa-f]+)$", dv, re.M)):
        return f"cdhash:{cm.group(1).strip().lower()}"
    return None
def parse_keychain_items(kc):
    r = run(["security", "dump-keychain", "-a", kc])
    if r.returncode != 0: return None, f"dump-keychain failed: {emsg(r)}"
    items = []
    for blk in r.stdout.split("keychain: "):
        if 'class: "genp"' not in blk or f'"svce"<blob>="{KEYCHAIN_SERVICE}"' not in blk: continue
        acct = None
        if (mh := re.search(r'"acct"<blob>=0x([0-9A-Fa-f]+)', blk)):
            try: acct = bytes.fromhex(mh.group(1)).decode("utf-8")
            except Exception: acct = None
        if acct is None and (ms := re.search(r'"acct"<blob>="([^"]*)"', blk)):
            acct = ms.group(1)
        if not acct: continue
        acc_part = blk.split("access:", 1)[1] if "access:" in blk else ""
        matched = acct.startswith(KEYCHAIN_ACCT_PREFIXES) or acct in KEYCHAIN_ACCT_EXACT or f'identifier "{BUNDLE_ID}"' in acc_part
        if not matched: continue
        decrypt_reqs, security_allowed, partitions = set(), False, set()
        for ent in re.split(r"\n\s*entry\s+\d+:\s*\n", acc_part)[1:]:
            if re.search(r"authorizations\b[^\n]*\bdecrypt\b", ent):
                for rm in re.finditer(r"requirement:\s*(.+)", ent): decrypt_reqs.add(rm.group(1).strip())
                if "/usr/bin/security" in ent: security_allowed = True
            if re.search(r"authorizations\b[^\n]*\bpartition_id\b", ent):
                if (dm := re.search(r"description:\s*(.+)", ent)):
                    partitions.update(t.strip() for t in dm.group(1).split(",") if t.strip())
        items.append({"acct": acct, "decrypt_reqs": decrypt_reqs, "security_allowed": security_allowed, "partitions": partitions})
    return items, None
def inspect_keychain_sync(app, kc):
    if not kc or not os.path.exists(kc): return None, None, [], [], f"keychain not found: {kc}"
    part_id, req = app_partition_id(app), designated_req(app)
    if not part_id or not req: return part_id, req, [], [], "unable to read app CDHash/TeamIdentifier or designated requirement"
    items, err = parse_keychain_items(kc)
    if err: return part_id, req, [], [], err
    need = [it for it in items if (req not in it["decrypt_reqs"]) or (part_id not in it["partitions"])]
    return part_id, req, items, need, None
def sync_keychain_access(app, kc, kc_pass, rep):
    part_id, req, items, need, err = inspect_keychain_sync(app, kc)
    rep["keychainPartitionId"] = part_id
    rep["keychainItemsMatched"] = len(items)
    if err:
        rep.update(keychainAccessUpdated=False, keychainItemsUpdated=0)
        return False, err
    if not need:
        rep.update(keychainAccessUpdated=True, keychainItemsUpdated=0)
        return True, None
    if not kc_pass:
        rep.update(keychainAccessUpdated=False, keychainItemsUpdated=0)
        return False, f"EMBYVIEW_KEYCHAIN_PASSWORD is required to update keychain access for {len(need)} item(s)"
    ur = sec_i([("unlock-keychain", ["-p", kc_pass, kc])])
    if ur.returncode != 0:
        rep.update(keychainAccessUpdated=False, keychainItemsUpdated=0)
        return False, "failed to unlock keychain for access update"
    desired_parts = f"{part_id},apple-tool:,apple:"
    for it in need:
        acct = it["acct"]
        if req not in it["decrypt_reqs"]:
            if not it["security_allowed"]:
                rep.update(keychainAccessUpdated=False, keychainItemsUpdated=0)
                return False, "keychain item decrypt ACL does not trust the new app signing requirement"
            fr = run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", acct, "-w", kc], timeout=15)
            if fr.returncode != 0:
                rep.update(keychainAccessUpdated=False, keychainItemsUpdated=0)
                return False, "failed to read keychain item for ACL refresh"
            val = fr.stdout.rstrip("\r\n")
            ar = sec_i([("add-generic-password", ["-U", "-s", KEYCHAIN_SERVICE, "-a", acct, "-T", app, "-w", val, kc])])
            val = ""
            if ar.returncode != 0:
                rep.update(keychainAccessUpdated=False, keychainItemsUpdated=0)
                return False, "failed to update keychain item ACL"
        pr = sec_i([("set-generic-password-partition-list", ["-S", desired_parts, "-s", KEYCHAIN_SERVICE, "-a", acct, "-k", kc_pass, kc])])
        if pr.returncode != 0:
            rep.update(keychainAccessUpdated=False, keychainItemsUpdated=0)
            return False, "failed to update keychain item partition list"
    _, _, _, still_need, verr = inspect_keychain_sync(app, kc)
    if verr or still_need:
        rep.update(keychainAccessUpdated=False, keychainItemsUpdated=len(need) - len(still_need))
        return False, verr or f"keychain access verification failed for {len(still_need)} item(s)"
    rep.update(keychainAccessUpdated=True, keychainItemsUpdated=len(need))
    return True, None
def verify_app(app):
    if not os.path.isdir(app): return False, f"app bundle not found: {app}", None
    if not (info := read_plist(app)): return False, f"invalid or missing Info.plist in {app}", None
    if info["bundleId"] != BUNDLE_ID: return False, f"unexpected CFBundleIdentifier '{info['bundleId']}'", info
    if (v := run(["codesign", "--verify", "--deep", "--strict", app])).returncode != 0: return False, f"codesign verify failed: {emsg(v)}", info
    dv = run(["codesign", "-dvvv", app]).stderr
    if "Signature=adhoc" in dv or not re.search(r"^Authority=.+", dv, re.M): return False, "ad-hoc signature or missing Authority", info
    if not (id_m := re.search(r"^Identifier=(.+)$", dv, re.M)) or id_m.group(1).strip() != BUNDLE_ID: return False, f"unexpected code signing Identifier '{id_m.group(1).strip() if id_m else 'missing'}'", info
    er = run(["codesign", "-d", "--entitlements", "-", "--xml", app])
    try: ents = plistlib.loads(er.stdout.encode()) if er.returncode == 0 else {}
    except Exception: ents = {}
    if (miss := [k for k in REQ_ENTS if ents.get(k) is not True]): return False, f"missing required entitlements: {', '.join(miss)}", info
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
        if not arr: return None, None
        for i in range(cf.CFArrayGetCount(arr)):
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
            if cnt is None: rep.update(desktopSessionAvailable=False, launchedPid=last_pid, windowVisible=False, windowCount=0); return True, None
            if cnt > 0: rep.update(launchedPid=owner or last_pid, windowVisible=True, windowCount=cnt); return True, None
        time.sleep(0.5)
    pids = find_pids(app); rep["launchedPid"] = pids[0] if pids else last_pid
    return False, "process running but no visible window within 10s" if pids else "app process did not stay alive within 10s"
def atomic_replace(src_app, dst):
    parent, name = os.path.dirname(os.path.abspath(dst)), os.path.basename(os.path.abspath(dst)); os.makedirs(parent, exist_ok=True)
    stage, old = os.path.join(parent, f".{name}.tmp.{os.getpid()}"), os.path.join(parent, f".{name}.old.{os.getpid()}")
    rm_any(stage); rm_any(old); moved = False
    try:
        if (r := run(["ditto", src_app, stage])).returncode != 0: raise RuntimeError(f"ditto stage failed: {emsg(r)}")
        if os.path.lexists(dst): os.rename(dst, old); moved = True
        os.rename(stage, dst)
    except Exception:
        if moved and not os.path.lexists(dst) and os.path.lexists(old): os.rename(old, dst)
        rm_any(stage); raise
    rm_any(old)
def run_remote(a, kc_pass):
    rep, sdir, rroot, ltmp, rtmp = base_res(a.host, "rollback" if a.rollback else "install", a.target or DEF_TARGET), os.environ["EMBYVIEW_SCRIPT_DIR"], os.environ["EMBYVIEW_REPO_ROOT"], tempfile.mkdtemp(prefix="embyview-remote-"), None
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", a.host]
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
        if (mr := run([*ssh, "mktemp -d /tmp/embyview-install.XXXXXX"])).returncode != 0: fail(f"ssh mktemp failed: {emsg(mr)}")
        rtmp = mr.stdout.strip()
        if not re.fullmatch(r"/tmp/embyview-install\.[A-Za-z0-9]+", rtmp): bad = rtmp; rtmp = None; fail(f"unexpected remote temp path: {bad!r}")
        p1 = subprocess.Popen(["tar", "-cf", "-", "-C", ltmp, "."], stdout=subprocess.PIPE)
        p2 = subprocess.run([*ssh, f"tar -xf - -C {shlex.quote(rtmp)}"], stdin=p1.stdout, capture_output=True, text=True); p1.stdout.close(); p1.wait()
        if p1.returncode != 0 or p2.returncode != 0: fail(f"remote transfer failed: {emsg(p2)}")
        rcmd = ["bash", f"{rtmp}/scripts/embyview/install-macos.sh", *(c.replace("__RTMP__", rtmp) for c in cmd)] + [x for fl, v in (("--identity", a.identity), ("--keychain", a.keychain), ("--target", a.target), ("--backup-dir", a.backup_dir)) if v for x in (fl, v)] + (["--skip-launch"] if a.skip_launch else []) + (["--keychain-password-stdin"] if kc_pass else [])
        pre = f"mkdir -p {shlex.quote(rtmp + '/unpacked')} && ditto -x -k {shlex.quote(rtmp + '/app.zip')} {shlex.quote(rtmp + '/unpacked')} && " if a.app else ""
        rr = run([*ssh, pre + " ".join(shlex.quote(c) for c in rcmd)], **({"input": kc_pass + "\n"} if kc_pass else {}))
        try: data = json.loads(rr.stdout)
        except Exception: fail(f"remote execution failed: {emsg(rr)}")
        emit(data, a.report, rr.returncode)
    except Exception as e: fail(str(e))
    finally:
        shutil.rmtree(ltmp, ignore_errors=True)
        if rtmp: run([*ssh, f"python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' {shlex.quote(rtmp)}"])
def main():
    ap = argparse.ArgumentParser(prog="install-macos.sh")
    for fl in ("--host", "--app", "--candidate", "--identity", "--keychain", "--target", "--backup-dir", "--report"): ap.add_argument(fl)
    ap.add_argument("--rollback", action="store_true"); ap.add_argument("--skip-launch", action="store_true"); ap.add_argument("--keychain-password-stdin", action="store_true"); a = ap.parse_args()
    kc_pass = read_kc_pass(a.keychain_password_stdin)
    if sum(bool(x) for x in (a.app, a.candidate, a.rollback)) != 1: emit(base_res(a.host or socket.gethostname().split(".")[0], "install", a.target or DEF_TARGET) | {"error": "specify exactly one of --app, --candidate, or --rollback"}, a.report, 1)
    if a.host: run_remote(a, kc_pass)
    target, bdir, kc = os.path.expanduser(a.target or DEF_TARGET), os.path.expanduser(a.backup_dir or DEF_BACKUP), resolve_keychain(a.keychain)
    bapp, had_prev = os.path.join(bdir, "previous.app"), os.path.isdir(target)
    prev_ok, _, prev_vinfo = verify_app(target) if had_prev else (False, None, None)
    prev_info = prev_vinfo or (read_plist(target) if had_prev else None)
    prev_req = prev_vinfo["designatedRequirement"] if prev_ok else (designated_req(target) if (had_prev and a.rollback) else None)
    rep = base_res(socket.gethostname().split(".")[0], "rollback" if a.rollback else ("update" if had_prev else "install"), target)
    rep["previousVersion"] = prev_info["version"] if prev_info else None; tmp = tempfile.mkdtemp(prefix="embyview-install-work-")
    try:
        staged = os.path.join(tmp, "EmbyView.app")
        if a.rollback:
            rep.update(rollbackPerformed=True, backupPath=bapp if os.path.isdir(bapp) else None)
            ok, err, _ = verify_app(bapp) if os.path.isdir(bapp) else (False, f"backup not found: {bapp}", None)
            if not ok: rep.update(rollbackSucceeded=False, error=f"backup check failed: {err}"); emit(rep, a.report, 1)
            stop_running(target); atomic_replace(bapp, target)
            kok, kerr = sync_keychain_access(target, kc, kc_pass, rep)
            ok, err = (verify_and_launch(target, a.skip_launch, rep) if kok else (False, kerr))
            if prev_req and ok: rep["continuityVerified"] = run(["codesign", "--verify", "--strict", f"--test-requirement=={prev_req}", target]).returncode == 0
            rep.update(rollbackSucceeded=ok, status="ok" if ok else "failed", error=err); emit(rep, a.report, 0 if ok else 1)
        if a.candidate:
            sc = ["bash", os.path.join(os.environ["EMBYVIEW_SCRIPT_DIR"], "sign-macos.sh"), "--candidate", a.candidate, "--output", staged] + (["--identity", a.identity] if a.identity else []) + (["--keychain", kc] if a.keychain else []) + (["--previous-app", target] if prev_req else [])
            senv = dict(os.environ, EMBYVIEW_KEYCHAIN_PASSWORD=kc_pass) if kc_pass else None
            sr = run(sc, env=senv)
            try: srep = json.loads(sr.stdout)
            except Exception: srep = {}
            if sr.returncode != 0:
                if srep.get("continuityVerified") is False: rep["continuityVerified"] = False
                rep["error"] = f"sign-macos.sh failed: {srep.get('error') or emsg(sr)}"; emit(rep, a.report, 1)
            rep.update(designatedRequirement=srep.get("designatedRequirement"), signatureVerified=True, continuityVerified=srep.get("continuityVerified"))
        else:
            if not os.path.isdir(a.app): rep["error"] = f"app not found: {a.app}"; emit(rep, a.report, 1)
            if (dr := run(["ditto", a.app, staged])).returncode != 0: rep["error"] = f"ditto failed: {emsg(dr)}"; emit(rep, a.report, 1)
            ok, err, info = verify_app(staged)
            if not ok: rep["error"] = f"staged verification failed: {err}"; emit(rep, a.report, 1)
            rep.update(designatedRequirement=info["designatedRequirement"], signatureVerified=True)
            if prev_req:
                cont = run(["codesign", "--verify", "--strict", f"--test-requirement=={prev_req}", staged]).returncode == 0; rep["continuityVerified"] = cont
                if not cont: rep["error"] = "designated requirement continuity check failed"; emit(rep, a.report, 1)
        part_id, _, kitems, kneed, kerr = inspect_keychain_sync(staged, kc)
        rep.update(keychainPartitionId=part_id, keychainItemsMatched=len(kitems))
        if kerr:
            rep.update(keychainAccessUpdated=False, error=kerr); emit(rep, a.report, 1)
        if kneed and not kc_pass:
            rep.update(keychainAccessUpdated=False, error=f"EMBYVIEW_KEYCHAIN_PASSWORD is required to update keychain access for {len(kneed)} item(s)"); emit(rep, a.report, 1)
        stop_running(target)
        if prev_ok: atomic_replace(target, bapp); rep["backupPath"] = bapp
        atomic_replace(staged, target)
        kok, kerr = sync_keychain_access(target, kc, kc_pass, rep)
        ok, err = (verify_and_launch(target, a.skip_launch, rep) if kok else (False, kerr))
        if ok: rep["status"] = "ok"; emit(rep, a.report, 0)
        rep["error"] = err
        if rep["backupPath"] and os.path.isdir(rep["backupPath"]):
            rep["rollbackPerformed"] = True; stop_running(target); atomic_replace(rep["backupPath"], target)
            sync_keychain_access(target, kc, kc_pass, rep)
            rok, rerr = verify_and_launch(target, a.skip_launch, rep)
            rep.update(rollbackSucceeded=rok, status="rolled_back" if rok else "failed", error=err if rok else f"{err}; rollback failed: {rerr}")
        emit(rep, a.report, 1)
    except Exception as e:
        rep["error"] = str(e); emit(rep, a.report, 1)
    finally: shutil.rmtree(tmp, ignore_errors=True)
main()
PY
