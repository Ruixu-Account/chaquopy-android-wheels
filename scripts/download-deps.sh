#!/usr/bin/env bash
# 下载 Chaquopy 官方预编译依赖 + 自有 Release 产物到 dist/，
# 供 build-wheel.py 作为本地 pip 索引使用。
#
# 三个来源：
#   1. chaquopy-* 系列编译依赖（chaquo.com/pypi-13.1）
#   2. Chaquopy 预构建的最终产物（lxml / cryptography / pandas）
#   3. 自有 GitHub Release（numpy 2.5.3 等）
#
# 设计要点：
#   - 单一 manifest 列表，避免三段重复代码
#   - --retry-connrefused + --waitretry，缓解 GitHub 偶发 5xx
#   - 区分 404（硬失败）与 5xx/超时（重试）
#   - 结束时打印 manifest，便于 CI 核对

set -euo pipefail

readonly PYPI_DIR="/opt/chaquopy/server/pypi"
readonly DIST_DIR="${PYPI_DIR}/dist"

# Chaquopy 官方预编译仓库（保持原 URL，如失效请改这里）
readonly CHAQUOPY_BASE="https://chaquo.com/pypi-13.1"

# 自有 GitHub Release
readonly OWN_BASE="https://github.com/Ruixu-Account/chaquopy-android-wheels/releases/download/latest"

# ============================================================
# Manifest: 每行一个条目，格式 "<source>|<relative_path>"
#   source ∈ { chaquopy, own }
# ============================================================
readonly MANIFEST=$(cat <<'EOF'
# ── Chaquopy 官方编译依赖（chaquopy-*）────────────────────
chaquopy|chaquopy-libxml2/chaquopy_libxml2-2.9.8-1-py3-none-android_21_arm64_v8a.whl
chaquopy|chaquopy-libxslt/chaquopy_libxslt-1.1.32-1-py3-none-android_21_arm64_v8a.whl
chaquopy|chaquopy-libjpeg/chaquopy_libjpeg-1.5.3-1-py3-none-android_21_arm64_v8a.whl
chaquopy|chaquopy-libpng/chaquopy_libpng-1.6.34-1-py3-none-android_21_arm64_v8a.whl
chaquopy|chaquopy-freetype/chaquopy_freetype-2.9.1-2-py3-none-android_21_arm64_v8a.whl
chaquopy|chaquopy-libffi/chaquopy_libffi-3.3-3-py3-none-android_24_arm64_v8a.whl
chaquopy|chaquopy-libyaml/chaquopy_libyaml-0.2.5-0-py3-none-android_24_arm64_v8a.whl

# scipy 依赖（编译期 host 依赖）
chaquopy|chaquopy-libgfortran/chaquopy_libgfortran-4.9-0-py3-none-android_21_arm64_v8a.whl
chaquopy|chaquopy-openblas/chaquopy_openblas-0.2.20-5-py3-none-android_21_arm64_v8a.whl

# ── Chaquopy 预构建最终产物 ─────────────────────────────
chaquopy|lxml/lxml-5.3.0-0-cp312-cp312-android_24_arm64_v8a.whl
chaquopy|cryptography/cryptography-42.0.8-0-cp312-cp312-android_24_arm64_v8a.whl
chaquopy|pandas/pandas-2.1.3-0-cp312-cp312-android_21_arm64_v8a.whl

# ── 自有 Release 产物 ──────────────────────────────────
own|numpy/numpy-2.5.3-0-cp312-cp312-android_24_arm64_v8a.whl
EOF
)

# ============================================================
# 下载单个文件
#   参数: <source> <relative_path>
#   返回: 0 成功; 非 0 失败（脚本会因 set -e 退出）
# ============================================================
download_one() {
  local source="$1"
  local rel="$2"

  local base url target_dir file
  case "$source" in
    chaquopy) base="$CHAQUOPY_BASE" ;;
    own)      base="$OWN_BASE" ;;
    *)        echo "❌ 未知来源: $source" >&2; return 2 ;;
  esac

  file="$(basename "$rel")"
  target_dir="${DIST_DIR}/$(dirname "$rel")"
  url="${base}/${rel}"

  mkdir -p "$target_dir"

  # 幂等：已存在则跳过
  if [ -s "$target_dir/$file" ]; then
    echo "✅ 已存在: $(dirname "$rel")/$file"
    return 0
  fi

  echo "⬇️  [${source}] ${url}"

  # wget 退出码：
  #   0   成功
  #   8   服务端错误（5xx）—— 可重试
  #   4   网络故障 —— 可重试
  #   6   认证失败 —— 硬失败
  #   8   服务器错误 —— 可重试
  #  其他 硬失败
  local rc=0
  wget \
    --tries=4 \
    --waitretry=3 \
    --retry-connrefused \
    --timeout=60 \
    --show-progress \
    --no-verbose \
    -O "$target_dir/$file" \
    "$url" || rc=$?

  if [ $rc -ne 0 ]; then
    rm -f "$target_dir/$file"
    echo "❌ 下载失败 (wget rc=$rc): $url" >&2
    return $rc
  fi
}

# ============================================================
# 主流程
# ============================================================
main() {
  echo "=== 下载依赖 → ${DIST_DIR} ==="

  local line source rel
  local total=0 ok=0

  while IFS= read -r line; do
    # 跳过空行和注释
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    source="${line%%|*}"
    rel="${line#*|}"
    total=$((total + 1))
    download_one "$source" "$rel" && ok=$((ok + 1))
  done <<< "$MANIFEST"

  echo ""
  echo "=== 汇总: ${ok}/${total} 就绪 ==="
  echo ""
  echo "=== dist/ 内容 ==="
  find "$DIST_DIR" -name "*.whl" -printf '%10s  %p\n' | sort -k2
}

main "$@"
