#!/bin/bash
# 批量构建 Android arm64 wheel
# 环境变量：
#   PYTHON_VER       - 如 "3.12"
#   PACKAGES_INPUT   - 逗号或换行分隔的 "package==version" 列表（优先）
#   SINGLE_PACKAGE   - 单包模式（PACKAGES_INPUT 为空时用）
#   SINGLE_VERSION   - 单包版本

set -u

PYPI_DIR="/opt/chaquopy/server/pypi"
WHEELS_DIR="/tmp/all-wheels"
WS="${GITHUB_WORKSPACE:-/home/runner/work/chaquopy-android-wheels/chaquopy-android-wheels}"

mkdir -p "$WHEELS_DIR"

# --- 1. 确定包列表 ---
if [ -n "${PACKAGES_INPUT:-}" ]; then
    RAW="$PACKAGES_INPUT"
elif [ -n "${SINGLE_PACKAGE:-}" ] && [ -n "${SINGLE_VERSION:-}" ]; then
    RAW="${SINGLE_PACKAGE}==${SINGLE_VERSION}"
else
    echo "ERROR: 未指定包"
    exit 1
fi

echo "$RAW" | tr ',' '\n' | tr -d '\r' \
    | sed 's/#.*//' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$' > /tmp/packages.txt

echo "=== 要构建的包 ==="
cat /tmp/packages.txt
echo "====================="

# --- 2. 构建单个包 ---
build_one() {
    local PKG="$1"
    local VER="$2"
    local RECIPE_DIR="$PYPI_DIR/packages/astrbot-$PKG"
    local LOG="/tmp/build-$PKG.log"
    local PKG_LOWER
    PKG_LOWER=$(echo "$PKG" | tr '[:upper:]' '[:lower:]')

    # === 官方 recipe 优先 ===
    local OFFICIAL="$PYPI_DIR/packages/$PKG_LOWER"
    if [ -d "$OFFICIAL" ] && [ -f "$OFFICIAL/meta.yaml" ]; then
        echo "✅ 使用官方 recipe: $PKG_LOWER"

        rm -rf "$RECIPE_DIR"
        cp -a "$OFFICIAL" "$RECIPE_DIR"

        # 用 Python 改 version 和 source
        python3 - "$RECIPE_DIR/meta.yaml" "$PKG_LOWER" "$VER" <<'PYEOF'
import re, sys, yaml
meta_file, pkg, ver = sys.argv[1], sys.argv[2], sys.argv[3]
with open(meta_file) as f:
    meta = yaml.safe_load(f)
meta.setdefault("package", {})["name"] = pkg
meta["package"]["version"] = ver
src = meta.get("source")
if isinstance(src, dict):
    if "url" in src:
        src["url"] = re.sub(
            rf'{re.escape(pkg)}-[\d.]+\.(tar\.gz|zip|tgz|tar\.bz2)',
            f'{pkg}-{ver}.tar.gz', src["url"], flags=re.IGNORECASE)
        src.pop("sha256", None)
        src.pop("md5", None)
    elif "git_rev" in src:
        src["git_rev"] = ver
elif src in (None, "pypi"):
    meta["source"] = "pypi"
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

    echo "ℹ️  官方没有 $PKG 的 recipe，走 PyPI 流程"
    # ... 保持原有 PyPI 流程不变 ...
    local PKG="$1"
    local VER="$2"
    local RECIPE_DIR="$PYPI_DIR/packages/astrbot-$PKG"

    rm -rf "$RECIPE_DIR"
    mkdir -p "$RECIPE_DIR/src"

    # PyPI 校验
    local PYPI_JSON="/tmp/pypi-$PKG.json"
    if ! curl -sf "https://pypi.org/pypi/$PKG/$VER/json" -o "$PYPI_JSON"; then
        echo "ERROR: $PKG==$VER 在 PyPI 上不存在"
        return 1
    fi

    # 找 sdist
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

    # 定位源目录（连字符 / 下划线 / 通配）
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

    # LICENSE
    if [ -f "$WS/LICENSE" ]; then
        cp "$WS/LICENSE" "$RECIPE_DIR/LICENSE"
    else
        echo "MIT License placeholder" > "$RECIPE_DIR/LICENSE"
    fi

    # Cargo.toml 打补丁
    local HAS_RUST="no"
    if [ -f "$RECIPE_DIR/src/Cargo.toml" ]; then
        HAS_RUST="yes"
        sed -i 's/^lto = true/lto = false/' "$RECIPE_DIR/src/Cargo.toml" || true
        sed -i 's/^lto = "fat"/lto = false/' "$RECIPE_DIR/src/Cargo.toml" || true
        sed -i 's/^lto = "thin"/lto = false/' "$RECIPE_DIR/src/Cargo.toml" || true
        sed -i 's/^codegen-units = 1/codegen-units = 16/' "$RECIPE_DIR/src/Cargo.toml" || true
    fi

    # 生成 meta.yaml
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

    # 构建
    local LOG="/tmp/build-$PKG.log"
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

    # 收集 android wheel
    local NORMALIZED
    NORMALIZED=$(echo "$PKG" | tr '[:upper:]' '[:lower:]' | sed 's/[-_.]\+/-/g')
    local DIST_DIR="$PYPI_DIR/dist/$NORMALIZED"
    if [ -d "$DIST_DIR" ]; then
        find "$DIST_DIR" -name "*android_*.whl" \
            -exec cp -f {} "$WHEELS_DIR/" \;
    fi

    return 0
}

# --- 3. 主循环 ---
SUCCEEDED=()
FAILED=()

while IFS= read -r LINE; do
    [ -z "$LINE" ] && continue

    if ! echo "$LINE" | grep -q '=='; then
        echo "跳过无效行: $LINE"
        continue
    fi

    PKG=$(echo "$LINE" | cut -d= -f1 | xargs | tr '[:upper:]' '[:lower:]')
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
echo "成功: ${SUCCEEDED[*]:-（无）}"
echo "失败: ${FAILED[*]:-（无）}"
echo "============================================"

echo "=== 收集到的 wheel ==="
ls -la "$WHEELS_DIR"

if [ ${#FAILED[@]} -gt 0 ]; then
    exit 1
fi
