#!/bin/bash
# 下载 Chaquopy 官方预编译依赖到 dist/，供后续构建使用

set -eu

PYPI_DIR="/opt/chaquopy/server/pypi"
DIST_DIR="$PYPI_DIR/dist"

# ===== 编译依赖（chaquopy-* 系列）=====
DEPS=(
  "chaquopy-libxml2/chaquopy_libxml2-2.9.8-1-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-libxslt/chaquopy_libxslt-1.1.32-1-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-libjpeg/chaquopy_libjpeg-1.5.3-1-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-libpng/chaquopy_libpng-1.6.34-1-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-freetype/chaquopy_freetype-2.9.1-2-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-libffi/chaquopy_libffi-3.3-3-py3-none-android_24_arm64_v8a.whl"
  "chaquopy-libgfortran/chaquopy_libgfortran-4.9-0-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-openblas/chaquopy_openblas-0.2.20-5-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-libyaml/chaquopy_libyaml-0.2.5-0-py3-none-android_24_arm64_v8a.whl"
)

# ===== 预构建最终产物（直接使用，跳过编译）=====
PREBUILT=(
  "lxml/lxml-5.3.0-0-cp312-cp312-android_24_arm64_v8a.whl"
)

download_one() {
  local item="$1"
  local label="$2"
  local pkg_dir file target_dir url
  pkg_dir=$(dirname "$item")
  file=$(basename "$item")
  target_dir="$DIST_DIR/$pkg_dir"
  mkdir -p "$target_dir"

  if [ -f "$target_dir/$file" ]; then
    echo "✅ 已存在: $pkg_dir/$file"
    return 0
  fi

  url="https://chaquo.com/pypi-13.1/$pkg_dir/$file"
  echo "⬇️  $label: $url"
  if ! wget -q --tries=3 --timeout=60 "$url" -O "$target_dir/$file"; then
    echo "❌ 下载失败: $url"
    return 1
  fi
}

echo "=== 下载依赖 ==="
for dep in "${DEPS[@]}"; do
  download_one "$dep" "依赖" || exit 1
done

echo ""
echo "=== 下载预构建 ==="
for item in "${PREBUILT[@]}"; do
  download_one "$item" "预构建" || exit 1
done

echo ""
echo "=== dist/ 汇总 ==="
find "$DIST_DIR" -name "*.whl" -exec ls -la {} \;
