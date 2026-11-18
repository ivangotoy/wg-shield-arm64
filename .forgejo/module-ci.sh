#!/usr/bin/env bash
# Generic KernelSU module release pipeline (identical in every module repo).
#
#   module-ci.sh build <workdir>    no forge token: merge upstream, build the zip
#                                   (the build runs as an unprivileged user)
#   module-ci.sh release <workdir>  forge token: version + updateJson into the zip,
#                                   draft -> upload -> download back and verify ->
#                                   push merge -> publish -> commit update.json
# The release step runs this script and the config as fetched from the dispatched
# commit, never the copies in the build workspace. Any failure before publish
# deletes the draft and pushes nothing.
#
# Per-repo settings: .forgejo/module-ci.conf (sourced shell)
#   UPSTREAM_URL, UPSTREAM_BRANCH   upstream merged into main ("" = none)
#   ZIP_PREFIX                      release zip name prefix
#   VERSION_CODE_FLOOR              lowest versionCode allowed to release
#   VERSION_CODE_OFFSET             added to the built versionCode (default 0)
#   UPDATE_JSON_PATH                update.json path in main (default .forgejo/update.json)
#   SYNC_ROOT_PROP                  fork-owned module.prop in main kept at the released version
#   CHANGELOG_PATH                  changelog file in the tree ("" = none)
#   build()                         runs in the tree, leaves the module zip at "$OUT/module.zip"
#   prebuilt()                      instead of merge + build: puts an upstream release zip at
#                                   "$OUT/module.zip" and a one-line source note in "$OUT/upstream-desc"
#   release_files()                 optional, release step: writes extra fork-only files for the
#                                   update.json commit (in-app update feeds) and lists them in
#                                   RELEASE_FILES; sees VERSION VC TAG ZIP_NAME ZIP_URL ZIP_SHA ZIP_SIZE
#                                   BUILT_VERSION SRC_SHA BODY CHANGELOG_URL UPDATE_URL
set -euo pipefail

MODE="${1:?mode}"; WORK="$(cd "${2:?workdir}" && pwd)"
: "${SERVER_URL:?}" "${REPOSITORY:?}" "${BASE_SHA:?}"
BUILD_UID=1000
OUT="$WORK/.ci-out"
export GIT_AUTHOR_NAME="Ivan Angelov" GIT_AUTHOR_EMAIL="ivangotoy@gmail.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
prop_get() { sed -n "s/^$1=//p" "$2" | head -n1 | tr -d '\r'; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
jget() { python3 -I -c 'import json,sys;d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[int(k)] if k.isdigit() else d[k]
print(d)' "$1"; }
pack_paths() { (cd "$WORK" && zip -qr9 -X "$OUT/module.zip" "$@" -x '*/.gitkeep'); }
load_conf() {
    UPSTREAM_URL="" UPSTREAM_BRANCH="" ZIP_PREFIX="${REPOSITORY#*/}" VERSION_CODE_FLOOR=0 VERSION_CODE_OFFSET=0
    UPDATE_JSON_PATH=".forgejo/update.json" SYNC_ROOT_PROP="" CHANGELOG_PATH=""
    . "$1"
}

if [ "$MODE" = build-user ]; then
    # unprivileged part of the build step
    cd "$WORK"; load_conf .forgejo/module-ci.conf
    if declare -F prebuilt >/dev/null; then prebuilt; else build; fi
    exit 0
fi

if [ "$MODE" = build ]; then
    cd "$WORK"; load_conf .forgejo/module-ci.conf
    rm -rf "$OUT"; mkdir -p "$OUT"
    git checkout -q -B main "$BASE_SHA"
    printf '.ci-out/\n.ci-home/\n' >> .git/info/exclude
    SRC_SHA="$BASE_SHA" UP_SHA="" DESC=""
    if ! declare -F prebuilt >/dev/null && [ -n "$UPSTREAM_URL" ]; then
        log "merging $UPSTREAM_URL $UPSTREAM_BRANCH"
        git fetch -q "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
        UP_SHA="$(git rev-parse FETCH_HEAD)"
        UP_NAME="${UPSTREAM_URL#https://github.com/}"; UP_NAME="${UP_NAME%.git}"
        if git merge-base --is-ancestor "$UP_SHA" HEAD; then
            log "upstream $UP_SHA already merged"
        else
            git merge -q --no-ff --no-edit -m "Merge $UP_NAME $UPSTREAM_BRANCH ${UP_SHA:0:12}" "$UP_SHA" \
                || die "merge conflict with upstream $UP_SHA: resolve by hand"
        fi
        SRC_SHA="$(git rev-parse HEAD)"
        DESC="$UP_NAME@$UPSTREAM_BRANCH ${UP_SHA:0:12}"
        [ "$SRC_SHA" = "$BASE_SHA" ] || git bundle create -q "$OUT/merge.bundle" "$BASE_SHA..main"
    fi
    printf '%s\n%s\n' "$SRC_SHA" "$UP_SHA" > "$OUT/src"
    mkdir -p "$WORK/.ci-home"
    chown -R "$BUILD_UID:$BUILD_UID" "$WORK" "$OUT"
    log "building $SRC_SHA as uid $BUILD_UID"
    env -i PATH="$PATH" HOME="$WORK/.ci-home" LANG=C.UTF-8 GRADLE_USER_HOME=/ci/gradle \
        JAVA_HOME="${JAVA_HOME:-}" JAVA_HOME_21="${JAVA_HOME_21:-}" JAVA_HOME_26="${JAVA_HOME_26:-}" \
        ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk \
        SIGN_KEYSTORE_B64="${SIGN_KEYSTORE_B64:-}" SIGN_KEY_ALIAS="${SIGN_KEY_ALIAS:-}" \
        SIGN_STORE_PASSWORD="${SIGN_STORE_PASSWORD:-}" SIGN_KEY_PASSWORD="${SIGN_KEY_PASSWORD:-}" \
        SERVER_URL="$SERVER_URL" REPOSITORY="$REPOSITORY" BASE_SHA="$BASE_SHA" OUT="$OUT" \
        setpriv --reuid="$BUILD_UID" --regid="$BUILD_UID" --clear-groups \
        bash "$WORK/.forgejo/module-ci.sh" build-user "$WORK" || die "build failed"
    setpriv --reuid="$BUILD_UID" --regid="$BUILD_UID" --clear-groups kill -9 -1 2>/dev/null || true
    [ -f "$OUT/module.zip" ] || die "build left no $OUT/module.zip"
    [ -f "$OUT/upstream-desc" ] && DESC="$(head -n1 "$OUT/upstream-desc")"
    printf '%s\n' "$DESC" > "$OUT/desc"
    log "build done"
    exit 0
fi

[ "$MODE" = release ] || die "unknown mode $MODE"
: "${RELEASE_TOKEN:?}" "${RUN_NUMBER:?}"
API="$SERVER_URL/api/v1/repos/$REPOSITORY"
auth() { printf 'Authorization: token %s' "$RELEASE_TOKEN"; }
api() { local m="$1" p="$2"; shift 2; curl -sS --fail-with-body --retry 3 -X "$m" -H "$(auth)" "$@" "$API$p"; }
http_code() { curl -sS -o /dev/null -w '%{http_code}' -H "$(auth)" "$API$1"; }
git_auth() { git -c "http.extraHeader=$(auth)" "$@"; }

REL="$(pwd)/rel"
rm -rf "$REL"; mkdir -p "$REL"
git_auth clone -q --branch main "$SERVER_URL/$REPOSITORY.git" "$REL/repo"
cd "$REL/repo"
git cat-file -e "$BASE_SHA^{commit}" || die "base $BASE_SHA not in main"
git show "$BASE_SHA:.forgejo/module-ci.conf" > "$REL/module-ci.conf"
load_conf "$REL/module-ci.conf"

# build results are data owned by the build user: regular files only, checked before use
regular() { [ -f "$1" ] && [ ! -L "$1" ] || die "$1 is not a regular file"; }
regular "$OUT/src"; regular "$OUT/desc"; regular "$OUT/module.zip"
{ read -r SRC_SHA; read -r UP_SHA; } < "$OUT/src"
DESC="$(head -c 200 "$OUT/desc" | head -n1 | tr -cd '[:print:]')"
[[ "$SRC_SHA" =~ ^[0-9a-f]{40}$ ]] || die "bad source sha"
if [ "$SRC_SHA" != "$BASE_SHA" ]; then
    [[ "$UP_SHA" =~ ^[0-9a-f]{40}$ ]] || die "bad upstream sha"
    git fetch -q "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
    git merge-base --is-ancestor "$UP_SHA" FETCH_HEAD || die "$UP_SHA is not on upstream $UPSTREAM_BRANCH"
    regular "$OUT/merge.bundle"
    git fetch -q "$OUT/merge.bundle" "main:refs/ci/merge"
    [ "$(git rev-parse refs/ci/merge)" = "$SRC_SHA" ] || die "bundle tip differs from the built sha"
    [ "$(git rev-parse "$SRC_SHA^1") $(git rev-parse "$SRC_SHA^2")" = "$BASE_SHA $UP_SHA" ] || die "merge parents differ"
    [ "$(git merge-tree --write-tree "$BASE_SHA" "$UP_SHA")" = "$(git rev-parse "$SRC_SHA^{tree}")" ] || die "merge tree differs"
    [ -z "$(git log --format=%B -1 "$SRC_SHA" | grep -iE 'co-authored|generated')" ] || die "trailer in merge message"
fi
cp "$OUT/module.zip" "$REL/module.zip"

# version and updateJson inside the zip
unzip -p "$REL/module.zip" module.prop > "$REL/built.prop" || die "zip has no module.prop at its root"
BUILT_VERSION="$(prop_get version "$REL/built.prop")"
BUILT_VC="$(prop_get versionCode "$REL/built.prop")"
case "$BUILT_VC" in ''|*[!0-9]*) die "built versionCode '$BUILT_VC' is not a number" ;; esac
VERSION="$(printf '%s' "$BUILT_VERSION" | sed -E 's/-(fork|ci)[0-9]+$//')-ci$RUN_NUMBER"
VC=$((BUILT_VC + VERSION_CODE_OFFSET))
[ "$VC" -ge "$VERSION_CODE_FLOOR" ] || die "versionCode $VC is below the floor $VERSION_CODE_FLOOR"
TAG="$(printf '%s' "$VERSION" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
case "$TAG" in v*) ;; *) TAG="v$TAG" ;; esac
ZIP_NAME="$ZIP_PREFIX-$TAG.zip"
UPDATE_URL="$SERVER_URL/$REPOSITORY/raw/branch/main/$UPDATE_JSON_PATH"
ZIP_URL="$SERVER_URL/$REPOSITORY/releases/download/$TAG/$ZIP_NAME"
CHANGELOG_URL=""
if [ -n "$CHANGELOG_PATH" ] && git cat-file -e "$SRC_SHA:$CHANGELOG_PATH" 2>/dev/null; then
    CHANGELOG_URL="$SERVER_URL/$REPOSITORY/raw/commit/$SRC_SHA/$CHANGELOG_PATH"
fi
log "version $VERSION versionCode $VC tag $TAG"

python3 -I - "$REL/module.zip" "$REL/$ZIP_NAME" "$VERSION" "$VC" "$UPDATE_URL" <<'PY'
import hashlib, sys, zipfile
src, dst, version, vc, url = sys.argv[1:]
zin = zipfile.ZipFile(src)
lines, seen = [], set()
for line in zin.read("module.prop").decode().splitlines():
    k = line.split("=", 1)[0]
    if k in ("version", "versionCode", "updateJson"):
        if k in seen:
            continue
        seen.add(k)
        line = f"{k}=" + {"version": version, "versionCode": vc, "updateJson": url}[k]
    lines.append(line)
for k, v in (("version", version), ("versionCode", vc), ("updateJson", url)):
    if k not in seen:
        lines.append(f"{k}={v}")
prop = ("\n".join(lines) + "\n").encode()
# install-time checks that pin module.prop (module.prop.sha256, verify scripts listing
# its sha256) are updated by replacing the old hash wherever an entry holds it
old_h = hashlib.sha256(zin.read("module.prop")).hexdigest().encode()
new_h = hashlib.sha256(prop).hexdigest().encode()
with zipfile.ZipFile(dst, "w") as zout:
    for info in zin.infolist():
        data = zin.read(info)
        if info.filename == "module.prop":
            data = prop
        elif old_h in data:
            data = data.replace(old_h, new_h)
            print(f"==> module.prop hash updated in {info.filename}", file=sys.stderr)
        zi = zipfile.ZipInfo(info.filename, info.date_time)
        zi.compress_type, zi.external_attr, zi.create_system = info.compress_type, info.external_attr, info.create_system
        zout.writestr(zi, data, compresslevel=9 if info.compress_type == zipfile.ZIP_DEFLATED else None)
# every <file>.sha256 entry must hold the hash of <file>
z = zipfile.ZipFile(dst)
names = set(z.namelist())
for n in names:
    if n != "module.prop" and old_h != new_h and old_h in z.read(n):
        sys.exit(f"{n} still holds the old module.prop hash")
for n in names:
    if n.endswith(".sha256") and n[:-7] in names:
        want = z.read(n).decode().split()[0].strip()
        got = hashlib.sha256(z.read(n[:-7])).hexdigest()
        if want != got:
            sys.exit(f"sidecar {n} does not match {n[:-7]}")
PY
ZIP="$REL/$ZIP_NAME"
unzip -tq "$ZIP" >/dev/null || die "zip test failed"
[ "$(unzip -p "$ZIP" module.prop | prop_get updateJson /dev/stdin)" = "$UPDATE_URL" ] || die "updateJson not set"
ZIP_SHA="$(sha "$ZIP")"
log "zip $ZIP_NAME sha256 $ZIP_SHA"

RELEASE_ID="" PUBLISHED=0
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$RELEASE_ID" ] && [ "$PUBLISHED" != 1 ]; then
        log "failure before publish: deleting draft release $RELEASE_ID"
        api DELETE "/releases/$RELEASE_ID" >/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT

# draft release, upload, download back, verify
[ "$(http_code "/releases/tags/$TAG")" = 404 ] || die "release $TAG exists (or the check failed)"
[ "$(http_code "/tags/$TAG")" = 404 ] || die "tag $TAG exists (or the check failed)"
BODY="$(printf 'Built by module-release #%s from %s (%s).\nversionCode %s\nsha256 %s  %s\nupdateJson %s' \
    "$RUN_NUMBER" "${SRC_SHA:0:12}" "${DESC:-fork main}" "$VC" "$ZIP_SHA" "$ZIP_NAME" "$UPDATE_URL")"
REQ="$(python3 -I -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"target_commitish":"main","name":sys.argv[2],"body":sys.argv[3],"draft":True}))' "$TAG" "$ZIP_PREFIX $VERSION" "$BODY")"
RELEASE_ID="$(api POST /releases -H 'Content-Type: application/json' -d "$REQ" | jget id)"
log "draft release $RELEASE_ID, uploading $ZIP_NAME"
ASSET_ID="$(api POST "/releases/$RELEASE_ID/assets?name=$ZIP_NAME" -F "attachment=@$ZIP" | jget id)"
ASSET_URL="$(api GET "/releases/$RELEASE_ID/assets/$ASSET_ID" | jget browser_download_url)"
log "downloading back $ASSET_URL"
curl -sSL --fail-with-body -H "$(auth)" -o "$REL/back.zip" "$ASSET_URL"
[ "$(sha "$REL/back.zip")" = "$ZIP_SHA" ] || die "downloaded asset sha256 differs"
unzip -tq "$REL/back.zip" >/dev/null || die "downloaded asset fails zip test"

# push the merge (fast-forward only), publish at the built commit
if [ "$SRC_SHA" != "$BASE_SHA" ]; then
    log "pushing merge $SRC_SHA"
    git_auth push -q origin "$SRC_SHA:refs/heads/main" || die "push of the merge failed (main moved?)"
fi
REQ="$(python3 -I -c 'import json,sys;print(json.dumps({"draft":False,"target_commitish":sys.argv[1]}))' "$SRC_SHA")"
api PATCH "/releases/$RELEASE_ID" -H 'Content-Type: application/json' -d "$REQ" >/dev/null
PUBLISHED=1
TAG_SHA="$(api GET "/tags/$TAG" | jget commit.sha)"
[ "$TAG_SHA" = "$SRC_SHA" ] || die "published tag $TAG points at $TAG_SHA, expected $SRC_SHA"
for i in 1 2 3 4 5; do curl -fsSL -o "$REL/anon.zip" "$ZIP_URL" && break; sleep 5; done
[ "$(sha "$REL/anon.zip")" = "$ZIP_SHA" ] || die "anonymous download of $ZIP_URL differs"
log "published $TAG"

# update.json (and the fork-owned module.prop) in main
git_auth fetch -q origin main
git checkout -q -B main FETCH_HEAD
mkdir -p "$(dirname "$UPDATE_JSON_PATH")"
python3 -I - "$UPDATE_JSON_PATH" "$VERSION" "$VC" "$ZIP_URL" "$CHANGELOG_URL" <<'PY'
import json, sys
path, version, vc, zip_url, changelog = sys.argv[1:]
with open(path, "w") as f:
    f.write(json.dumps({"version": version, "versionCode": int(vc), "zipUrl": zip_url, "changelog": changelog}, indent=2) + "\n")
PY
git add -- "$UPDATE_JSON_PATH"
if declare -F release_files >/dev/null; then
    RELEASE_FILES="" ZIP_SIZE="$(stat -c %s "$ZIP")"
    release_files
    for f in $RELEASE_FILES; do git add -- "$f"; done
fi
if [ -n "$SYNC_ROOT_PROP" ]; then
    sed -i -E "s|^version=.*|version=$VERSION|; s|^versionCode=.*|versionCode=$VC|; s|^updateJson=.*|updateJson=$UPDATE_URL|" "$SYNC_ROOT_PROP"
    git add -- "$SYNC_ROOT_PROP"
fi
git commit -q -m "update.json: $VERSION (versionCode $VC)"
git_auth push -q origin HEAD:refs/heads/main || die "push of update.json failed"
got=""
for i in 1 2 3 4 5; do
    got="$(curl -fsS "$UPDATE_URL" | jget versionCode || true)"
    [ "$got" = "$VC" ] && break; sleep 5
done
[ "$got" = "$VC" ] || die "$UPDATE_URL answers versionCode '$got', expected $VC"
log "done: $UPDATE_URL -> $TAG"
