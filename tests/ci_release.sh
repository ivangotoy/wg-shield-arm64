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
        printf '{"commit": {"sha": "%s"}}\n' "$CI_FAKE_SHA" ;;
    "POST $A/releases")
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
        echo False > "$F/draft"
        [ "$CI_FAKE_MODE" = patch_lost ] && exit 52
        echo '{}' ;;
    "GET $A/releases/7")
        if [ "$(cat "$F/draft")" = True ]; then echo '{"draft": true}'; else echo '{"draft": false}'; fi ;;
    "DELETE $A/releases/7") rm -f "$F/draft" ;;
    "GET /o/r/raw/branch/main/update.json") git --git-dir="$CI_FAKE_BARE" show main:update.json | out ;;
    *) exit 22 ;;
esac
EOF
chmod 755 "$D/bin/curl"

for mode in upload_fail patch_lost ok post_lost post_lost_two post_lost_nolist; do
    R="$D/$mode"; mkdir -p "$R/work/.ci-out" "$R/fake"
    # what the build step leaves: the built commit (no upstream merge), no
    # upstream note, the module zip
    printf '%s\n\n' "$BASE" > "$R/work/.ci-out/src"
    : > "$R/work/.ci-out/desc"
    git --git-dir="$BARE" show main:module.prop > "$R/module.prop"
    python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], "module.prop"); z.writestr("service.sh", "#!/system/bin/sh\n")' "$R/work/.ci-out/module.zip" "$R/module.prop"
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
        post_lost*) echo "$mode: rc=$rc deleted=$(sed -n 's#^DELETE /api/v1/repos/o/r##p' "$R/fake/calls" | tr '\n' ' ')posts=$(grep -c '^POST /api/v1/repos/o/r/releases$' "$R/fake/calls") token_in_argv=$tok" ;;
        *) echo "$mode: rc=$rc delete=$del token_in_argv=$tok main_moved=$([ "$head0" != "$(git --git-dir="$BARE" rev-parse main)" ] && echo yes || echo no)" ;;
    esac
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
