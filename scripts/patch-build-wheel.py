#!/usr/bin/env python3
"""Apply patches to Chaquopy's build-wheel.py for Rust/abi3 packages."""
import re
import sys

BUILD_WHEEL = "/opt/chaquopy/server/pypi/build-wheel.py"


def apply_patch(name: str, src: str, old: str, new: str) -> str:
    if old not in src:
        raise SystemExit(f"[patch] {name}: target not found")
    return src.replace(old, new, 1)


def apply_patch_regex(name: str, src: str, pattern: str, insertion_fn) -> str:
    m = re.search(pattern, src)
    if not m:
        raise SystemExit(f"[patch] {name}: anchor not found")
    return src[: m.end()] + insertion_fn() + src[m.end():]


def main() -> None:
    src = open(BUILD_WHEEL).read()

    # Patch 1: venv python 带版本号
    src = apply_patch(
        "venv-python-version",
        src,
        'python_executable=f"{self.build_env}/bin/python")',
        'python_executable=f"{self.build_env}/bin/python{self.python}")',
    )

    # Patch 2: PYO3_CROSS_LIB_DIR
    src = apply_patch(
        "pyo3-cross-lib-dir",
        src,
        '            "PYO3_CROSS_PYTHON_VERSION": self.python,\n        })',
        '            "PYO3_CROSS_PYTHON_VERSION": self.python,\n'
        '            "PYO3_CROSS_LIB_DIR": f"{self.host_env}/chaquopy/lib",\n        })',
    )

    # Patch 3: 创建 libpython3.so 软链
    src = apply_patch_regex(
        "libpython3-symlink",
        src,
        r'(for name in \["pthread", "rt"\]:\s*\n\s*run\(f"[^"]*lib\{name\}\.a"\))',
        lambda: (
            "\n        if self.needs_python:\n"
            '            lib_dir = f"{self.host_env}/chaquopy/lib"\n'
            '            py_lib = f"{lib_dir}/libpython{self.python}.so"\n'
            '            generic_lib = f"{lib_dir}/libpython3.so"\n'
            "            if exists(py_lib) and not exists(generic_lib):\n"
            '                run(f"ln -s libpython{self.python}.so {generic_lib}")'
        ),
    )

    # Patch 4: DT_NEEDED 放行 libpython3.so (abi3)
    src = apply_patch(
        "abi3-libpython3-allow",
        src,
        '            if tag.entry.d_tag == "DT_NEEDED":\n'
        "                req = COMPILER_LIBS.get(tag.needed)",
        '            if tag.entry.d_tag == "DT_NEEDED":\n'
        '                if tag.needed == "libpython3.so":\n'
        "                    continue\n"
        "                req = COMPILER_LIBS.get(tag.needed)",
    )

    open(BUILD_WHEEL, "w").write(src)
    print("=== all 4 patches applied ===", file=sys.stderr)


if __name__ == "__main__":
    main()
