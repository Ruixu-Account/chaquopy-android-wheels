#!/bin/bash
# 下载 Chaquopy 官方预编译依赖到 dist/ 供 lxml/pillow/numpy 等使用

set -eu

PYPI_DIR="/opt/chaquopy/server/pypi"
DIST_DIR="$PYPI_DIR/dist"

# 格式: "<pkg_dir>/<wheel_filename>"
DEPS=(
  "chaquopy-libxml2/chaquopy_libxml2-2.9.8-1-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-libxslt/chaquopy_libxslt-1.1.32-1-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-libjpeg/chaquopy_libjpeg-1.5.3-1-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-libpng/chaquopy_libpng-1.6.34-1-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-freetype/chaquopy_freetype-2.9.1-2-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-libffi/chaquopy_libffi-3.3-3-py3-none-android_24_arm64_v8a.whl"
  "chaquopy-libgfortran/chaquopy_libgfortran-4.9-0-py3-none-android_21_arm64_v8a.whl"
  "chaquopy-openblas/chaquopy_openblas-0.2.20-5-py3-none-android_21_arm64_v8a.whl"
)

for dep in "${DEPS[@]}"; do
  pkg_dir=$(dirname "$dep")
  file=$(basename "$dep")
  target_dir="$DIST_DIR/$pkg_dir"
  mkdir -p "$target_dir"
  if [ -f "$target_dir/$file" ]; then
    echo "✅ 已存在: $pkg_dir/$file"
    continue
  fi
  url="https://chaquo.com/pypi-13.1/$pkg_dir/$file"
  echo "⬇️  下载: $url"
  if ! wget -q --tries=3 --timeout=60 "$url" -O "$target_dir/$file"; then
    echo "❌ 下载失败: $url"
    exit 1
  fi
done

echo ""
echo "=== dist/ 汇总 ==="
find "$DIST_DIR" -name "*.whl" -exec ls -la {} \;
