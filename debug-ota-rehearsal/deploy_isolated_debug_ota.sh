#!/bin/bash
set -Eeuo pipefail

snippet=/etc/nginx/snippets/erp-uat-updates.conf
root=/var/www/erp-uat-updates
host=https://api-test.scxmj.cn
source_base=https://raw.githubusercontent.com/zhangchengjiang236-netizen/FH_ERP_Debug_Artifacts/e1e932ceb02b5997a7be2f4f0213f8f01421779e/debug-ota-rehearsal
baseline=feihong-erp-0.9.4-debug-baseline.apk
update=feihong-erp-0.9.5-debug-update.apk
expected_snippet=478600982cdf079ef7585cca050d6dc642a14d2227758509c6b9f0c3e15f0c4b
baseline_hash=baeb4729c9697224e10d8f7bc7c7c457a7929128b8b51a7e550a86f81ef2848b
update_hash=8103841366f2f5d303fa936feaa65af275404956ead128a604f615f75f556aef
manifest_hash=4b1f687f3c7b2499dfcacfc082cdb2cd4cb0a802d54996fe4a335047f7397af2
baseline_size=1024968
update_size=1024972
ts=$(date -u +%Y%m%dT%H%M%SZ)
backup_root=/var/backups/nginx/erp-uat-debug-ota-$ts
tmp=$(mktemp -d /tmp/erp-debug-ota.XXXXXX)
finished=0
had_debug_manifest=0
new_baseline=0
new_update=0

rollback() {
  rc=$?
  trap - EXIT ERR INT TERM
  if [ "$finished" -eq 0 ] && [ -d "$backup_root" ]; then
    [ ! -f "$backup_root/snippet.before" ] || cp -a "$backup_root/snippet.before" "$snippet"
    if [ "$had_debug_manifest" -eq 1 ]; then
      cp -a "$backup_root/debug.json.before" "$root/android/debug.json"
    else
      rm -f "$root/android/debug.json"
    fi
    [ "$new_baseline" -eq 0 ] || rm -f "$root/debug-packages/$baseline"
    [ "$new_update" -eq 0 ] || rm -f "$root/debug-packages/$update"
    if [ -d "$backup_root/enabled-backups" ]; then
      find "$backup_root/enabled-backups" -maxdepth 1 -type f -exec mv -t /etc/nginx/sites-enabled/ -- {} + 2>/dev/null || true
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  fi
  rm -rf "$tmp"
  exit "$rc"
}
trap rollback EXIT ERR INT TERM

[ "$(sha256sum "$snippet" | awk '{print $1}')" = "$expected_snippet" ] || {
  echo SNIPPET_CHANGED_STOP
  exit 20
}
stable_before=MISSING
[ ! -f "$root/android/stable.json" ] || stable_before=$(sha256sum "$root/android/stable.json" | awk '{print $1}')

fetch() {
  url=$1
  out=$2
  meta=$(curl -sS --proto '=https' --tlsv1.2 --max-redirs 0 --connect-timeout 20 --max-time 240 \
    -w '%{http_code} %{num_redirects} %{url_effective}' -o "$out" "$url")
  [ "$meta" = "200 0 $url" ] || {
    echo "FETCH_REJECTED $meta"
    return 1
  }
}

fetch "$source_base/$baseline" "$tmp/$baseline"
fetch "$source_base/$update" "$tmp/$update"
fetch "$source_base/debug.json" "$tmp/debug.json"
[ "$(sha256sum "$tmp/$baseline" | awk '{print $1}')" = "$baseline_hash" ]
[ "$(stat -c%s "$tmp/$baseline")" = "$baseline_size" ]
[ "$(sha256sum "$tmp/$update" | awk '{print $1}')" = "$update_hash" ]
[ "$(stat -c%s "$tmp/$update")" = "$update_size" ]
[ "$(sha256sum "$tmp/debug.json" | awk '{print $1}')" = "$manifest_hash" ]
python3 -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); e={'versionName':'0.9.5-debug.1','versionCode':90501,'minimumVersion':'90401','mandatory':False,'downloadUrl':'https://api-test.scxmj.cn/mobile-updates/debug-packages/feihong-erp-0.9.5-debug-update.apk','fileSize':1024972,'sha256':'8103841366f2f5d303fa936feaa65af275404956ead128a604f615f75f556aef','signingIdentity':'sha256:a182e8f2b6b60e71acf6e29184558fd3b210b5c8748a8beeb75de0bace3355a4','channel':'debug'}; assert all(d.get(k)==v for k,v in e.items()); assert isinstance(d.get('publishedAt'),str) and d['publishedAt']; assert isinstance(d.get('releaseNotes'),str) and d['releaseNotes']" "$tmp/debug.json"

install -d -m 0755 "$backup_root/enabled-backups" "$root/android" "$root/debug-packages" "$root/archive"
cp -a "$snippet" "$backup_root/snippet.before"
unknown=$(grep -RIlE '^[[:space:]]*server_name[[:space:]].*api-test[.]scxmj[.]cn' /etc/nginx/sites-enabled 2>/dev/null \
  | grep -vE '^/etc/nginx/sites-enabled/wlh-test-api([.]erp-uat-backup-[A-Za-z0-9_-]+)?$' || true)
[ -z "$unknown" ] || {
  printf 'UNEXPECTED_API_TEST_CONFIG=%s\n' "$unknown"
  exit 21
}
[ -f /etc/nginx/sites-enabled/wlh-test-api ] || {
  echo ACTIVE_SITE_NOT_FOUND
  exit 22
}
[ "$(grep -cF '/mobile-updates/android/debug.json' "$snippet")" -eq 0 ]
[ "$(grep -cF '/mobile-updates/debug-packages/' "$snippet")" -eq 0 ]
pending=$snippet.pending.$$
cp -a "$snippet" "$pending"
printf '%s\n' \
  '' \
  'location = /mobile-updates/android/debug.json {' \
  '    alias /var/www/erp-uat-updates/android/debug.json;' \
  '    default_type application/json;' \
  '    add_header Cache-Control "no-store, max-age=0" always;' \
  '    add_header X-Content-Type-Options "nosniff" always;' \
  '    add_header Access-Control-Allow-Origin "https://appassets.androidplatform.net" always;' \
  '    add_header Vary "Origin" always;' \
  '}' \
  '' \
  'location ^~ /mobile-updates/debug-packages/ {' \
  '    alias /var/www/erp-uat-updates/debug-packages/;' \
  '    default_type application/vnd.android.package-archive;' \
  '    add_header Cache-Control "public, max-age=31536000, immutable" always;' \
  '    add_header X-Content-Type-Options "nosniff" always;' \
  '}' >> "$pending"
mv -f "$pending" "$snippet"

# Disable only the two explicitly allow-listed historical site copies, and do
# it immediately before the final syntax/duplicate gate.  This avoids leaving
# a window in which a control-plane reconciliation can reintroduce the copies
# between route preparation and validation.
shopt -s nullglob
backup_candidates=(/etc/nginx/sites-enabled/wlh-test-api.erp-uat-backup-*)
shopt -u nullglob
for candidate in "${backup_candidates[@]}"; do
  [[ "$candidate" =~ ^/etc/nginx/sites-enabled/wlh-test-api[.]erp-uat-backup-[A-Za-z0-9_-]+$ ]] || {
    echo UNEXPECTED_BACKUP_NAME
    exit 23
  }
  mv -- "$candidate" "$backup_root/enabled-backups/"
done
check=$(nginx -t 2>&1) || {
  printf '%s\n' "$check"
  exit 24
}
printf '%s\n' "$check"
! grep -qi 'conflicting server name' <<<"$check" || {
  echo DUPLICATE_SERVER_NAME_AFTER_ROUTE
  exit 25
}

install_one() {
  name=$1
  hash=$2
  size=$3
  marker=$4
  dest=$root/debug-packages/$name
  if [ -e "$dest" ]; then
    [ "$(sha256sum "$dest" | awk '{print $1}')" = "$hash" ] \
      && [ "$(stat -c%s "$dest")" = "$size" ] \
      || { echo EXISTING_PACKAGE_MISMATCH; exit 27; }
  else
    install -m 0644 "$tmp/$name" "$root/debug-packages/.$name.pending"
    mv -n "$root/debug-packages/.$name.pending" "$dest"
    if [ "$marker" = baseline ]; then new_baseline=1; else new_update=1; fi
  fi
}
install_one "$baseline" "$baseline_hash" "$baseline_size" baseline
install_one "$update" "$update_hash" "$update_size" update

if [ -f "$root/android/debug.json" ]; then
  had_debug_manifest=1
  cp -a "$root/android/debug.json" "$backup_root/debug.json.before"
  cp -a "$root/android/debug.json" "$root/archive/debug.json.$ts.before"
fi
install -m 0644 "$tmp/debug.json" "$root/android/.debug.json.pending.$$"
mv -f "$root/android/.debug.json.pending.$$" "$root/android/debug.json"
systemctl reload nginx

manifest_url=$host/mobile-updates/android/debug.json
meta=$(curl -sS --proto '=https' --tlsv1.2 --max-redirs 0 --connect-timeout 20 --max-time 60 \
  -H 'Origin: https://appassets.androidplatform.net' -D "$tmp/headers" \
  -w '%{http_code} %{num_redirects} %{url_effective}' -o "$tmp/readback.json" "$manifest_url")
[ "$meta" = "200 0 $manifest_url" ] || {
  echo "HTTPS_MANIFEST_REJECTED $meta"
  exit 29
}
tr -d '\r' < "$tmp/headers" > "$tmp/headers.clean"
grep -Fqi 'Content-Type: application/json' "$tmp/headers.clean"
grep -Fqi 'Access-Control-Allow-Origin: https://appassets.androidplatform.net' "$tmp/headers.clean"
grep -Fqi 'Vary: Origin' "$tmp/headers.clean"
[ "$(sha256sum "$tmp/readback.json" | awk '{print $1}')" = "$manifest_hash" ]

fetch "$host/mobile-updates/debug-packages/$baseline" "$tmp/readback-baseline.apk"
[ "$(sha256sum "$tmp/readback-baseline.apk" | awk '{print $1}')" = "$baseline_hash" ]
[ "$(stat -c%s "$tmp/readback-baseline.apk")" = "$baseline_size" ]
fetch "$host/mobile-updates/debug-packages/$update" "$tmp/readback-update.apk"
[ "$(sha256sum "$tmp/readback-update.apk" | awk '{print $1}')" = "$update_hash" ]
[ "$(stat -c%s "$tmp/readback-update.apk")" = "$update_size" ]

stable_after=MISSING
[ ! -f "$root/android/stable.json" ] || stable_after=$(sha256sum "$root/android/stable.json" | awk '{print $1}')
[ "$stable_before" = "$stable_after" ] || {
  echo STABLE_MANIFEST_CHANGED
  exit 28
}
printf '%s\n' \
  "Restore config: cp -a $backup_root/snippet.before $snippet && nginx -t && systemctl reload nginx" \
  "Restore manifest: use $backup_root/debug.json.before when present; otherwise remove only $root/android/debug.json" \
  "Restore disabled backup configs only if needed: move files from $backup_root/enabled-backups/ back to /etc/nginx/sites-enabled/ then run nginx -t" \
  'The stable manifest was not changed.' > "$backup_root/ROLLBACK.txt"

finished=1
trap - EXIT ERR INT TERM
rm -rf "$tmp"
printf 'DEBUG_OTA_STATIC_DEPLOYED\nMANIFEST_URL=%s/mobile-updates/android/debug.json\nMANIFEST_SHA256=%s\nBASELINE_URL=%s/mobile-updates/debug-packages/%s\nBASELINE_SHA256=%s\nUPDATE_URL=%s/mobile-updates/debug-packages/%s\nUPDATE_SHA256=%s\nSIGNER_SHA256=%s\nSTABLE_JSON=%s\nBACKUP_ID=%s\nSTATUS=PENDING_REAL_DEVICE_DEBUG_OTA_VERIFICATION\n' \
  "$host" "$manifest_hash" "$host" "$baseline" "$baseline_hash" "$host" "$update" "$update_hash" \
  a182e8f2b6b60e71acf6e29184558fd3b210b5c8748a8beeb75de0bace3355a4 "$stable_after" "erp-uat-debug-ota-$ts"
