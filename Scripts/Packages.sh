#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 重写要点：
#   1) 全程基于 SCRIPT_DIR 锚定路径，不依赖 CWD
#   2) PKG_LIST 模糊删除改为读 feeds/*.index 精确反查，不再误删公共包
#   3) 哈希改为在 dl/ 已下载文件上计算，避免 tarball 时间字段导致校验失败
#   4) 去掉 dpkg / grep -Po / echo -e 等不可移植依赖
#   5) 主题固化前校验目录存在，失败时回退到 bootstrap，防 LuCI 白屏
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
: "${GITHUB_WORKSPACE:=${REPO_ROOT}}"

# 优先使用 OpenWrt 自带的下载缓存目录
DL_DIR="${REPO_ROOT}/dl"

# ---------- 工具函数 ----------

# 纯 bash 版本比较，替代 dpkg --compare-versions
ver_lt() {
	local i x y
	local -a a b
	IFS=. read -r -a a <<<"$1"
	IFS=. read -r -a b <<<"$2"
	unset IFS
	for ((i=0; i<${#a[@]} || i<${#b[@]}; i++)); do
		local x=${a[i]:-0} y=${b[i]:-0}
		x=${x%%[!0-9]*}; y=${y%%[!0-9]*}
		x=${x:-0}; y=${y:-0}
		((x < y)) && return 0
		((x > y)) && return 1
	done
	return 1
}

# 从 feeds index 精确反查 Makefile 所在目录，避免 -iname 误删公共包
feed_dirs_of() {
	local name=$1
	local idx dir
	for idx in "${REPO_ROOT}"/../feeds/*.index; do
		[ -f "$idx" ] || continue
		# index 格式: Source-Makefile: feeds/xxx/<path>/<name>/Makefile
		dir=$(awk -v n="$name" '
			$0 ~ "^Source-Makefile:" {
				if ($0 ~ "/" n "/Makefile" || $0 ~ "/" n "$") {
					sub(/^Source-Makefile:[ \t]*/, "")
					sub(/\/Makefile$/, "")
					print $0
					exit
				}
			}' "$idx")
		[ -n "$dir" ] && [ -d "${REPO_ROOT}/${dir}" ] && printf '%s\n' "${REPO_ROOT}/${dir}"
	done
}

# 取最新 release tag，兼容 GitHub API 限流（退化为本地 ls-remote）
latest_tag() {
	local repo=$1
	local prerelease=$2
	local tag

	if [ "$prerelease" = true ]; then
		tag=$(curl -sL --max-time 20 "https://api.github.com/repos/${repo}/releases" \
			| awk -F'"' '/"tag_name":/ {print $4; exit}')
	else
		tag=$(curl -sL --max-time 20 "https://api.github.com/repos/${repo}/releases" \
			| awk -F'"' 'BEGIN{found=0}
				/"prerelease": *true/ {found=1}
				/"tag_name":/ {if (!found) {print $4; exit} else found=0}')
	fi

	if [ -z "$tag" ]; then
		# 限流/失败时兜底：取远端最新 tag
		tag=$(git ls-remote --tags --sort=-v:refname "https://github.com/${repo}.git" \
			| awk -F'/' '/refs\/tags\//{sub(/\^{}$/,"",$3); print $3; exit}')
	fi
	echo "$tag"
}

# ---------- 核心函数 ----------

UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=${4:-}
	local PKG_EXTRA=${5:-}
	local REPO_NAME=${PKG_REPO##*/}

	# 合并主包名与额外名，统一去重去空
	local -a RAW=("$PKG_NAME")
	[ -n "$PKG_EXTRA" ] && IFS=' ' read -r -a RAW <<<"${RAW[*]} $PKG_EXTRA"
	unset IFS
	local -A SEEN=()
	local -a PKG_LIST=()
	local t
	for t in "${RAW[@]}"; do
		[ -z "$t" ] && continue
		[ -z "${SEEN[$t]:-}" ] || continue
		SEEN[$t]=1
		PKG_LIST+=("$t")
	done

	printf '\n====== %s (%s) ======\n' "$PKG_NAME" "$PKG_REPO"

	# 1) 精确删除：只删 feeds index 里登记过的同名包
	local d name
	for name in "${PKG_LIST[@]}"; do
		while read -r d; do
			[ -z "$d" ] && continue
			rm -rf "$d"
			printf 'delete: %s\n' "$d"
		done < <(feed_dirs_of "$name")
	done

	# 2) 删除本次克隆的残留目录，避免 find 不到导致的通配字面值
	rm -rf "${REPO_ROOT:?}/${REPO_NAME}"

	# 3) 克隆：tag 与 branch 自动识别（缓存 tag 列表，减少一次网络请求）
	local TAGS
	TAGS=$(git ls-remote --tags "https://github.com/${PKG_REPO}.git" 2>/dev/null || true)
	if printf '%s\n' "$TAGS" | grep -q "refs/tags/${PKG_BRANCH}$"; then
		printf 'tag mode: %s\n' "$PKG_BRANCH"
		git clone --depth=1 "https://github.com/${PKG_REPO}.git" "$REPO_NAME"
		git -C "$REPO_NAME" fetch --depth=1 origin "refs/tags/${PKG_BRANCH}:refs/tags/${PKG_BRANCH}"
		git -C "$REPO_NAME" checkout -q "refs/tags/${PKG_BRANCH}"
	else
		printf 'branch mode: %s\n' "$PKG_BRANCH"
		git clone --depth=1 --single-branch --branch "$PKG_BRANCH" \
			"https://github.com/${PKG_REPO}.git" "$REPO_NAME"
	fi

	# 4) 后处理
	if [ "$PKG_SPECIAL" = "pkg" ]; then
		# 只处理目录存在的情况，规避空目录通配报错
		if [ -d "$REPO_NAME" ]; then
			find "$REPO_NAME" -maxdepth 3 -type d -iname "*${PKG_NAME}*" -prune -exec cp -rf {} ./ \;
		fi
		rm -rf "$REPO_NAME"
	elif [ "$PKG_SPECIAL" = "name" ]; then
		mv -f -- "$REPO_NAME" "$PKG_NAME"
	fi
}

UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-false}
	local PKG_FILE

	while read -r PKG_FILE; do
		[ -z "$PKG_FILE" ] && continue
		[ -f "$PKG_FILE" ] || continue

		printf '\n%s version update has started!\n' "$PKG_NAME"

		# 用 awk 替代 grep -Po，兼容 busybox / macOS
		local PKG_REPO PKG_URL OLD_VER OLD_FILE OLD_HASH
		PKG_REPO=$(awk -F'=' '/^PKG_SOURCE_URL:/ {
				if ($0 ~ /github\.com\//) {
					sub(/.*github\.com\//, "", $2)
					sub(/\.git.*/, "", $2)
					print $2; exit
				}
			}' "$PKG_FILE")

		OLD_VER=$(awk -F= '/^PKG_VERSION:/ {print $2; exit}' "$PKG_FILE")
		PKG_URL=$(awk -F= '/^PKG_SOURCE_URL:/ {print $2; exit}' "$PKG_FILE")
		OLD_FILE=$(awk -F= '/^PKG_SOURCE:/ {print $2; exit}' "$PKG_FILE")
		OLD_HASH=$(awk -F= '/^PKG_HASH:/ {print $2; exit}' "$PKG_FILE")

		[ -z "$PKG_REPO" ] && { echo "cannot parse repo from $PKG_FILE"; continue; }

		local PKG_TAG
		PKG_TAG=$(latest_tag "$PKG_REPO" "$PKG_MARK")
		[ -z "$PKG_TAG" ] && { echo "$PKG_FILE: no release tag"; continue; }

		# 规范化版本号：v1.2.3 -> 1.2.3；纯字母 tag 丢弃
		local NEW_VER
		NEW_VER=$(printf '%s\n' "$PKG_TAG" | sed -E 's/^v//; s/[^0-9]+/\./g; s/^\.|\.$//g')
		[[ "$NEW_VER" =~ ^[0-9] ]] || { echo "$PKG_FILE: tag $PKG_TAG not version-like, skip"; continue; }

		# 构造下载 URL（变量展开用 sed 安全替换）
		local NEW_URL
		if [[ "$PKG_URL" == *"releases"* ]]; then
			NEW_URL="${PKG_URL%/}/${OLD_FILE}"
		else
			NEW_URL="${PKG_URL%/}"
		fi
		NEW_URL=$(printf '%s' "$NEW_URL" | sed \
			-e "s#\$(PKG_VERSION)#$NEW_VER#g" \
			-e "s#\$(PKG_NAME)#$PKG_NAME#g" \
			-e "s#@VERSION@#$NEW_VER#g")

		# 优先复用 dl/ 中已下载文件，失败再临时下载
		local ARCHIVE NEW_HASH TMPDIR
		ARCHIVE=""
		if [ -d "$DL_DIR" ]; then
			ARCHIVE=$(find "$DL_DIR" -maxdepth 1 -type f \
				\( -name "${PKG_NAME}-${NEW_VER}*" -o -name "${PKG_NAME}_${NEW_VER}*" \) \
				| head -1 || true)
		fi

		if [ -n "$ARCHIVE" ] && [ -s "$ARCHIVE" ]; then
			NEW_HASH=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
			printf 'hash from dl: %s\n' "$(basename "$ARCHIVE")"
		else
			TMPDIR=$(mktemp -d)
			# shellcheck disable=SC2064
			trap "rm -rf '$TMPDIR'" RETURN
			if command -v curl >/dev/null 2>&1; then
				curl -sL --max-time 60 -o "$TMPDIR/src" "$NEW_URL"
			else
				wget -q --timeout=60 -O "$TMPDIR/src" "$NEW_URL"
			fi
			NEW_HASH=$(sha256sum "$TMPDIR/src" | cut -d' ' -f1)
		fi

		printf 'old: %s %s\n' "$OLD_VER" "$OLD_HASH"
		printf 'new: %s %s\n' "$NEW_VER" "$NEW_HASH"

		if ver_lt "$OLD_VER" "$NEW_VER"; then
			sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/" "$PKG_FILE"
			sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/" "$PKG_FILE"
			printf '%s updated!\n' "$PKG_FILE"
		else
			printf '%s is already latest\n' "$PKG_FILE"
		fi
	done < <(find "$REPO_ROOT" "$REPO_ROOT"/../feeds/packages -maxdepth 3 \
		-type f -wholename "*/${PKG_NAME}/Makefile" 2>/dev/null)
}

# ===================== 主题 =====================
# UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
# UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
# UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
# UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"
# UPDATE_PACKAGE "noobwrt" "nooblk-98/luci-theme-noobwrt" "master"
# UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"
# UPDATE_PACKAGE "theme-fluent" "LazuliKao/luci-theme-fluent" "main"

# 👇 新增主题
UPDATE_PACKAGE "luci-theme-footstrap" "VizzleTF/luci-theme-footstrap" "main"
UPDATE_PACKAGE "luci-theme-vantage" "anothaDev/luci-theme-vantage" "main"

# ===================== 网络 / 代理 =====================
UPDATE_PACKAGE "momo" "nikkinikki-org/OpenWrt-momo" "main"
UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main"
UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "dev" "pkg"
UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"

# ===================== 工具 / 系统 =====================
# UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"
UPDATE_PACKAGE "luci-app-tcpdump" "KFERMercer/luci-app-tcpdump" "master" "" "tcpdump"

UPDATE_PACKAGE "ddns-go" "sirpdboy/luci-app-ddns-go" "main"
UPDATE_PACKAGE "diskman" "sbwml/luci-app-diskman" "main"
UPDATE_PACKAGE "diskmanager" "4IceG/luci-app-mini-diskmanager" "main"
UPDATE_PACKAGE "easytier" "EasyTier/luci-app-easytier" "main"
UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"
UPDATE_PACKAGE "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox ookla-speedtest"
UPDATE_PACKAGE "netwizard" "sirpdboy/luci-app-netwizard" "main"
UPDATE_PACKAGE "openlist2" "sbwml/luci-app-openlist2" "main"
UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
UPDATE_PACKAGE "qbittorrent" "sbwml/luci-app-qbittorrent" "master" "" "qt6base qt6tools rblibtorrent"
UPDATE_PACKAGE "qmodem" "FUjr/QModem" "main"
UPDATE_PACKAGE "quickfile" "sbwml/luci-app-quickfile" "main"
UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"
UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "axonhub gecoosac sing-box luci-app-homeproxy luci-app-timewol luci-app-wolplus luci-app-wolultra"
UPDATE_PACKAGE "vnt" "lmq8267/luci-app-vnt" "main"

# ===================== LED 控制器 (雅典娜 AX6600) =====================
# UPDATE_PACKAGE "athena-led" "577090447/JDC-AX6600-Athena-LED-Controller" "main" "pkg"
# UPDATE_PACKAGE "luci-app-athena-led" "577090447/JDC-AX6600-Athena-LED-Controller" "main" "pkg"

# ========== 第三方扩展插件 ==========
echo "========================================"
echo "      EXTRA PACKAGES INSTALL START      "
echo "========================================"
UPDATE_PACKAGE "luci-app-store" "linkease/istore" "main" "" "store"
UPDATE_PACKAGE "OpenAppFilter" "destan19/OpenAppFilter" "master" "" "luci-app-appfilter oaf open-app-filter"
UPDATE_PACKAGE "harbor-file" "destan19/luci-app-harbor-file" "main" "" "luci-app-harbor-file"
echo "========================================"
echo "       EXTRA PACKAGES INSTALL DONE      "
echo "========================================"

# ===================== linkease（易有云） =====================
UPDATE_PACKAGE "linkease" "linkease/nas-packages" "master" "" "linkease"
UPDATE_PACKAGE "luci-app-linkease" "linkease/nas-packages-luci" "main" "" "luci-app-linkease luci-i18n-linkease-zh-cn"

# ===================== 私有扩展 =====================
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
	# shellcheck disable=SC1090
	source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi

# ===================== 主题固化（aurora，带兜底） =====================
DEFAULT_SET="${REPO_ROOT}/package/emortal/default-settings/files/zzz-default-settings"

# 只清理 luci.main 作用域内的 theme / mediaurlbase，避免连坐
if [ -f "$DEFAULT_SET" ]; then
	sed -i -E '/^[[:space:]]*luci\.main\..*(theme|mediaurlbase)/d' "$DEFAULT_SET"
fi

mkdir -p "${REPO_ROOT}/files/etc/uci-defaults"

# 先在构建期确认 aurora 目录存在；不存在则回退 bootstrap，保证 LuCI 能起来
THEME=aurora
if ! find "$REPO_ROOT" "$REPO_ROOT"/../feeds/luci -maxdepth 4 -type d -iname '*aurora*' \
	-exec false {} + 2>/dev/null; then
	THEME=bootstrap
	echo "WARN: aurora theme directory not found, fallback to $THEME" >&2
fi

cat > "${REPO_ROOT}/files/etc/uci-defaults/99-set-theme" <<EOF
#!/bin/sh
THEME='${THEME}'
if [ -d "/www/luci-static/\${THEME}" ]; then
	uci set luci.main.theme="\${THEME}"
	uci set luci.main.mediaurlbase="/luci-static/\${THEME}"
	uci commit luci
	rm -rf /tmp/luci-*
	/etc/init.d/uhttpd restart
fi
exit 0
EOF

chmod +x "${REPO_ROOT}/files/etc/uci-defaults/99-set-theme"
