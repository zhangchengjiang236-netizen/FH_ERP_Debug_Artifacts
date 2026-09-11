#!/bin/bash
set -euo pipefail

root=/var/www/erp-uat-updates
host=https://api-test.scxmj.cn
source_base=https://raw.githubusercontent.com/zhangchengjiang236-netizen/FH_ERP_Debug_Artifacts/71da745f860a86a9a32a683a1d959b93e3f8d96a/debug-ota-rehearsal
update=feihong-erp-0.9.6-debug-update.apk
update_hash=9ee1dec99235a0d875e126aa17000298cc18bba8e86a839f7b397c0c72aba727
update_size=1025256
manifest_hash=2661a955be5c4e0314bfd3efd02706083c191aac2eaae3b8435b72d3ed487ddf
ts=$(date -u +%Y%m%dT%H%M%SZ)
backup_root=/var/backups/nginx/erp-uat-debug-ota-0.9.6-$ts
tmp=$(mktemp -d /tmp/erp-debug-ota-0.9.6.XXXXXX)
finished=0
had_debug_manifest=0
new_update=0

rollback() {
  rc=$?
  trap - ERR INT TERM
  if [ "$finished" -eq 0 ] && [ -d "$backup_root" ]; then
    if [ "$had_debug_manifest" -eq 1 ]; then
      cp -a "$backup_root/debug.json.before" "$root/android/debug.json"
    else
      rm -f "$root/android/debug.json"
    fi
    [ "$new_update" -eq 0 ] || rm -f "$root/debug-packages/$update"
  fi
  rm -rf "$tmp"
  exit "$rc"
}
trap rollback ERR INT TERM

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

main() {
  stable_before=MISSING
  [ ! -f "$root/android/stable.json" ] || stable_before=$(sha256sum "$root/android/stable.json" | awk '{print $1}')

  active=$(nginx -T 2>&1)
  ! grep -qi 'conflicting server name' <<<"$active" || {
    echo DUPLICATE_SERVER_NAME_IN_ACTIVE_CONFIG
    return 20
  }
  [ "$(grep -cF 'location = /mobile-updates/android/debug.json' <<<"$active")" -eq 1 ] || {
    echo DEBUG_MANIFEST_ROUTE_NOT_UNIQUE
    return 21
  }
  [ "$(grep -cF 'location ^~ /mobile-updates/debug-packages/' <<<"$active")" -eq 1 ] || {
    echo DEBUG_PACKAGE_ROUTE_NOT_UNIQUE
    return 22
  }

  fetch "$source_base/$update" "$tmp/$update"
  fetch "$source_base/debug.json" "$tmp/debug.json"
  [ "$(sha256sum "$tmp/$update" | awk '{print $1}')" = "$update_hash" ]
  [ "$(stat -c%s "$tmp/$update")" = "$update_size" ]
  [ "$(sha256sum "$tmp/debug.json" | awk '{print $1}')" = "$manifest_hash" ]
  python3 -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); e={'versionName':'0.9.6-debug.1','versionCode':90601,'minimumVersion':'90501','mandatory':False,'downloadUrl':'https://api-test.scxmj.cn/mobile-updates/debug-packages/feihong-erp-0.9.6-debug-update.apk','fileSize':1025256,'sha256':'9ee1dec99235a0d875e126aa17000298cc18bba8e86a839f7b397c0c72aba727','signingIdentity':'sha256:a182e8f2b6b60e71acf6e29184558fd3b210b5c8748a8beeb75de0bace3355a4','channel':'debug'}; assert all(d.get(k)==v for k,v in e.items()); assert isinstance(d.get('publishedAt'),str) and d['publishedAt']; assert isinstance(d.get('releaseNotes'),str) and d['releaseNotes']" "$tmp/debug.json"

  install -d -m 0755 "$backup_root" "$root/android" "$root/debug-packages" "$root/archive"
  if [ -f "$root/android/debug.json" ]; then
    had_debug_manifest=1
    cp -a "$root/android/debug.json" "$backup_root/debug.json.before"
    cp -a "$root/android/debug.json" "$root/archive/debug.json.$ts.before-0.9.6"
  fi

  dest=$root/debug-packages/$update
  if [ -e "$dest" ]; then
    [ "$(sha256sum "$dest" | awk '{print $1}')" = "$update_hash" ]
    [ "$(stat -c%s "$dest")" = "$update_size" ]
  else
    install -m 0644 "$tmp/$update" "$root/debug-packages/.$update.pending.$$"
    mv -n "$root/debug-packages/.$update.pending.$$" "$dest"
    new_update=1
  fi

  install -m 0644 "$tmp/debug.json" "$root/android/.debug.json.pending.$$"
  mv -f "$root/android/.debug.json.pending.$$" "$root/android/debug.json"

  manifest_url=$host/mobile-updates/android/debug.json
  meta=$(curl -sS --proto '=https' --tlsv1.2 --max-redirs 0 --connect-timeout 20 --max-time 60 \
    -H 'Origin: https://appassets.androidplatform.net' -D "$tmp/headers" \
    -w '%{http_code} %{num_redirects} %{url_effective}' -o "$tmp/readback.json" "$manifest_url")
  [ "$meta" = "200 0 $manifest_url" ]
  tr -d '\r' < "$tmp/headers" > "$tmp/headers.clean"
  grep -Fqi 'Content-Type: application/json' "$tmp/headers.clean"
  grep -Fqi 'Access-Control-Allow-Origin: https://appassets.androidplatform.net' "$tmp/headers.clean"
  [ "$(sha256sum "$tmp/readback.json" | awk '{print $1}')" = "$manifest_hash" ]

  update_url=$host/mobile-updates/debug-packages/$update
  fetch "$update_url" "$tmp/readback-update.apk"
  [ "$(sha256sum "$tmp/readback-update.apk" | awk '{print $1}')" = "$update_hash" ]
  [ "$(stat -c%s "$tmp/readback-update.apk")" = "$update_size" ]

  stable_after=MISSING
  [ ! -f "$root/android/stable.json" ] || stable_after=$(sha256sum "$root/android/stable.json" | awk '{print $1}')
  [ "$stable_before" = "$stable_after" ] || {
    echo STABLE_MANIFEST_CHANGED
    return 23
  }
  printf '%s\n' \
    "Restore manifest: cp -a $backup_root/debug.json.before $root/android/debug.json" \
    "Optional cleanup after rollback: rm -f $root/debug-packages/$update" \
    'Nginx configuration and stable.json were not changed.' > "$backup_root/ROLLBACK.txt"

  finished=1
  trap - ERR INT TERM
  rm -rf "$tmp"
  printf 'DEBUG_OTA_0_9_6_STATIC_DEPLOYED\nMANIFEST_URL=%s\nMANIFEST_SHA256=%s\nUPDATE_URL=%s\nUPDATE_SHA256=%s\nUPDATE_SIZE=%s\nSIGNER_SHA256=%s\nSTABLE_JSON=%s\nBACKUP_ID=%s\nSTATUS=PENDING_REAL_DEVICE_DEBUG_OTA_VERIFICATION\n' \
    "$manifest_url" "$manifest_hash" "$update_url" "$update_hash" "$update_size" \
    a182e8f2b6b60e71acf6e29184558fd3b210b5c8748a8beeb75de0bace3355a4 "$stable_after" "erp-uat-debug-ota-0.9.6-$ts"
}

main
