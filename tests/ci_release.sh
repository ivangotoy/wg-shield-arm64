#!/usr/bin/env bash
# WG Shield Arm64 - offline check of the release pipeline (.forgejo/module-ci.sh).
#
#   bash tests/ci_release.sh SCRIPT DIR [TREE]
#
# Runs SCRIPT (module-ci.sh) in release mode against a fake forge: curl is a
# stub that answers the forge API, git is the real one on a local bare repo
# (the forge URL is mapped to it with url.<path>.insteadOf), the token is
# made up, nothing leaves the machine. DIR is a scratch folder (emptied).
# Prints one line per scenario, "<scenario>: <results>"; tests/harness.sh
# compares them.
#   upload_fail   the asset upload fails while the release is a draft
#   patch_lost    the publish PATCH is applied, its reply is lost
#   ok            the whole run: draft, upload, check, publish, update.json
#   post_lost     the release POST is applied, its reply is lost: the draft
#                 is found in the release list (exact tag, draft) and deleted
#   post_lost_two the same, but the list holds two such drafts: none deleted
#   post_lost_nolist  the same, but the list cannot be read: none deleted
#   post_lost_none    the POST was never applied, its reply lost: the list
#                 holds no draft with that tag, none deleted
#   after_publish the run fails after the publish (the tag points at another
#                 commit); the forge still calls it a draft: never deleted,
#                 not even looked at
#   out_link      the build left .ci-out as a link to another folder that
#                 holds valid build results: refused before any forge call
#   links_desc    the build step (mode build: setpriv and chown are stubs,
#                 the build user's bash runs as this user) after a build()
#                 that links upstream-desc to one file and desc to another:
#                 neither is read or written through the link
#   links_out     the same, the build() puts a link to another folder in
#                 place of .ci-out: refused, nothing written there
#   links_merge   the same, the merged upstream tracks .ci-out as a link to
#                 another folder: refused, nothing written there
#   links_merge_in    the same, the merged upstream tracks .ci-out/src and
#                 .ci-out/merge.bundle as links to files: not written through
#   up_version    main has merged an upstream whose module.prop names a newer
#                 version than main's (whose version lines the release commit
#                 writes): the release is named after upstream's version, the
#                 versionCode is main's + VERSION_CODE_OFFSET as always
#   up_version_merge  the same main, the build step merged one more upstream
#                 commit: the version is read at that commit, the merge pushed
#   build_fail    the same, build() fails: the job fails, and the build user's
#                 processes are still killed (the stub records the kill)
#   build         (with TREE, a module source tree) the build step's own
#                 part (build-user) with TREE's module-ci.conf: what the
#                 module zip holds at its top level
set -u
S=$(readlink -f "$1"); D=$2; TREE=${3:-}
rm -rf "$D"; mkdir -p "$D/bin" "$D/home" "$D/tmp" "$D/seed"
D=$(cd "$D" && pwd)
FORGE=https://forge.example.invalid
BARE="$D/forge.git"

# the repo on the forge: a made-up module and its CI settings
git init -q --bare -b main "$BARE"
mkdir -p "$D/seed/.forgejo"
cat > "$D/seed/.forgejo/module-ci.conf" <<'EOF'
ZIP_PREFIX=demo
VERSION_CODE_FLOOR=1
UPDATE_JSON_PATH=update.json
SYNC_ROOT_PROP=module.prop
build() { :; }
EOF
printf '%s\n' id=demo name=Demo version=1.0-fork2 versionCode=5 updateJson=https://old.example.invalid/update.json > "$D/seed/module.prop"
printf '{}\n' > "$D/seed/update.json"
git -C "$D/seed" init -q -b main
git -C "$D/seed" add -A
git -C "$D/seed" -c user.name=Test -c user.email=test@example.invalid commit -q -m seed
git -C "$D/seed" push -q "$BARE" main
BASE=$(git -C "$D/seed" rev-parse HEAD)
printf '[url "%s"]\n\tinsteadOf = %s/o/r.git\n' "$BARE" "$FORGE" > "$D/gitconfig"

# curl: the forge. State in $CI_FAKE (draft, the uploaded asset), every call
# as "METHOD URL-path" in $CI_FAKE/calls; a call whose arguments hold the
# token is noted as TOKEN-IN-ARGV. CI_FAKE_MODE: a scenario name above
cat > "$D/bin/curl" <<'EOF'
#!/bin/sh
F=$CI_FAKE; m=GET; o=""; w=""; fa=""; u=""
for a in "$@"; do case "$a" in *tok-example*) echo TOKEN-IN-ARGV >> "$F/calls" ;; esac; done
while [ $# -gt 0 ]; do
    case "$1" in
        -X) m=$2; shift ;;
        -o) o=$2; shift ;;
        -w) w=$2; shift ;;
        -F) fa=$2; shift ;;
        -H|-d|--connect-timeout|--max-time|--retry) shift ;;
        -*) : ;;
        *) u=$1 ;;
    esac
    shift
done
p=${u#https://forge.example.invalid}
echo "$m $p" >> "$F/calls"
out() { if [ -n "$o" ] && [ "$o" != /dev/null ]; then cat > "$o"; else cat; fi; }
A=/api/v1/repos/o/r
case "$m $p" in
    "GET $A/releases/tags/"*|"GET $A/tags/"*)
        if [ -n "$w" ]; then printf 404; exit 0; fi
        if [ "$CI_FAKE_MODE" = after_publish ]; then printf '{"commit": {"sha": "%040d"}}\n' 0
        else printf '{"commit": {"sha": "%s"}}\n' "$CI_FAKE_SHA"; fi ;;
    "POST $A/releases")
        [ "$CI_FAKE_MODE" = post_lost_none ] && exit 52
        echo True > "$F/draft"
        case "$CI_FAKE_MODE" in post_lost*) exit 52 ;; esac
        echo '{"id": 7}' ;;
    "GET $A/releases?"*)
        # the draft list (drafts=true&q=TAG): Forgejo matches q as a substring;
        # the release itself, a draft whose tag only contains it, a release
        # that is no draft
        [ "$CI_FAKE_MODE" = post_lost_nolist ] && exit 22
        q=${p#*q=}; q=${q%%&*}
        printf '[{"id": 8, "tag_name": "%s0", "draft": true}, {"id": 11, "tag_name": "%s", "draft": false}' "$q" "$q"
        [ -f "$F/draft" ] && printf ', {"id": 7, "tag_name": "%s", "draft": true}' "$q"
        [ "$CI_FAKE_MODE" = post_lost_two ] && printf ', {"id": 12, "tag_name": "%s", "draft": true}' "$q"
        echo ']' ;;
    "POST $A/releases/7/assets?name="*)
        [ "$CI_FAKE_MODE" = upload_fail ] && exit 22
        cp "${fa#attachment=@}" "$F/asset"; echo '{"id": 9}' ;;
    "GET $A/releases/7/assets/9") echo '{"browser_download_url": "https://forge.example.invalid/attachments/9"}' ;;
    "GET /attachments/9"|"GET /o/r/releases/download/"*) [ -f "$F/asset" ] || exit 22; out < "$F/asset" ;;
    "PATCH $A/releases/7")
        [ "$CI_FAKE_MODE" = after_publish ] || echo False > "$F/draft"
        [ "$CI_FAKE_MODE" = patch_lost ] && exit 52
        echo '{}' ;;
    "GET $A/releases/7")
        if [ "$(cat "$F/draft")" = True ]; then echo '{"draft": true}'; else echo '{"draft": false}'; fi ;;
    "DELETE $A/releases/7") rm -f "$F/draft" ;;
    # the list's other entries exist too: deleting one of them shows
    "GET $A/releases/8"|"GET $A/releases/12") echo '{"draft": true}' ;;
    "GET $A/releases/11") echo '{"draft": false}' ;;
    "DELETE $A/releases/8"|"DELETE $A/releases/11"|"DELETE $A/releases/12") : ;;
    "GET /o/r/raw/branch/main/update.json") git --git-dir="$CI_FAKE_BARE" show main:update.json | out ;;
    *) exit 22 ;;
esac
EOF
chmod 755 "$D/bin/curl"

for mode in upload_fail patch_lost ok post_lost post_lost_two post_lost_nolist post_lost_none after_publish out_link; do
    R="$D/$mode"; O="$R/work/.ci-out"; mkdir -p "$R/work" "$R/fake"
    if [ "$mode" = out_link ]; then mkdir -p "$R/elsewhere"; ln -s ../elsewhere "$O"; else mkdir -p "$O"; fi
    # what the build step leaves: the built commit (no upstream merge), no
    # upstream note, the module zip
    printf '%s\n\n' "$BASE" > "$O/src"
    : > "$O/desc"
    git --git-dir="$BARE" show main:module.prop > "$R/module.prop"
    python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], "module.prop"); z.writestr("service.sh", "#!/system/bin/sh\n")' "$O/module.zip" "$R/module.prop"
    head0=$(git --git-dir="$BARE" rev-parse main)
    ( cd "$R" && env PATH="$D/bin:$PATH" HOME="$D/home" TMPDIR="$D/tmp" GIT_CONFIG_GLOBAL="$D/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        CI_FAKE="$R/fake" CI_FAKE_MODE="$mode" CI_FAKE_SHA="$BASE" CI_FAKE_BARE="$BARE" \
        RELEASE_TOKEN=tok-example SERVER_URL="$FORGE" REPOSITORY=o/r BASE_SHA="$BASE" RUN_NUMBER=3 \
        bash "$S" release "$R/work" > "$R/log" 2>&1 )
    rc=$?
    del=$(grep -c '^DELETE ' "$R/fake/calls" 2>/dev/null)
    tok=$(grep -c TOKEN-IN-ARGV "$R/fake/calls" 2>/dev/null)
    case "$mode" in
        ok)
            head1=$(git --git-dir="$BARE" rev-parse main)
            uj=$(git --git-dir="$BARE" show main:update.json | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(d["version"], d["versionCode"], d["zipUrl"])')
            mp=$(git --git-dir="$BARE" show main:module.prop | grep -E '^(version|versionCode|updateJson)=' | tr '\n' ' ')
            echo "ok: rc=$rc delete=$del token_in_argv=$tok draft=$(cat "$R/fake/draft" 2>/dev/null) main_moved=$([ "$head0" != "$head1" ] && echo yes || echo no)"
            echo "ok_update_json: $uj"
            echo "ok_module_prop: ${mp% }" ;;
        after_publish) echo "$mode: rc=$rc delete=$del draft_gets=$(grep -c '^GET /api/v1/repos/o/r/releases/7$' "$R/fake/calls") token_in_argv=$tok" ;;
        out_link) echo "$mode: rc=$rc calls=$(cat "$R/fake/calls" 2>/dev/null | grep -c .)" ;;
        post_lost*) echo "$mode: rc=$rc deleted=$(sed -n 's#^DELETE /api/v1/repos/o/r##p' "$R/fake/calls" | tr '\n' ' ')posts=$(grep -c '^POST /api/v1/repos/o/r/releases$' "$R/fake/calls") token_in_argv=$tok" ;;
        *) echo "$mode: rc=$rc delete=$del token_in_argv=$tok main_moved=$([ "$head0" != "$(git --git-dir="$BARE" rev-parse main)" ] && echo yes || echo no)" ;;
    esac
done

# up_version: a repo of its own on the fake forge (o/r is mapped to it by its
# own gitconfig), an upstream in a local folder. Main's module.prop holds the
# last release's lines (1.0-ci2, versionCode 5); upstream moved on to 1.1
# (versionCode 3) and main merged it keeping its own lines, as a hand merge
# of the conflict does. The build note's upstream sha (src, the build user's
# file) names the older upstream commit: it is not what the name comes from.
U="$D/up_version"; mkdir -p "$U/work/.ci-out" "$U/fake"
gu() { git -C "$1" -c user.name=Test -c user.email=test@example.invalid "${@:2}"; }
git init -q -b main "$U/up"
printf '%s\n' id=demo name=Demo version=1.0 versionCode=3 > "$U/up/module.prop"
gu "$U/up" add -A; gu "$U/up" commit -q -m 'upstream 1.0'
UP1=$(git -C "$U/up" rev-parse HEAD)
git clone -q "$U/up" "$U/fork"
mkdir -p "$U/fork/.forgejo"
printf '%s\n' ZIP_PREFIX=demo VERSION_CODE_FLOOR=1 UPDATE_JSON_PATH=update.json SYNC_ROOT_PROP=module.prop \
    "UPSTREAM_URL=$U/up" UPSTREAM_BRANCH=main 'build() { :; }' > "$U/fork/.forgejo/module-ci.conf"
printf '%s\n' id=demo name=Demo version=1.0-ci2 versionCode=5 "updateJson=$FORGE/o/r/raw/branch/main/update.json" > "$U/fork/module.prop"
printf '{}\n' > "$U/fork/update.json"
gu "$U/fork" add -A; gu "$U/fork" commit -q -m 'fork, release 1.0-ci2'
printf '%s\n' id=demo name=Demo version=1.1 versionCode=3 > "$U/up/module.prop"
gu "$U/up" commit -q -am 'upstream 1.1'
gu "$U/fork" fetch -q "$U/up" main
gu "$U/fork" merge -q --no-edit -s ours FETCH_HEAD
git init -q --bare -b main "$U/forge.git"
git -C "$U/fork" push -q "$U/forge.git" main
UB=$(git -C "$U/fork" rev-parse HEAD)
printf '[url "%s"]\n\tinsteadOf = %s/o/r.git\n' "$U/forge.git" "$FORGE" > "$U/gitconfig"
printf '%s\n%s\n' "$UB" "$UP1" > "$U/work/.ci-out/src"
: > "$U/work/.ci-out/desc"
python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], "module.prop")' "$U/work/.ci-out/module.zip" "$U/fork/module.prop"
( cd "$U" && env PATH="$D/bin:$PATH" HOME="$D/home" TMPDIR="$D/tmp" GIT_CONFIG_GLOBAL="$U/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    CI_FAKE="$U/fake" CI_FAKE_MODE=ok CI_FAKE_SHA="$UB" CI_FAKE_BARE="$U/forge.git" \
    RELEASE_TOKEN=tok-example SERVER_URL="$FORGE" REPOSITORY=o/r BASE_SHA="$UB" RUN_NUMBER=3 \
    bash "$S" release "$U/work" > "$U/log" 2>&1 )
rc=$?
uj=$(git --git-dir="$U/forge.git" show main:update.json | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(d.get("version"), d.get("versionCode"))')
echo "up_version: rc=$rc update_json=$uj $(git --git-dir="$U/forge.git" show main:module.prop | grep -E '^(version|versionCode)=' | tr '\n' ' ' | sed 's/ $//')"
# up_version_merge: the same main, upstream gained a commit that leaves
# module.prop alone; the build step merged it (merge commit, merge.bundle and
# src made as module-ci.sh build makes them): the release takes the version at
# that upstream commit too, and pushes the merge
M="$D/up_version_merge"; mkdir -p "$M/work/.ci-out" "$M/fake"
printf 'b\n' > "$U/up/b"; gu "$U/up" add b; gu "$U/up" commit -q -m 'upstream: b'
UP3=$(git -C "$U/up" rev-parse HEAD)
git init -q --bare -b main "$M/forge.git"
git -C "$U/fork" push -q "$M/forge.git" main
git clone -q "$M/forge.git" "$M/b"
gu "$M/b" fetch -q "$U/up" main
gu "$M/b" merge -q --no-ff --no-edit -m "Merge up main ${UP3:0:12}" FETCH_HEAD
MS=$(git -C "$M/b" rev-parse HEAD)
git -C "$M/b" bundle create -q "$M/work/.ci-out/merge.bundle" "$UB..main"
printf '%s\n%s\n' "$MS" "$UP3" > "$M/work/.ci-out/src"
: > "$M/work/.ci-out/desc"
python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], "module.prop")' "$M/work/.ci-out/module.zip" "$M/b/module.prop"
printf '[url "%s"]\n\tinsteadOf = %s/o/r.git\n' "$M/forge.git" "$FORGE" > "$M/gitconfig"
( cd "$M" && env PATH="$D/bin:$PATH" HOME="$D/home" TMPDIR="$D/tmp" GIT_CONFIG_GLOBAL="$M/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    CI_FAKE="$M/fake" CI_FAKE_MODE=ok CI_FAKE_SHA="$MS" CI_FAKE_BARE="$M/forge.git" \
    RELEASE_TOKEN=tok-example SERVER_URL="$FORGE" REPOSITORY=o/r BASE_SHA="$UB" RUN_NUMBER=3 \
    bash "$S" release "$M/work" > "$M/log" 2>&1 )
rc=$?
uj=$(git --git-dir="$M/forge.git" show main:update.json | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(d.get("version"), d.get("versionCode"))')
echo "up_version_merge: rc=$rc update_json=$uj merge_on_main=$(git --git-dir="$M/forge.git" merge-base --is-ancestor "$MS" main 2>/dev/null && echo yes || echo no)"

# the build step as root, after a build user that planted links: setpriv
# runs only the build user's bash (as this user, never `kill -9 -1`: any other
# call is recorded in SETPRIV_LOG), chown does nothing. Each scenario has its own repo, with SCRIPT as its module-ci.sh
cat > "$D/bin/setpriv" <<'EOF'
#!/bin/sh
all="$*"
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
[ "$1" = bash ] && exec "$@"
echo "$all" >> "$SETPRIV_LOG"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$D/bin/chown"
chmod 755 "$D/bin/setpriv" "$D/bin/chown"
for mode in links_desc links_out links_merge links_merge_in build_fail; do
    B="$D/$mode"; mkdir -p "$B/repo/.forgejo" "$B/other"
    printf 'secret-example\n' > "$B/secret"; printf 'victim-example\n' > "$B/victim"
    cp "$S" "$B/repo/.forgejo/module-ci.sh"
    case "$mode" in links_merge*) printf 'UPSTREAM_URL=%s\nUPSTREAM_BRANCH=main\n' "$B/up" > "$B/repo/.forgejo/module-ci.conf" ;; esac
    cat >> "$B/repo/.forgejo/module-ci.conf" <<'EOF'
build() {
    case "$WORK" in
        */links_desc/repo) printf x > "$OUT/module.zip"; ln -s ../../secret "$OUT/upstream-desc"; ln -s ../../victim "$OUT/desc" ;;
        */links_out/repo) rm -rf "$OUT"; ln -s ../other "$OUT"; printf x > "$OUT/module.zip" ;;
        */build_fail/repo) echo "example build failure" >&2; return 1 ;;
        *) printf x > "$OUT/module.zip" ;;
    esac
}
EOF
    printf 'id=demo\n' > "$B/repo/module.prop"
    git -C "$B/repo" init -q -b main
    git -C "$B/repo" add -A
    git -C "$B/repo" -c user.name=Test -c user.email=test@example.invalid commit -q -m seed
    if [ "$mode" = links_merge ]; then
        git clone -q "$B/repo" "$B/up"
        ln -s ../other "$B/up/.ci-out"
        git -C "$B/up" add .ci-out
        git -C "$B/up" -c user.name=Test -c user.email=test@example.invalid commit -q -m 'upstream: .ci-out as a link'
    elif [ "$mode" = links_merge_in ]; then
        git clone -q "$B/repo" "$B/up"
        mkdir "$B/up/.ci-out"
        ln -s ../../victim "$B/up/.ci-out/src"
        ln -s ../../secret "$B/up/.ci-out/merge.bundle"
        git -C "$B/up" add .ci-out
        git -C "$B/up" -c user.name=Test -c user.email=test@example.invalid commit -q -m 'upstream: links in .ci-out'
    fi
    : > "$B/setpriv.log"
    ( cd "$B" && env PATH="$D/bin:$PATH" SETPRIV_LOG="$B/setpriv.log" HOME="$D/home" TMPDIR="$D/tmp" GIT_CONFIG_GLOBAL="$D/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        SERVER_URL="$FORGE" REPOSITORY=o/r BASE_SHA="$(git -C "$B/repo" rev-parse HEAD)" \
        bash "$S" build "$B/repo" > "$B/log" 2>&1 )
    rc=$?
    d="$B/repo/.ci-out/desc"
    if [ -L "$d" ]; then k="link"; elif [ -f "$d" ]; then k="file"; else k="none"; fi
    echo "$mode kills: $(grep -c -e '--reuid=1000 .*kill -9 -1' "$B/setpriv.log")"
    echo "$mode: rc=$rc secret=$(head -n1 "$B/secret" | tr -cd '[:print:]') victim=$(head -n1 "$B/victim" | tr -cd '[:print:]') desc=$k desc_secret=$(cat "$d" 2>/dev/null | grep -c secret-example) other=$(find "$B/other" -mindepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
done

if [ -n "$TREE" ]; then
    W="$D/build"; mkdir -p "$W"
    tar -C "$TREE" --exclude=./.git --exclude=./tests/.run -cf - . | tar -C "$W" -xf -
    rm -rf "$W/.ci-out"; mkdir -p "$W/.ci-out"
    ( cd "$W" && env PATH="$D/bin:$PATH" HOME="$D/home" TMPDIR="$D/tmp" SERVER_URL="$FORGE" REPOSITORY=o/r BASE_SHA="$BASE" \
        bash "$S" build-user "$W" > "$D/build.log" 2>&1 )
    rc=$?
    echo "build: rc=$rc top=$(unzip -Z1 "$W/.ci-out/module.zip" 2>/dev/null | cut -d/ -f1 | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
fi
