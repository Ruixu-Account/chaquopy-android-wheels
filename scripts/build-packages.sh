#!/usr/bin/env bash
# 批量构建 Android arm64 wheel
#
# 环境变量：
#   PYTHON_VER       - 如 "3.12"
#   PACKAGES_INPUT   - 逗号/空格/换行分隔的 "package==version"（批量，优先）
#   SINGLE_PACKAGE   - 单包名（PACKAGES_INPUT 为空时用）
#   SINGLE_VERSION   - 单包版本
#   RUSTUP_TOOLCHAIN - 可选，指定给 cargo 用的工具链，覆盖 sdist 里的 rust-toolchain.toml

set -euo pipefail

readonly PYPI_DIR="/opt/chaquopy/server/pypi"
readonly WHEELS_DIR="/tmp/all-wheels"
readonly WS="${GITHUB_WORKSPACE:-/home/runner/work/chaquopy-android-wheels/chaquopy-android-wheels}"
readonly RUST_TARGET="aarch64-linux-android"

mkdir -p "$WHEELS_DIR"

# ============================================================
# 通用辅助
# ============================================================

# PEP 503 规范化：小写 + [-_.]+ → -
normalize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[-_.]\+/-/g'
}

# 关闭 Cargo.toml 里的 LTO / codegen-units，避免交叉编译慢到超时
patch_cargo_toml() {
    local manifest="$1"
    [ -f "$manifest" ] || return 0
    sed -i -E \
        -e 's/^lto[[:space:]]*=[[:space:]]*(true|"fat"|"thin")/lto = false/' \
        -e 's/^codegen-units[[:space:]]*=[[:space:]]*1/codegen-units = 16/' \
        "$manifest"
}

# 确保 Rust Android target 已安装（幂等）
ensure_rust_target() {
    if ! command -v rustup >/dev/null 2>&1; then
        echo "⚠️  rustup 未安装，跳过 Rust target 检查" >&2
        return 0
    fi

    local installed
    installed=$(rustup target list --installed 2>/dev/null || true)
    if grep -qx "$RUST_TARGET" <<< "$installed"; then
        echo "✅ Rust target 已安装: $RUST_TARGET"
        return 0
    fi

    echo "⬇️  安装 Rust target: $RUST_TARGET"
    rustup target add "$RUST_TARGET"
}

# 运行 build-wheel.py，失败时打印日志尾部
#   用法: run_build_wheel <recipe_dir> <log_file> [extra_env...]
run_build_wheel() {
    local recipe_dir="$1"
    local log="$2"
    shift 2

    ( cd "$PYPI_DIR" && env "$@" python build-wheel.py \
        --python "$PYTHON_VER" \
        --abi arm64-v8a \
        "$recipe_dir" > "$log" 2>&1 )
}

# 把 dist/<name>/ 下的 android wheel 拷到 $WHEELS_DIR
collect_wheels() {
    local pkg="$1"
    local norm
    norm=$(normalize_name "$pkg")
    local src_dir="$PYPI_DIR/dist/$norm"
    [ -d "$src_dir" ] || return 0
    find "$src_dir" -name "*android_*.whl" -exec cp -f {} "$WHEELS_DIR/" \;
}

# ============================================================
# 路径 1：预构建 wheel 优先
# ============================================================
try_prebuilt() {
    local pkg="$1" ver="$2"
    local norm
    norm=$(normalize_name "$pkg")
    local dir="$PYPI_DIR/dist/$norm"
    [ -d "$dir" ] || return 1

    # 精确匹配 <norm>-<ver>-*.whl，避免 1.26 命中 1.26.2
    local hit
    hit=$(find "$dir" -maxdepth 1 -name "${norm}-${ver}-*android_*.whl" 2>/dev/null | head -1)
    if [ -n "$hit" ]; then
        echo "✅ 使用预构建 wheel: $hit"
        cp -f "$hit" "$WHEELS_DIR/"
        return 0
    fi
    return 1
}

# ============================================================
# 路径 2：faiss 专用
# ============================================================
build_faiss() {
    local ver="$1"
    local recipe_dir="$PYPI_DIR/packages/astrbot-faiss-cpu"
    local log="/tmp/build-faiss.log"

    echo "🔧 faiss 专用构建流程"
    rm -rf "$recipe_dir"
    mkdir -p "$recipe_dir"

    cat > "$recipe_dir/meta.yaml" <<EOF
package:
  name: faiss-cpu
  version: "$ver"
source:
  git_url: https://github.com/facebookresearch/faiss
  git_rev: v$ver
build:
  number: 0
  script_env:
    - CMAKE_ARGS=-DFAISS_ENABLE_GPU=OFF -DFAISS_ENABLE_PYTHON=ON -DFAISS_OPT_LEVEL=generic -DBUILD_TESTING=OFF -DCMAKE_BUILD_PARALLEL_LEVEL=1
requirements:
  build:
    - cmake 3.24.0
    - setuptools 69.0.2
    - wheel 0.42.0
    - numpy 2.5.3
  host:
    - python
    - numpy 2.5.3
    - chaquopy-openblas 0.2.20
EOF

    if ! run_build_wheel "$recipe_dir" "$log" CARGO_BUILD_JOBS=1; then
        echo "❌ faiss 构建失败，最后 80 行："
        tail -80 "$log"
        return 1
    fi
    collect_wheels "faiss-cpu"
}

# ============================================================
# 路径 3：官方 recipe
# ============================================================
build_from_official_recipe() {
    local pkg="$1" ver="$2"
    local pkg_lower
    pkg_lower=$(normalize_name "$pkg")
    local official="$PYPI_DIR/packages/$pkg_lower"
    local recipe_dir="$PYPI_DIR/packages/astrbot-$pkg"
    local log="/tmp/build-$pkg.log"

    [ -d "$official" ] && [ -f "$official/meta.yaml" ] || return 1

    echo "✅ 使用官方 recipe: $pkg_lower"
    rm -rf "$recipe_dir"
    cp -a "$official" "$recipe_dir"

    # 用文本级替换，不完整 load/dump，保留 recipe 原格式
    python3 - "$recipe_dir/meta.yaml" "$pkg_lower" "$ver" <<'PYEOF'
import os, re, sys
from jinja2 import Template, StrictUndefined

meta_file, pkg, ver = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(meta_file).read()

# 1. 渲染 Jinja（PY_VER 从环境读）
try:
    rendered = Template(raw, undefined=StrictUndefined).render(
        PY_VER=os.environ.get("PYTHON_VER", "3.12")
    )
except Exception as e:
    print(f"Jinja render failed: {e}", file=sys.stderr)
    sys.exit(1)

# 2. 文本级替换 package.version 和 source 版本号
#    （保留其他结构，避免 yaml.dump 破坏 recipe 格式）
out = rendered

# 替换 package.version
out = re.sub(
    r'(^\s*version:\s*)(?:"[^"]*"|\'[^\']*\'|[^\s#]+)',
    rf'\g<1>"{ver}"',
    out, count=1, flags=re.MULTILINE
)

# 替换 source.url 里的版本号
out = re.sub(
    rf'{re.escape(pkg)}-[\d.]+\.(tar\.gz|zip|tgz|tar\.bz2)',
    rf'{pkg}-{ver}.tar.gz', out, flags=re.IGNORECASE
)

# 移除 sha256/md5（若版本变了则失效）
out = re.sub(r'^\s*(sha256|md5):.*$\n?', '', out, flags=re.MULTILINE)

# 替换 source.git_rev 的版本号部分
def repl_git_rev(m):
    prefix = m.group(1)
    return f'{m.group(0).split(":")[0]}: {prefix}{ver}'
out = re.sub(
    r'^\s*git_rev:\s*([^\d\n]*)[\d.]+',
    repl_git_rev, out, flags=re.MULTILINE
)

open(meta_file, "w").write(out)
print(out)
PYEOF

    [ -f "$WS/LICENSE" ] && [ ! -f "$recipe_dir/LICENSE" ] && \
        cp "$WS/LICENSE" "$recipe_dir/LICENSE"
    patch_cargo_toml "$recipe_dir/src/Cargo.toml"

    if ! run_build_wheel "$recipe_dir" "$log"; then
        echo "❌ 官方 recipe 构建失败，最后 60 行："
        tail -60 "$log"
        return 1
    fi
    collect_wheels "$pkg"
}

# ============================================================
# 路径 4：PyPI 裸 sdist
# ============================================================
build_from_pypi() {
    local pkg="$1" ver="$2"
    local recipe_dir="$PYPI_DIR/packages/astrbot-$pkg"
    local log="/tmp/build-$pkg.log"

    echo "ℹ️  官方没有 $pkg 的 recipe，走 PyPI 流程"
    rm -rf "$recipe_dir"
    mkdir -p "$recipe_dir/src"

    local json="/tmp/pypi-$pkg.json"
    if ! curl -sf "https://pypi.org/pypi/$pkg/$ver/json" -o "$json"; then
        echo "ERROR: $pkg==$ver 在 PyPI 上不存在"
        return 1
    fi

    local sdist_url
    sdist_url=$(jq -r '.urls[] | select(.packagetype=="sdist") | .url' "$json" | head -n1)
    if [ -z "$sdist_url" ] || [ "$sdist_url" = "null" ]; then
        echo "ERROR: $pkg==$ver 没有 sdist"
        jq -r '.urls[].filename' "$json"
        return 1
    fi

    echo "下载 sdist: $sdist_url"
    local tarball="/tmp/sdist-$pkg.tar.gz"
    wget -q "$sdist_url" -O "$tarball"
    tar -xzf "$tarball" -C /tmp

    local src_dir="/tmp/$pkg-$ver"
    [ -d "$src_dir" ] || src_dir="/tmp/${pkg//-/_}-$ver"
    if [ ! -d "$src_dir" ]; then
        src_dir=$(find /tmp -maxdepth 1 -type d -name "*${ver}*" \
            -not -name "inject*" -not -name "sdist*" | head -1)
    fi
    if [ ! -d "$src_dir" ]; then
        echo "ERROR: 找不到 sdist 解压目录"
        return 1
    fi
    echo "源目录: $src_dir"
    cp -a "$src_dir/." "$recipe_dir/src/"

    if [ -f "$WS/LICENSE" ]; then
        cp "$WS/LICENSE" "$recipe_dir/LICENSE"
    else
        echo "MIT License placeholder" > "$recipe_dir/LICENSE"
    fi

    local has_rust="no"
    if [ -f "$recipe_dir/src/Cargo.toml" ]; then
        has_rust="yes"
        patch_cargo_toml "$recipe_dir/src/Cargo.toml"
    fi

    {
        echo "package:"
        echo "  name: $pkg"
        echo "  version: $ver"
        echo "build:"
        echo "  number: 0"
        echo "  script_env: []"
        echo "source:"
        echo "  path: src"
        echo "requirements:"
        if [ "$has_rust" = "yes" ]; then
            echo "  build:"
            echo "    - rust"
        fi
        echo "  host:"
        echo "    - python"
    } > "$recipe_dir/meta.yaml"

    if ! run_build_wheel "$recipe_dir" "$log"; then
        echo "❌ 构建失败，最后 60 行日志："
        tail -60 "$log"
        return 1
    fi
    collect_wheels "$pkg"
}

# ============================================================
# 单包调度
# ============================================================
build_one() {
    local pkg="$1" ver="$2"
    local pkg_norm
    pkg_norm=$(normalize_name "$pkg")

    # 0. 预构建优先
    if try_prebuilt "$pkg" "$ver"; then
        return 0
    fi

    # 1. faiss 专用
    if [ "$pkg_norm" = "faiss-cpu" ] || [ "$pkg_norm" = "faiss" ]; then
        ensure_rust_target
        build_faiss "$ver"
        return $?
    fi

    # 2. 官方 recipe
    if build_from_official_recipe "$pkg" "$ver"; then
        return 0
    fi

    # 3. PyPI 裸包
    ensure_rust_target
    build_from_pypi "$pkg" "$ver"
}

# ============================================================
# 解析包列表
# ============================================================
parse_packages() {
    if [ -n "${PACKAGES_INPUT:-}" ]; then
        echo "$PACKAGES_INPUT"
    elif [ -n "${SINGLE_PACKAGE:-}" ] && [ -n "${SINGLE_VERSION:-}" ]; then
        echo "${SINGLE_PACKAGE}==${SINGLE_VERSION}"
    else
        echo "ERROR: 未指定包" >&2
        exit 1
    fi \
        | sed 's/,/ /g' \
        | tr ' ' '\n' \
        | tr -d '\r' \
        | sed 's/#.*//' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$' \
        | sort -u
}

# ============================================================
# 主流程
# ============================================================
main() {
    parse_packages > /tmp/packages.txt

    echo "=== 要构建的包 ==="
    cat /tmp/packages.txt
    echo "====================="

    ensure_rust_target

    local succeeded=() failed=()

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        if [[ "$line" != *"=="* ]]; then
            echo "跳过无效行: $line"
            continue
        fi

        local pkg="${line%%==*}"
        local ver="${line##*==}"
        pkg="${pkg// /}"
        ver="${ver// /}"

        if [ -z "$pkg" ] || [ -z "$ver" ]; then
            echo "跳过无效行: $line"
            continue
        fi

        echo ""
        echo "========================================"
        echo "构建 $pkg==$ver"
        echo "========================================"

        if build_one "$pkg" "$ver"; then
            succeeded+=("$pkg==$ver")
            echo "✅ $pkg==$ver 成功"
        else
            failed+=("$pkg==$ver")
            echo "❌ $pkg==$ver 失败"
        fi
    done < /tmp/packages.txt

    echo ""
    echo "============================================"
    echo "构建汇总"
    echo "============================================"
    echo "成功: ${succeeded[*]:-（无）}"
    echo "失败: ${failed[*]:-（无）}"
    echo "============================================"

    echo "=== 收集到的 wheel ==="
    ls -la "$WHEELS_DIR"

    [ ${#failed[@]} -eq 0 ]
}

main "$@"
