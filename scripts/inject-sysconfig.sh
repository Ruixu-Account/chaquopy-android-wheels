#!/usr/bin/env bash
set -euo pipefail

PY_VER="${1:?python version required}"
TARGET_VER="${2:?target version required}"
ZIP="/opt/chaquopy/maven/com/chaquo/python/target/${TARGET_VER}/target-${TARGET_VER}-arm64-v8a.zip"

if [ ! -f "$ZIP" ]; then
  echo "ERROR: target zip not found: $ZIP" >&2
  exit 1
fi

PY_VER_NODOT="${PY_VER//./}"
INJ=$(mktemp -d)
trap 'rm -rf "$INJ"' EXIT

mkdir -p "$INJ/jniLibs/arm64-v8a"
cat > "$INJ/jniLibs/arm64-v8a/_sysconfigdata__linux_aarch64-linux-android.py" <<EOF
build_time_vars = {
    "SOABI": "cpython-${PY_VER_NODOT}-aarch64-linux-android",
    "EXT_SUFFIX": ".cpython-${PY_VER_NODOT}-aarch64-linux-android.so",
    "VERSION": "${PY_VER}",
    "LDVERSION": "${PY_VER}",
    "py_version_nodot": "${PY_VER_NODOT}",
    "py_version_short": "${PY_VER}",
    "Py_ENABLE_SHARED": 1,
    "Py_DEBUG": 0,
    "Py_REF_DEBUG": 0,
    "abiflags": "",
    "prefix": "/data/data/com.astrbot.app/files/astrbot_root",
    "exec_prefix": "/data/data/com.astrbot.app/files/astrbot_root",
    "CC": "aarch64-linux-android24-clang",
    "CXX": "aarch64-linux-android24-clang++",
    "LDSHARED": "aarch64-linux-android24-clang -shared",
}
EOF

cd "$INJ"
zip -q "$ZIP" jniLibs/arm64-v8a/_sysconfigdata__linux_aarch64-linux-android.py
unzip -l "$ZIP" | grep sysconfigdata
