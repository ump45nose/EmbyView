#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SOURCE="auto"
CI_RUN_ID=""
OUTPUT_DIR="build/embyview-release"
EXPECTED_COMMIT=""
SKIP_BUILD=0
ALLOW_SDK_MISMATCH=0

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --ci-run-id) CI_RUN_ID="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --commit) EXPECTED_COMMIT="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --allow-sdk-mismatch) ALLOW_SDK_MISMATCH=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--source local|ci|auto] [--ci-run-id <id>] [--output-dir <dir>] [--commit <sha>] [--skip-build] [--allow-sdk-mismatch]"
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$SOURCE" =~ ^(local|ci|auto)$ ]] || die "Invalid --source '$SOURCE' (expected local, ci, or auto)"

HEAD_COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="$(git rev-parse --short HEAD)"
APP_VERSION="$(sed -nE 's/^version:[[:space:]]*([^[:space:]+]+).*/\1/p' pubspec.yaml | head -n 1)"
[[ -n "$APP_VERSION" ]] || die "Failed to parse version from pubspec.yaml"
if [[ -n "$EXPECTED_COMMIT" ]]; then
  RESOLVED_COMMIT="$(git rev-parse --verify "${EXPECTED_COMMIT}^{commit}")" || die "Unknown commit: $EXPECTED_COMMIT"
  [[ "$HEAD_COMMIT" == "$RESOLVED_COMMIT" ]] || die "HEAD ($HEAD_COMMIT) != expected commit ($RESOLVED_COMMIT)"
fi

if [[ "$SOURCE" == "auto" ]]; then
  EFFECTIVE_SOURCE="$([[ -n "$CI_RUN_ID" ]] && echo ci || echo local)"
else
  EFFECTIVE_SOURCE="$SOURCE"
fi

LOCKFILES=(pubspec.lock macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved macos/Packages/Whisper/Package.swift)
check_lockfiles() {
  git diff HEAD --exit-code -- "${LOCKFILES[@]}" >/dev/null || die "Lockfile drift detected in: ${LOCKFILES[*]}"
}
rm_tree() { python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$1"; }

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_PATH="$OUTPUT_DIR/EmbyView.app"
ARCHIVE_NAME="EmbyView-macos-arm64-unsigned.zip"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
SUMS_PATH="$OUTPUT_DIR/SHA256SUMS"
MANIFEST_PATH="$OUTPUT_DIR/release-candidate.json"

package_archive() {
  rm -f "$ARCHIVE_PATH" "$SUMS_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
  (cd "$OUTPUT_DIR" && shasum -a 256 "$ARCHIVE_NAME" > SHA256SUMS)
}

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  if [[ "$EFFECTIVE_SOURCE" == "ci" ]]; then
    if [[ -z "$CI_RUN_ID" ]]; then
      CI_RUN_ID="$(gh run list --workflow build.yml --commit "$HEAD_COMMIT" --status success --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
      [[ -n "$CI_RUN_ID" ]] || die "No successful build.yml CI run for $HEAD_COMMIT (pass --ci-run-id or --source local)"
    fi
    RUN_INFO="$(gh run view "$CI_RUN_ID" --json headSha,conclusion --jq '[.headSha, .conclusion] | @tsv')" || die "Failed to inspect CI run $CI_RUN_ID"
    IFS=$'\t' read -r RUN_SHA RUN_CONC <<< "$RUN_INFO"
    [[ "$RUN_CONC" == "success" ]] || die "CI run $CI_RUN_ID conclusion is '${RUN_CONC:-unknown}', expected 'success'"
    [[ "$RUN_SHA" == "$HEAD_COMMIT" ]] || die "CI run $CI_RUN_ID commit ($RUN_SHA) != HEAD ($HEAD_COMMIT)"
    STAGE_DIR="$(mktemp -d)"
    trap 'rm_tree "$STAGE_DIR"' EXIT
    gh run download "$CI_RUN_ID" -n macos-release-arm64-unsigned -D "$STAGE_DIR"
    [[ -f "$STAGE_DIR/$ARCHIVE_NAME" && -f "$STAGE_DIR/SHA256SUMS" ]] || die "CI artifact missing $ARCHIVE_NAME or SHA256SUMS"
    sed -E "s|^([0-9a-fA-F]{64}[[:space:]]+\*?)([^[:space:]]*/)?(${ARCHIVE_NAME})\$|\1\3|" "$STAGE_DIR/SHA256SUMS" > "$STAGE_DIR/SHA256SUMS.norm"
    grep -qE "^[0-9a-fA-F]{64}[[:space:]]+\*?${ARCHIVE_NAME}\$" "$STAGE_DIR/SHA256SUMS.norm" || die "CI SHA256SUMS missing entry for $ARCHIVE_NAME"
    (cd "$STAGE_DIR" && shasum -a 256 -c SHA256SUMS.norm >/dev/null) || die "CI artifact SHA256SUMS verification failed"
    mkdir -p "$STAGE_DIR/unpacked"
    ditto -x -k "$STAGE_DIR/$ARCHIVE_NAME" "$STAGE_DIR/unpacked"
    [[ -d "$STAGE_DIR/unpacked/EmbyView.app" ]] || die "CI archive missing EmbyView.app (build.yml may still package Moonfin.app)"
    rm_tree "$APP_PATH"
    ditto "$STAGE_DIR/unpacked/EmbyView.app" "$APP_PATH"
    cp "$STAGE_DIR/$ARCHIVE_NAME" "$ARCHIVE_PATH"
    cp "$STAGE_DIR/SHA256SUMS.norm" "$SUMS_PATH"
  else
    DERIVED_DATA="$ROOT_DIR/build/macos"
    SPM_SOURCE_DIR="$DERIVED_DATA/SourcePackages"
    SPM_CACHE_DIR="${EMBYVIEW_SPM_CACHE_DIR:-$HOME/Library/Caches/org.swift.swiftpm}"
    mkdir -p "$SPM_SOURCE_DIR" "$SPM_CACHE_DIR"

    if ! flutter pub get --enforce-lockfile; then
      if [[ "$ALLOW_SDK_MISMATCH" -eq 1 && -f .dart_tool/package_config.json ]]; then
        echo "WARN: flutter pub get --enforce-lockfile failed; --allow-sdk-mismatch enabled, reusing existing .dart_tool/package_config.json" >&2
      else
        die "flutter pub get --enforce-lockfile failed (pass --allow-sdk-mismatch only to reuse existing .dart_tool/package_config.json)"
      fi
    fi

    flutter build macos --release --config-only --no-pub \
      --dart-define="EMBYVIEW_VERSION=${APP_VERSION}" \
      --dart-define="EMBYVIEW_COMMIT=${SHORT_COMMIT}"
    check_lockfiles

    xcodebuild -resolvePackageDependencies \
      -workspace macos/Runner.xcworkspace \
      -scheme Runner \
      -clonedSourcePackagesDirPath "$SPM_SOURCE_DIR" \
      -packageCachePath "$SPM_CACHE_DIR" \
      -onlyUsePackageVersionsFromResolvedFile
    check_lockfiles

    xcodebuild build \
      -workspace macos/Runner.xcworkspace \
      -scheme Runner \
      -configuration Release \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$DERIVED_DATA" \
      -clonedSourcePackagesDirPath "$SPM_SOURCE_DIR" \
      -packageCachePath "$SPM_CACHE_DIR" \
      -disableAutomaticPackageResolution \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
      COMPILER_INDEX_STORE_ENABLE=NO
    check_lockfiles

    BUILT_APP="$DERIVED_DATA/Build/Products/Release/EmbyView.app"
    [[ -d "$BUILT_APP" ]] || die "Expected Release app not found at $BUILT_APP"
    rm_tree "$APP_PATH"
    ditto "$BUILT_APP" "$APP_PATH"
    package_archive
  fi
else
  [[ -d "$APP_PATH" ]] || die "--skip-build requires existing $APP_PATH"
  [[ -f "$ARCHIVE_PATH" ]] || package_archive
  [[ -f "$SUMS_PATH" ]] || (cd "$OUTPUT_DIR" && shasum -a 256 "$ARCHIVE_NAME" > SHA256SUMS)
fi

check_lockfiles
[[ -x "$APP_PATH/Contents/MacOS/EmbyView" ]] || die "Missing executable: $APP_PATH/Contents/MacOS/EmbyView"
lipo "$APP_PATH/Contents/MacOS/EmbyView" -verify_arch arm64 || die "EmbyView binary is not arm64"
(cd "$OUTPUT_DIR" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "SHA256SUMS verification failed"

python3 - "$ROOT_DIR" "$APP_PATH" "$ARCHIVE_PATH" "$MANIFEST_PATH" "$EFFECTIVE_SOURCE" "$CI_RUN_ID" "$HEAD_COMMIT" "$SHORT_COMMIT" <<'PY'
import datetime, hashlib, json, pathlib, plistlib, re, subprocess, sys

root, app, archive, manifest = map(pathlib.Path, sys.argv[1:5])
source, ci_run_id, commit, short_commit = sys.argv[5:9]

def sha256(p: pathlib.Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

m = re.search(r"^version:\s*([^\s+]+)\+([^\s]+)\s*$", (root / "pubspec.yaml").read_text("utf-8"), re.M)
if not m:
    fail("Failed to parse version from pubspec.yaml")
expected_version, expected_build = m.group(1), m.group(2)

info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
for key, exp in {
    "CFBundleName": "EmbyView",
    "CFBundleIdentifier": "io.github.ump45nose.embyview",
    "CFBundleExecutable": "EmbyView",
    "CFBundleShortVersionString": expected_version,
    "CFBundleVersion": expected_build,
}.items():
    if info.get(key) != exp:
        fail(f"Info.plist {key}={info.get(key)!r}, expected {exp!r}")

fw_dir = app / "Contents/Frameworks"
flutter_fw, app_fw, whisper_fw = fw_dir / "FlutterMacOS.framework", fw_dir / "App.framework", fw_dir / "whisper.framework"
aether_fws = sorted(fw_dir.glob("Aether*.framework"))
for name, p in [("FlutterMacOS.framework", flutter_fw), ("App.framework", app_fw), ("whisper.framework", whisper_fw)]:
    if not p.is_dir():
        fail(f"Missing embedded {name}")
if not aether_fws:
    fail("Missing embedded Aether*.framework")

flutter_info = plistlib.loads((flutter_fw / "Resources/Info.plist").read_bytes())
if flutter_info.get("BuildMode") != "release":
    fail(f"FlutterMacOS BuildMode={flutter_info.get('BuildMode')!r}, expected 'release'")
if (app_fw / "Resources/flutter_assets/kernel_blob.bin").exists():
    fail("App.framework contains Debug kernel_blob.bin")
if not (app_fw / "Resources/flutter_assets/AssetManifest.bin").exists():
    fail("App.framework missing flutter_assets/AssetManifest.bin")

def fw_binary(fw: pathlib.Path) -> pathlib.Path:
    for rel in ("Resources/Info.plist", "Versions/Current/Resources/Info.plist"):
        if (p := fw / rel).is_file():
            if exe := plistlib.loads(p.read_bytes()).get("CFBundleExecutable"):
                return fw / exe
    return fw / fw.stem

for bin_path in [flutter_fw / "FlutterMacOS", app_fw / "App", whisper_fw / "whisper", *(fw_binary(p) for p in aether_fws)]:
    if not bin_path.exists():
        fail(f"Missing framework binary: {bin_path}")
    subprocess.run(["lipo", str(bin_path), "-verify_arch", "arm64"], check=True)
nm_out = subprocess.check_output(["nm", "-gU", str(app_fw / "App")], text=True)
if "_kDartSnapshotText" not in nm_out and "_kDartVmSnapshotInstructions" not in nm_out:
    fail("App.framework missing AOT Dart snapshot symbols")
otool_out = subprocess.check_output(["otool", "-L", str(app / "Contents/MacOS/EmbyView")], text=True)
if "whisper.framework" not in otool_out:
    fail("EmbyView executable does not link whisper.framework")

data = {
    "schemaVersion": 1,
    "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": source,
    "ciRunId": ci_run_id or None,
    "commit": commit,
    "shortCommit": short_commit,
    "productName": info["CFBundleName"],
    "bundleId": info["CFBundleIdentifier"],
    "version": info["CFBundleShortVersionString"],
    "buildNumber": info["CFBundleVersion"],
    "arch": "arm64",
    "configuration": "Release",
    "appPath": str(app),
    "archivePath": str(archive),
    "archiveSha256": sha256(archive),
    "dependencies": {
        "pubspecLockSha256": sha256(root / "pubspec.lock"),
        "packageResolvedSha256": sha256(root / "macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
        "whisperPackageSha256": sha256(root / "macos/Packages/Whisper/Package.swift"),
        "lockfilesClean": True,
    },
    "embedded": {
        "executable": "Contents/MacOS/EmbyView",
        "aetherFrameworks": [str(p.relative_to(app)) for p in aether_fws],
        "whisperFramework": str(whisper_fw.relative_to(app)),
        "flutterFramework": str(flutter_fw.relative_to(app)),
        "appFramework": str(app_fw.relative_to(app)),
    },
}
manifest.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"Verified Release candidate: {app} -> {manifest}")
PY
