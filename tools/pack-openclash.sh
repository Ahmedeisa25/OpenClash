#!/usr/bin/env bash
# Pack luci-app-openclash as both opkg (.ipk) and apk-tools v3 (.apk).
#
# OpenWrt 25.12 / snapshots use apk. A gzip/opkg .ipk is not an APK v3
# package; `apk add file.ipk` fails with: v2 package format error.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT/luci-app-openclash"
PKG_NAME="luci-app-openclash"
PKG_VERSION="$(awk -F ':=' '/^PKG_VERSION:=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$PKG_DIR/Makefile")"
# apk version spec: number{.number}...{_suffix}{-r#}. "lite" is not valid.
APK_VERSION="$PKG_VERSION"
IPK_VERSION="${PKG_VERSION}-lite"
MAINTAINER="vernesong"
DESCRIPTION="Lightweight LuCI support for clash on MT7621 / 128MB RAM. Defaults: nftables + Fake-IP + Rule mode. MetaCubeXD bundled."
DEPENDS_IPK="libc, dnsmasq-full, bash, curl, ca-bundle, ip-full, ruby, ruby-yaml, unzip, luci-compat"
DEPENDS_APK="libc dnsmasq-full bash curl ca-bundle ip-full ruby ruby-yaml unzip luci-compat"

OUT_DIR="${OUT_DIR:-$ROOT/bin}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need_cmd tar
need_cmd gzip
need_cmd find
need_cmd python3

APK_BIN="${APK_BIN:-}"
if [ -z "$APK_BIN" ]; then
  for cand in \
    "$ROOT/.tools/apk" \
    /tmp/apk-tools/build/src/apk \
    "$(command -v apk || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if "$cand" mkpkg --output /dev/null --info "name:probe" 2>&1 | grep -qiE 'version is invalid|info field|failed to create'; then
      APK_BIN="$cand"
      break
    fi
  done
fi

stage_files() {
  local dest="$1"
  mkdir -p "$dest/usr/lib/lua/luci/i18n"

  tar -C "$PKG_DIR/root" --exclude='.gitkeep' -cf - . | tar -C "$dest" -xf -

  mkdir -p "$dest/usr/lib/lua/luci"
  tar -C "$PKG_DIR/luasrc" -cf - . | tar -C "$dest/usr/lib/lua/luci" -xf -

  local po2lmo="$PKG_DIR/tools/po2lmo/src/po2lmo"
  if [ ! -x "$po2lmo" ]; then
    make -C "$PKG_DIR/tools/po2lmo" >/dev/null
  fi
  local po
  for po in "$PKG_DIR"/po/zh-cn/*.po; do
    [ -f "$po" ] || continue
    "$po2lmo" "$po" "$dest/usr/lib/lua/luci/i18n/$(basename "${po%.po}").lmo"
  done

  chmod 0755 "$dest/etc/init.d/openclash"
  chmod -R 0755 "$dest/usr/share/openclash"
  find "$dest" -type d -exec chmod 0755 {} +
  find "$dest" -type f -name '*.sh' -exec chmod 0755 {} +
  find "$dest" -type f \( -name '*.lua' -o -name '*.htm' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' -o -name '*.list' \) -exec chmod 0644 {} +
}

write_script() {
  local path="$1"
  cat > "$path"
  chmod 0755 "$path"
}

write_preinst() {
  write_script "$1" <<'EOF'
#!/bin/sh
	if [ -f "/etc/config/openclash" ] && [ ! -f "/tmp/openclash.bak" ]; then
		cp -f "/etc/config/openclash" "/tmp/openclash.bak" >/dev/null 2>&1
		cp -rf "/etc/openclash" "/tmp/openclash" >/dev/null 2>&1
		cp -rf "/usr/share/openclash/ui" "/tmp/openclash_ui" >/dev/null 2>&1
		cp -rf "/www/luci-static/resources/openclash/pac" "/tmp/pac" >/dev/null 2>&1
	fi
	exit 0
EOF
}

write_prerm_pkg() {
  write_script "$1" <<'EOF'
#!/bin/sh
	[ -n "$(pidof clash)" ] && /etc/init.d/openclash stop 2>/dev/null
	if [ -f "/etc/config/openclash" ] && [ ! -f "/tmp/openclash.bak" ]; then
		cp -f "/etc/config/openclash" "/tmp/openclash.bak" >/dev/null 2>&1
		cp -rf "/etc/openclash" "/tmp/openclash" >/dev/null 2>&1
		cp -rf "/usr/share/openclash/ui" "/tmp/openclash_ui" >/dev/null 2>&1
		cp -rf "/www/luci-static/resources/openclash/pac" "/tmp/pac" >/dev/null 2>&1
	fi
	exit 0
EOF
}

write_postrm() {
  write_script "$1" <<'EOF'
#!/bin/sh
	DEFAULT_DNSMASQ_CFGID="$(uci -q show "dhcp.@dnsmasq[0]" | awk 'NR==1 {split($0, conf, /[.=]/); print conf[2]}' 2>/dev/null)"
	if [ -f "/tmp/etc/dnsmasq.conf.$DEFAULT_DNSMASQ_CFGID" ]; then
	   DNSMASQ_CONF_DIR="$(awk -F '=' '/^conf-dir=/ {print $2}' "/tmp/etc/dnsmasq.conf.$DEFAULT_DNSMASQ_CFGID" 2>/dev/null)"
	else
	   DNSMASQ_CONF_DIR="/tmp/dnsmasq.d"
	fi
	DNSMASQ_CONF_DIR=${DNSMASQ_CONF_DIR%*/}
	rm -rf /etc/openclash >/dev/null 2>&1
	rm -rf /etc/config/openclash >/dev/null 2>&1
	rm -rf /tmp/openclash.log >/dev/null 2>&1
	rm -rf /tmp/openclash_start.log >/dev/null 2>&1
	rm -rf /tmp/openclash.change >/dev/null 2>&1
	rm -rf /usr/share/openclash >/dev/null 2>&1
	rm -rf /tmp/openclash_version_history.json >/dev/null 2>&1
	rm -rf /tmp/openclash_cdn_info.json >/dev/null 2>&1
	rm -rf ${DNSMASQ_CONF_DIR}/dnsmasq_openclash_custom_domain.conf >/dev/null 2>&1
	rm -rf ${DNSMASQ_CONF_DIR}/dnsmasq_openclash_chnroute_pass.conf >/dev/null 2>&1
	rm -rf ${DNSMASQ_CONF_DIR}/dnsmasq_openclash_chnroute6_pass.conf >/dev/null 2>&1
	rm -rf /tmp/etc/openclash >/dev/null 2>&1
	rm -rf /tmp/openclash_announcement >/dev/null 2>&1
	rm -rf /www/luci-static/resources/openclash >/dev/null 2>&1
	rm -rf /tmp/oix* >/dev/null 2>&1
	rm -rf /tmp/openclash_oix_version.json >/dev/null 2>&1
	rm -rf /tmp/openclash_version_history_* >/dev/null 2>&1
	rm -rf /tmp/openclash_cdn_info_* >/dev/null 2>&1
	sed -i '/OpenClash Append/,/OpenClash Append End/d' "/usr/lib/lua/luci/model/network.lua" >/dev/null 2>&1
	sed -i '/.*kB maximum content size*/c\HTTP_MAX_CONTENT      = 1024*100		-- 100 kB maximum content size' /usr/lib/lua/luci/http.lua >/dev/null 2>&1
	sed -i '/.*kB maximum content size*/c\export let HTTP_MAX_CONTENT = 1024*100;		// 100 kB maximum content size' /usr/share/ucode/luci/http.uc >/dev/null 2>&1
	uci -q delete firewall.openclash
	uci -q commit firewall
	[ -f "/etc/config/ucitrack" ] && {
	uci -q delete ucitrack.@openclash[-1]
	uci -q commit ucitrack
	}
	rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* /var/luci-indexcache /var/luci-indexcache.* >/dev/null 2>&1
	rm -rf /tmp/luci-modulecache /var/luci-modulecache >/dev/null 2>&1
	exit 0
EOF
}

pack_ipk() {
  local stage="$WORK/ipk-root"
  local control_dir="$WORK/ipk-control"
  mkdir -p "$stage" "$control_dir"
  stage_files "$stage"

  local installed_size
  installed_size="$(find "$stage" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"

  cat > "$control_dir/control" <<EOF
Package: $PKG_NAME
Version: $IPK_VERSION
Depends: $DEPENDS_IPK
Source: package/luci-app-openclash
SourceName: luci-app-openclash
Section: luci
Maintainer: $MAINTAINER
Architecture: all
Installed-Size: $installed_size
Description:  $DESCRIPTION
EOF

  write_preinst "$control_dir/preinst"
  write_prerm_pkg "$control_dir/prerm-pkg"
  write_postrm "$control_dir/postrm"
  write_script "$control_dir/postinst-pkg" <<'EOF'
#!/bin/sh
	exit 0
EOF
  write_script "$control_dir/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF
  write_script "$control_dir/prerm" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF

  local data_tar="$WORK/data.tar.gz"
  local control_tar="$WORK/control.tar.gz"
  tar --numeric-owner --owner=0 --group=0 --mtime='@0' -C "$stage" -czf "$data_tar" .
  tar --numeric-owner --owner=0 --group=0 --mtime='@0' -C "$control_dir" -czf "$control_tar" .
  printf '2.0\n' > "$WORK/debian-binary"

  local ipk="$OUT_DIR/${PKG_NAME}_${IPK_VERSION}_all.ipk"
  tar --numeric-owner --owner=0 --group=0 --mtime='@0' -C "$WORK" -czf "$ipk" debian-binary data.tar.gz control.tar.gz
  echo "wrote $ipk ($(wc -c < "$ipk") bytes)"
}

pack_apk() {
  if [ -z "$APK_BIN" ]; then
    echo "apk mkpkg not found; skip .apk (set APK_BIN to apk-tools 3.x)" >&2
    return 1
  fi

  local stage="$WORK/apk-root"
  local scripts="$WORK/apk-scripts"
  mkdir -p "$stage" "$scripts"
  stage_files "$stage"

  mkdir -p "$stage/lib/apk/packages"
  (cd "$stage" && find . -type f -o -type l | sed 's|^\.||' | sort > "$stage/lib/apk/packages/${PKG_NAME}.list")

  write_preinst "$scripts/preinst"
  write_prerm_pkg "$scripts/prerm-pkg"
  write_postrm "$scripts/postrm"
  write_script "$scripts/postinst-pkg" <<'EOF'
#!/bin/sh
	exit 0
EOF

  write_script "$scripts/post-install" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-openclash"
add_group_and_user
default_postinst
exit 0
EOF

  write_script "$scripts/pre-install" <<'EOF'
#!/bin/sh
	if [ -f "/etc/config/openclash" ] && [ ! -f "/tmp/openclash.bak" ]; then
		cp -f "/etc/config/openclash" "/tmp/openclash.bak" >/dev/null 2>&1
		cp -rf "/etc/openclash" "/tmp/openclash" >/dev/null 2>&1
		cp -rf "/usr/share/openclash/ui" "/tmp/openclash_ui" >/dev/null 2>&1
		cp -rf "/www/luci-static/resources/openclash/pac" "/tmp/pac" >/dev/null 2>&1
	fi
	exit 0
EOF

  write_script "$scripts/pre-upgrade" <<'EOF'
#!/bin/sh
export PKG_UPGRADE=1
	if [ -f "/etc/config/openclash" ] && [ ! -f "/tmp/openclash.bak" ]; then
		cp -f "/etc/config/openclash" "/tmp/openclash.bak" >/dev/null 2>&1
		cp -rf "/etc/openclash" "/tmp/openclash" >/dev/null 2>&1
		cp -rf "/usr/share/openclash/ui" "/tmp/openclash_ui" >/dev/null 2>&1
		cp -rf "/www/luci-static/resources/openclash/pac" "/tmp/pac" >/dev/null 2>&1
	fi
	exit 0
EOF

  write_script "$scripts/post-upgrade" <<'EOF'
#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-openclash"
add_group_and_user
default_postinst
exit 0
EOF

  write_script "$scripts/pre-deinstall" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-openclash"
default_prerm
	[ -n "$(pidof clash)" ] && /etc/init.d/openclash stop 2>/dev/null
	if [ -f "/etc/config/openclash" ] && [ ! -f "/tmp/openclash.bak" ]; then
		cp -f "/etc/config/openclash" "/tmp/openclash.bak" >/dev/null 2>&1
		cp -rf "/etc/openclash" "/tmp/openclash" >/dev/null 2>&1
		cp -rf "/usr/share/openclash/ui" "/tmp/openclash_ui" >/dev/null 2>&1
		cp -rf "/www/luci-static/resources/openclash/pac" "/tmp/pac" >/dev/null 2>&1
	fi
	exit 0
EOF

  local apk="$OUT_DIR/${PKG_NAME}-${APK_VERSION}.apk"
  SOURCE_DATE_EPOCH=0 "$APK_BIN" mkpkg \
    --info "name:$PKG_NAME" \
    --info "version:$APK_VERSION" \
    --info "description:$DESCRIPTION" \
    --info "arch:noarch" \
    --info "origin:feeds/base/luci-app-openclash" \
    --info "maintainer:$MAINTAINER" \
    --info "license:MIT" \
    --info "url:https://github.com/Ahmedeisa25/OpenClash" \
    --info "provides:${PKG_NAME}-any" \
    --info "tags:openwrt:section=luci" \
    --info "depends:$DEPENDS_APK" \
    --script "pre-install:$scripts/pre-install" \
    --script "post-install:$scripts/post-install" \
    --script "pre-upgrade:$scripts/pre-upgrade" \
    --script "post-upgrade:$scripts/post-upgrade" \
    --script "pre-deinstall:$scripts/pre-deinstall" \
    --script "post-deinstall:$scripts/postrm" \
    --files "$stage" \
    --output "$apk"

  echo "wrote $apk ($(wc -c < "$apk") bytes)"
  "$APK_BIN" adbdump "$apk" | awk '
    /^info:/{p=1}
    /^paths:/{exit}
    p
  '
}

mkdir -p "$OUT_DIR"
pack_ipk
pack_apk
ls -lh "$OUT_DIR"/${PKG_NAME}*
