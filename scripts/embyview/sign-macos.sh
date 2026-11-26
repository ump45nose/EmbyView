#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_env_id="${EMBYVIEW_SIGN_IDENTITY-}" _env_kc="${EMBYVIEW_SIGN_KEYCHAIN-}"
[[ -f "${HOME}/.config/embyview/signing.env" ]] && source "${HOME}/.config/embyview/signing.env"
export EMBYVIEW_SIGN_IDENTITY="${_env_id:-${EMBYVIEW_SIGN_IDENTITY:-EmbyView Local Signing}}"
export EMBYVIEW_SIGN_KEYCHAIN="${_env_kc:-${EMBYVIEW_SIGN_KEYCHAIN:-}}" EMBYVIEW_REPO_ROOT="${REPO_ROOT}"
exec python3 - "$@" <<'PY'
import argparse, ctypes, datetime, hashlib, json, os, plistlib, re, shutil, socket, struct, subprocess, sys, tempfile

BUNDLE_ID = "io.github.ump45nose.embyview"
REQ_ENTS = ("com.apple.security.app-sandbox", "com.apple.security.cs.allow-jit", "com.apple.security.network.client",
            "com.apple.security.network.server", "com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope")
CODE_BUNDLE_EXTS, OPT_BUNDLE_EXTS = (".framework", ".xpc", ".appex", ".app"), (".bundle", ".plugin")
MAGICS = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}

def run(cmd, timeout=None, **kw):
    t = 60 if (timeout is None and cmd and cmd[0] == "codesign") else timeout
    if "input" not in kw: kw.setdefault("stdin", subprocess.DEVNULL)
    try: return subprocess.run(cmd, capture_output=True, text=True, timeout=t, **kw)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", f"timed out after {t}s (keychain may be locked or missing codesign partition authorization)")

def keychain_unlocked(kc):
    try:
        sec, ref, st = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security"), ctypes.c_void_p(), ctypes.c_uint32()
        if sec.SecKeychainOpen(kc.encode(), ctypes.byref(ref)) == 0 and sec.SecKeychainGetStatus(ref, ctypes.byref(st)) == 0:
            return bool(st.value & 1)
    except Exception: pass
    return run(["security", "show-keychain-info", kc], timeout=5).returncode == 0

def inspect_cert(pem):
    txt = run(["/usr/bin/openssl", "x509", "-noout", "-enddate", "-text", "-subject"], input=pem).stdout
    m_end, m_cn = re.search(r"notAfter=(.+)", txt), re.search(r"CN\s*=\s*([^,/\n]+)", txt)
    dt = datetime.datetime.strptime(re.sub(r"\s+", " ", m_end.group(1).strip()), "%b %d %H:%M:%S %Y %Z") if m_end else None
    return {"expired": (dt is None or dt <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)), "dt": dt,
            "notAfter": dt.strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None, "cn": m_cn.group(1).strip() if m_cn else None,
            "codeSigning": bool(re.search(r"X509v3 Extended Key Usage:.*\n\s*.*Code Signing", txt))}

def resolve_identity(query, kc, rep):
    r_id = run(["security", "find-identity", "-p", "codesigning", kc])
    if r_id.returncode != 0: return None, f"failed to query keychain {kc}: {(r_id.stderr or r_id.stdout).strip()}", False
    has_key = {h.upper(): n for h, n in re.findall(r'\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', r_id.stdout.split("Valid identities only", 1)[0])}
    is_sha = bool(re.fullmatch(r"[0-9A-Fa-f]{40}", query))
    c_cmd = ["security", "find-certificate", "-a", "-Z", "-p", *([] if is_sha else ["-c", query]), kc]
    certs = {h.upper(): p + "\n" for h, p in re.findall(r"SHA-1 hash:\s*([0-9A-Fa-f]{40}).*?(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)", run(c_cmd).stdout, re.S)}
    valid, bad, last = [], None, None
    for sha1, pem in certs.items():
        if is_sha and sha1 != query.upper(): continue
        m = inspect_cert(pem); name = has_key.get(sha1) or m["cn"] or sha1
        if query not in (name, m["cn"]) and query.upper() != sha1: continue
        last = (sha1, name, m)
        if not m["codeSigning"]: bad = f"certificate '{name}' ({sha1}) lacks Code Signing EKU"
        elif m["expired"]: bad = f"certificate '{name}' ({sha1}) is expired (notAfter={m['notAfter']})"
        elif sha1 not in has_key: bad = f"certificate '{name}' ({sha1}) has no usable private key in keychain"
        else: valid.append((sha1, name, m))
    if valid: return max(valid, key=lambda x: x[2]["dt"] or datetime.datetime.min), None, True
    if last: rep.update(certificateSha1=last[0], identityName=last[1], notAfter=last[2]["notAfter"]); return None, bad, True
    return None, f"persistent code signing identity '{query}' not found in keychain {kc}", False

def is_macho(p):
    try: h = open(p, "rb").read(8); return len(h) >= 4 and h[:4] in MAGICS and not (h[:4] == b"\xca\xfe\xba\xbe" and (len(h) < 8 or struct.unpack(">I", h[4:8])[0] >= 32))
    except OSError: return False

def bundle_main_exec(b):
    exe = None
    for rel in ("Contents/Info.plist", "Resources/Info.plist", "Versions/Current/Resources/Info.plist"):
        if not exe and os.path.isfile(p := os.path.join(b, rel)):
            try: exe = plistlib.load(open(p, "rb")).get("CFBundleExecutable")
            except Exception: pass
    exe = exe or (os.path.basename(b)[:-10] if b.endswith(".framework") else None)
    return next((os.path.realpath(c) for c in ((os.path.join(b, "Contents/MacOS", exe), os.path.join(b, "Versions/Current", exe), os.path.join(b, exe)) if exe else ()) if os.path.exists(c)), None)

def designated_req(p):
    r = run(["codesign", "-d", "-r-", p])
    m = re.search(r"designated\s*=>\s*(.+)", r.stdout) if r.returncode == 0 else None
    return (m.group(1).strip(), None) if m else (None, (r.stderr or r.stdout or "missing requirement").strip())

def main():
    ap = argparse.ArgumentParser(prog="sign-macos.sh")
    ap.add_argument("--ensure-identity", action="store_true")
    for fl in ("--app", "--candidate", "--output", "--previous-app", "--expected-requirement", "--report"): ap.add_argument(fl)
    for fl, df in (("--identity", os.environ["EMBYVIEW_SIGN_IDENTITY"]), ("--keychain", os.environ["EMBYVIEW_SIGN_KEYCHAIN"]),
                   ("--entitlements", os.path.join(os.environ["EMBYVIEW_REPO_ROOT"], "macos/Runner/Release.entitlements"))): ap.add_argument(fl, default=df)
    a = ap.parse_args()
    kc = os.path.expanduser(a.keychain or run(["security", "default-keychain", "-d", "user"]).stdout.strip().strip('"'))
    kc_pass, id_q = os.environ.get("EMBYVIEW_KEYCHAIN_PASSWORD", ""), (a.identity or "").strip()
    rep = {"host": socket.gethostname().split(".")[0], "status": "error", "identityName": id_q, "certificateSha1": None, "certificateValid": False,
           "notAfter": None, "bundleId": BUNDLE_ID, "designatedRequirement": None, "entitlementsVerified": False, "nestedCount": 0,
           "candidateSha256Verified": None, "continuityVerified": None, "appPath": None, "error": None}
    def done(code, st, err=None):
        rep.update(status=st, error=err); out = json.dumps(rep, indent=2, ensure_ascii=False); print(out)
        if a.report: os.makedirs(os.path.dirname(os.path.abspath(a.report)), exist_ok=True); open(a.report, "w", encoding="utf-8").write(out + "\n")
        sys.exit(code)
    def must(cmd, label, st="error", timeout=None):
        if (r := run(cmd, timeout=timeout)).returncode != 0: done(1, "blocked" if r.returncode == 124 else st, f"{label}: {(r.stderr or r.stdout).strip()}")
        return r
    def set_partition():
        if kc_pass: must(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", kc_pass, kc], "set-key-partition-list failed", "blocked", timeout=15)

    if not id_q or id_q == "-": done(1, "blocked", "ad-hoc signing ('-') is prohibited; persistent code signing identity required")
    if not os.path.exists(kc): done(1, "blocked", f"keychain not found: {kc}")
    if kc_pass: must(["security", "unlock-keychain", "-p", kc_pass, kc], "failed to unlock keychain", "blocked", timeout=15)
    found, reason, exists = resolve_identity(id_q, kc, rep)
    if a.ensure_identity:
        if not found:
            if exists: done(1, "blocked", reason)
            if re.fullmatch(r"[0-9A-Fa-f]{40}", id_q): done(1, "blocked", f"cannot generate cert for SHA-1 '{id_q}'")
            if not keychain_unlocked(kc): done(1, "blocked", f"keychain is locked ({kc}); unlock it or provide EMBYVIEW_KEYCHAIN_PASSWORD")
            td = tempfile.mkdtemp(prefix="embyview-sign-gen-")
            try:
                os.chmod(td, 0o700); cnf, key, crt, seq = [os.path.join(td, n) for n in ("o.cnf", "k.pem", "c.pem", "s.pem")]
                open(cnf, "w").write(f"[req]\ndistinguished_name=dn\nx509_extensions=e\nprompt=no\n[dn]\nCN={id_q}\n[e]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n")
                must(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-keyout", key, "-out", crt, "-days", "3650", "-config", cnf], "openssl failed")
                fp_out = must(["/usr/bin/openssl", "x509", "-in", crt, "-noout", "-fingerprint", "-sha1"], "fingerprint failed").stdout
                crt_sha1 = fp_out.split("=")[1].strip().replace(":", "").upper() if "=" in fp_out else ""
                open(seq, "wb").write(open(crt, "rb").read() + open(key, "rb").read()); os.chmod(seq, 0o600)
                if (imp := run(["security", "import", seq, "-k", kc, "-f", "pemseq", "-t", "agg", "-x", "-T", "/usr/bin/codesign"], timeout=30)).returncode != 0:
                    if crt_sha1: run(["security", "delete-certificate", "-Z", crt_sha1, kc], timeout=10)
                    done(1, "blocked", f"security import failed: {(imp.stderr or imp.stdout).strip()}")
            finally: shutil.rmtree(td, ignore_errors=True)
            found, reason, _ = resolve_identity(id_q, kc, rep)
            if not found: done(1, "blocked", reason or "imported identity could not be verified")
        set_partition()
        rep.update(identityName=found[1], certificateSha1=found[0], certificateValid=True, notAfter=found[2]["notAfter"]); done(0, "ok")

    if not found: done(1, "blocked", reason)
    set_partition()
    sha1, name, meta = found
    rep.update(identityName=name, certificateSha1=sha1, certificateValid=True, notAfter=meta["notAfter"])
    if not os.path.isfile(a.entitlements): done(1, "error", f"entitlements not found: {a.entitlements}")
    tmp = tempfile.mkdtemp(prefix="embyview-sign-work-")
    try:
        src, unpacked = a.app, False
        if a.candidate:
            if not os.path.isfile(a.candidate): done(1, "error", f"candidate not found: {a.candidate}")
            cand, base = json.load(open(a.candidate, encoding="utf-8")), os.path.dirname(os.path.abspath(a.candidate))
            res = lambda p: p if os.path.isabs(p) else os.path.normpath(os.path.join(base, p))
            arch = res(cand["archivePath"]) if cand.get("archivePath") else None
            if arch and cand.get("archiveSha256"):
                if not os.path.isfile(arch): rep["candidateSha256Verified"] = False; done(1, "blocked", f"archive not found: {arch}")
                h = hashlib.sha256()
                with open(arch, "rb") as f:
                    while ch := f.read(1 << 20): h.update(ch)
                if h.hexdigest().lower() != cand["archiveSha256"].strip().lower(): rep["candidateSha256Verified"] = False; done(1, "blocked", "candidate archive SHA-256 mismatch")
                rep["candidateSha256Verified"] = True
            if not src:
                if cand.get("appPath") and os.path.isdir(res(cand["appPath"])): src = res(cand["appPath"])
                elif arch and os.path.isfile(arch):
                    ud = os.path.join(tmp, "unpacked"); os.makedirs(ud)
                    must(["ditto", "-x", "-k", arch, ud] if arch.endswith(".zip") else ["tar", "-xzf", arch, "-C", ud], "unpack failed")
                    apps = sorted([os.path.join(dp, d) for dp, ds, _ in os.walk(ud) for d in ds if d.endswith(".app")], key=lambda p: (os.path.basename(p) != "EmbyView.app", p.count(os.sep)))
                    if not apps: done(1, "error", f"no .app bundle found in {arch}")
                    src, unpacked = apps[0], True
        if not src or not os.path.isdir(src): done(1, "error", "source .app bundle missing")
        if unpacked and not a.output: done(1, "error", "--output is required when unpacking candidate archive")
        target = src
        if a.output and os.path.realpath(a.output) != os.path.realpath(src):
            if os.path.exists(a.output): shutil.rmtree(a.output)
            os.makedirs(os.path.dirname(os.path.abspath(a.output)), exist_ok=True)
            must(["ditto", src, a.output], "ditto failed"); target = a.output
        rep["appPath"] = os.path.abspath(target)
        bundles, machos = [], []
        for dp, ds, fs in os.walk(os.path.join(target, "Contents"), followlinks=False):
            ds[:] = [d for d in ds if d != "_CodeSignature" and not os.path.islink(os.path.join(dp, d))]
            for d in ds:
                bp = os.path.join(dp, d)
                if d.endswith(CODE_BUNDLE_EXTS) or (d.endswith(OPT_BUNDLE_EXTS) and (ex := bundle_main_exec(bp)) and is_macho(ex)): bundles.append(bp)
            machos.extend(fp for fn in fs if not os.path.islink(fp := os.path.join(dp, fn)) and is_macho(fp))
        skip = {e for e in [bundle_main_exec(target), *(bundle_main_exec(b) for b in bundles)] if e}
        items = sorted([m for m in machos if os.path.realpath(m) not in skip], key=lambda p: p.count(os.sep), reverse=True) + sorted(bundles, key=lambda p: p.count(os.sep), reverse=True)
        base_cs = ["codesign", "--sign", sha1, "--keychain", kc, "--force", "--timestamp=none"]
        for it in items: must([*base_cs, "--preserve-metadata=entitlements", it], f"codesign failed on {it}")
        rep["nestedCount"] = len(items)
        must([*base_cs, "--identifier", BUNDLE_ID, "--entitlements", a.entitlements, target], "codesign failed on main app")
        must(["codesign", "--verify", "--deep", "--strict", "--verbose=2", target], "codesign verify failed")
        dv = run(["codesign", "-dvvv", target]).stderr
        if not (id_m := re.search(r"^Identifier=(.+)$", dv, re.M)) or id_m.group(1).strip() != BUNDLE_ID: done(1, "error", f"unexpected Identifier: {id_m.group(1).strip() if id_m else 'missing'}")
        if "Signature=adhoc" in dv or not re.search(r"^Authority=.+", dv, re.M): done(1, "blocked", "signed app is ad-hoc or lacks Authority")
        cp = os.path.join(tmp, "cert")
        must(["codesign", "-d", f"--extract-certificates={cp}", target], "extract leaf certificate failed")
        fp = must(["/usr/bin/openssl", "x509", "-inform", "DER", "-in", cp + "0", "-noout", "-fingerprint", "-sha1"], "fingerprint failed").stdout
        if (fp.split("=")[1].strip().replace(":", "").upper() if "=" in fp else "") != sha1: done(1, "blocked", "signed certificate SHA-1 mismatch")
        ent_out = must(["codesign", "-d", "--entitlements", "-", "--xml", target], "read entitlements failed").stdout
        if (miss := [k for k in REQ_ENTS if plistlib.loads(ent_out.encode()).get(k) is not True]): done(1, "error", f"missing required entitlements: {', '.join(miss)}")
        rep["entitlementsVerified"] = True
        req, rerr = designated_req(target)
        if not req: done(1, "error", f"read designated requirement failed: {rerr}")
        rep["designatedRequirement"] = req
        checks = [re.sub(r"^(?:designated\s*=>\s*|=)", "", a.expected_requirement.strip())] if a.expected_requirement else []
        if a.previous_app:
            pr, perr = designated_req(a.previous_app)
            if not pr: rep["continuityVerified"] = False; done(1, "error", f"read previous app requirement failed: {perr}")
            checks.insert(0, pr)
        for exp in checks:
            if (tr := run(["codesign", "--verify", "--strict", f"--test-requirement=={exp}", target])).returncode != 0:
                rep["continuityVerified"] = False; done(1, "blocked", f"continuity check failed: {(tr.stderr or tr.stdout).strip()}")
        if checks: rep["continuityVerified"] = True
        done(0, "ok")
    finally: shutil.rmtree(tmp, ignore_errors=True)
main()
PY
