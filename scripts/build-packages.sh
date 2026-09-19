#!/bin/bash
# 批量构建 Android arm64 wheel
# 环境变量：
#   PYTHON_VER       - 如 "3.12"
#   PACKAGES_INPUT   - 逗号/空格/换行分隔的 "package==version"（批量，优先）
#   SINGLE_PACKAGE   - 单包名（PACKAGES_INPUT 为空时用）
#   SINGLE_VERSION   - 单包版本

set -u

PYPI_DIR="/opt/chaquopy/server/pypi"
WHEELS_DIR="/tmp/all-wheels"
WS="${GITHUB_WORKSPACE:-/home/runner/work/chaquopy-android-wheels/chaquopy-android-wheels}"

mkdir -p "$WHEELS_DIR"

# ===== 1. 解析包列表 =====
if [ -n "${PACKAGES_INPUT:-}" ]; then
    RAW="$PACKAGES_INPUT"
elif [ -n "${SINGLE_PACKAGE:-}" ] && [ -n "${SINGLE_VERSION:-}" ]; then
    RAW="${SINGLE_PACKAGE}==${SINGLE_VERSION}"
else
    echo "ERROR: 未指定包"
    exit 1
fi

echo "$RAW" \
    | sed 's/,/ /g' \
    | tr ' ' '\n' \
    | tr -d '\r' \
    | sed 's/#.*//' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$' \
    | sort -u > /tmp/packages.txt

echo "=== 要构建的包 ==="
cat /tmp/packages.txt
echo "====================="

# ===== 2. 构建单个包 =====
build_one() {
    local PKG="$1"
    local VER="$2"
    local RECIPE_DIR="$PYPI_DIR/packages/astrbot-$PKG"
    local LOG="/tmp/build-$PKG.log"
    local PKG_LOWER
    PKG_LOWER=$(echo "$PKG" | tr '[:upper:]' '[:lower:]')

    # ============ 预构建 wheel 优先 ============
    local PREBUILT_DIR="$PYPI_DIR/dist/$PKG_LOWER"
    if [ -d "$PREBUILT_DIR" ]; then
        local HIT
        HIT=$(find "$PREBUILT_DIR" -name "*android_*.whl" -name "*${VER}*" 2>/dev/null | head -1)
        if [ -n "$HIT" ]; then
            echo "✅ 使用预构建 wheel: $HIT"
            cp -f "$HIT" "$WHEELS_DIR/"
            return 0
        fi
    fi

    # ============ 官方 recipe 优先 ============
    local OFFICIAL="$PYPI_DIR/packages/$PKG_LOWER"
    if [ -d "$OFFICIAL" ] && [ -f "$OFFICIAL/meta.yaml" ]; then
        echo "✅ 使用官方 recipe: $PKG_LOWER"

        rm -rf "$RECIPE_DIR"
        cp -a "$OFFICIAL" "$RECIPE_DIR"

        python3 - "$RECIPE_DIR/meta.yaml" "$PKG_LOWER" "$VER" <<'PYEOF'
import os, re, sys
import yaml
from jinja2 import Template, StrictUndefined

meta_file, pkg, ver = sys.argv[1], sys.argv[2], sys.argv[3]

with open(meta_file) as f:
    raw = f.read()

# 1. 渲染 Jinja（PY_VER 从环境变量读）
meta_vars = {"PY_VER": os.environ.get("PYTHON_VER", "3.12")}
try:
    rendered = Template(raw, undefined=StrictUndefined).render(**meta_vars)
except Exception as e:
    print(f"Jinja render failed: {e}", file=sys.stderr)
    sys.exit(1)

# 2. 解析 YAML
meta = yaml.safe_load(rendered)

# 3. 改版本号
meta.setdefault("package", {})["name"] = pkg
meta["package"]["version"] = ver

# 4. 处理 source
src = meta.get("source")
if isinstance(src, dict):
    if "url" in src:
        src["url"] = re.sub(
            rf'{re.escape(pkg)}-[\d.]+\.(tar\.gz|zip|tgz|tar\.bz2)',
            f'{pkg}-{ver}.tar.gz', src["url"], flags=re.IGNORECASE)
        src.pop("sha256", None)
        src.pop("md5", None)
    if "git_rev" in src:
        old_rev = str(src["git_rev"])
        m = re.match(r'^([^\d]*)', old_rev)
        prefix = m.group(1) if m else ""
        src["git_rev"] = f"{prefix}{ver}"
elif src in (None, "pypi"):
    meta["source"] = "pypi"

# 5. 写回
with open(meta_file, "w") as f:
    yaml.dump(meta, f, default_flow_style=False, allow_unicode=True)
print(open(meta_file).read())
PYEOF
        [ -f "$WS/LICENSE" ] && [ ! -f "$RECIPE_DIR/LICENSE" ] && \
            cp "$WS/LICENSE" "$RECIPE_DIR/LICENSE"

        if [ -f "$RECIPE_DIR/src/Cargo.toml" ]; then
            sed -i 's/^lto = true/lto = false/' "$RECIPE_DIR/src/Cargo.toml" || true
            sed -i 's/^lto = "fat"/lto = false/' "$RECIPE_DIR/src/Cargo.toml" || true
            sed -i 's/^lto = "thin"/lto = false/' "$RECIPE_DIR/src/Cargo.toml" || true
            sed -i 's/^codegen-units = 1/codegen-units = 16/' "$RECIPE_DIR/src/Cargo.toml" || true
        fi

        if ! (
            cd "$PYPI_DIR"
            python build-wheel.py \
                --python "$PYTHON_VER" \
                --abi arm64-v8a \
                "$RECIPE_DIR" > "$LOG" 2>&1
        ); then
            echo "❌ 官方 recipe 构建失败，最后 60 行："
            tail -60 "$LOG"
            return 1
        fi

        local NORMALIZED
        NORMALIZED=$(echo "$PKG" | tr '[:upper:]' '[:lower:]' | sed 's/[-_.]\+/-/g')
        [ -d "$PYPI_DIR/dist/$NORMALIZED" ] && \
            find "$PYPI_DIR/dist/$NORMALIZED" -name "*android_*.whl" \
                -exec cp -f {} "$WHEELS_DIR/" \;
        return 0
    fi

    # ============ 官方 recipe 没有，走 PyPI 流程 ============
    echo "ℹ️  官方没有 $PKG 的 recipe，走 PyPI 流程"
    rm -rf "$RECIPE_DIR"
    mkdir -p "$RECIPE_DIR/src"

    local PYPI_JSON="/tmp/pypi-$PKG.json"
    if ! curl -sf "https://pypi.org/pypi/$PKG/$VER/json" -o "$PYPI_JSON"; then
        echo "ERROR: $PKG==$VER 在 PyPI 上不存在"
        return 1
    fi

    local SDIST_URL
    SDIST_URL=$(jq -r '.urls[] | select(.packagetype=="sdist") | .url' \
        "$PYPI_JSON" | head -n1)
    if [ -z "$SDIST_URL" ] || [ "$SDIST_URL" = "null" ]; then
        echo "ERROR: $PKG==$VER 没有 sdist"
        echo "可用文件："
        jq -r '.urls[].filename' "$PYPI_JSON"
        return 1
    fi

    echo "下载 sdist: $SDIST_URL"
    wget -q "$SDIST_URL" -O "/tmp/sdist-$PKG.tar.gz" || return 1
    tar -xzf "/tmp/sdist-$PKG.tar.gz" -C /tmp || return 1

    local SRC_DIR="/tmp/$PKG-$VER"
    [ -d "$SRC_DIR" ] || SRC_DIR="/tmp/${PKG//-/_}-$VER"
    if [ ! -d "$SRC_DIR" ]; then
        SRC_DIR=$(find /tmp -maxdepth 1 -type d -name "*${VER}*" \
            -not -name "inject*" -not -name "sdist*" | head -1)
    fi
    if [ ! -d "$SRC_DIR" ]; then
        echo "ERROR: 找不到 sdist 解压目录"
        return 1
    fi
    echo "源目录: $SRC_DIR"
    cp -a "$SRC_DIR/." "$RECIPE_DIR/src/" || return 1

    if [ -f "$WS/LICENSE" ]; then
        cp "$WS/LICENSE" "$RECIPE_DIR/LICENSE"
    else
        echo "MIT License placeholder" > "$RECIPE_DIR/LICENSE"
    fi

    local HAS_RUST="no"
    if [ -f "$RECIPE_DIR/src/Cargo.toml" ]; then
        HAS_RUST="yes"
        sed -i 's/^lto = true/lto = false/' "$RECIPE_DIR/src/Cargo.toml" || true
        sed -i 's/^lto = "fat"/lto = false/' "$RECIPE_DIR/src/Cargo.toml" || true
        sed -i 's/^lto = "thin"/lto = false/' "$RECIPE_DIR/src/Cargo.toml" || true
        sed -i 's/^codegen-units = 1/codegen-units = 16/' "$RECIPE_DIR/src/Cargo.toml" || true
    fi

    {
        echo "package:"
        echo "  name: $PKG"
        echo "  version: $VER"
        echo "build:"
        echo "  number: 0"
        echo "  script_env: []"
        echo "source:"
        echo "  path: src"
        echo "requirements:"
        if [ "$HAS_RUST" = "yes" ]; then
            echo "  build:"
            echo "    - rust"
        fi
        echo "  host:"
        echo "    - python"
    } > "$RECIPE_DIR/meta.yaml"

    if ! (
        cd "$PYPI_DIR"
        python build-wheel.py \
            --python "$PYTHON_VER" \
            --abi arm64-v8a \
            "$RECIPE_DIR" > "$LOG" 2>&1
    ); then
        echo "❌ 构建失败，最后 60 行日志："
        tail -60 "$LOG"
        return 1
    fi

    local NORMALIZED
    NORMALIZED=$(echo "$PKG" | tr '[:upper:]' '[:lower:]' | sed 's/[-_.]\+/-/g')
    [ -d "$PYPI_DIR/dist/$NORMALIZED" ] && \
        find "$PYPI_DIR/dist/$NORMALIZED" -name "*android_*.whl" \
            -exec cp -f {} "$WHEELS_DIR/" \;

    return 0
}

# ===== 3. 主循环 =====
SUCCEEDED=()
FAILED=()

while IFS= read -r LINE; do
    [ -z "$LINE" ] && continue

    if ! echo "$LINE" | grep -q '=='; then
        echo "跳过无效行: $LINE"
        continue
    fi

    PKG=$(echo "$LINE" | cut -d= -f1 | xargs)
    VER=$(echo "$LINE" | cut -d= -f3 | xargs)

    if [ -z "$PKG" ] || [ -z "$VER" ]; then
        echo "跳过无效行: $LINE"
        continue
    fi

    echo ""
    echo "========================================"
    echo "构建 $PKG==$VER"
    echo "========================================"

    if build_one "$PKG" "$VER"; then
        SUCCEEDED+=("$PKG==$VER")
        echo "✅ $PKG==$VER 成功"
    else
        FAILED+=("$PKG==$VER")
        echo "❌ $PKG==$VER 失败"
    fi
done < /tmp/packages.txt

echo ""
echo "============================================"
echo "构建汇总"
echo "============================================"
if [ ${#SUCCEEDED[@]} -gt 0 ]; then
    echo "成功: ${SUCCEEDED[*]}"
else
    echo "成功: （无）"
fi
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "失败: ${FAILED[*]}"
else
    echo "失败: （无）"
fi
echo "============================================"

echo "=== 收集到的 wheel ==="
ls -la "$WHEELS_DIR"

if [ ${#FAILED[@]} -gt 0 ]; then
    exit 1
fi
