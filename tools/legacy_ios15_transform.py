#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
legacy_ios15_transform.py

OpenMinis iOS 15.4 降级移植 —— 调用点机械替换。

把 iOS 16 / iOS 17 才引入的 SwiftUI API 调用点改成 LegacyIOSCompat.swift
里提供的兼容 shim。所有替换都是「同义改名」，不做语义改写；iOS 16+ 上的
实际行为由 shim 转发到系统 API，保持不变。

安全约束：
  * 跳过 LegacyIOSCompat.swift 自身（它必须调用系统原 API）。
  * 跳过 MinisTests / MinisUITests（不参与 App 目标构建）。
  * 只做精确的字符串/正则替换，不做格式化，便于 git diff 复核。
"""

import os
import re
import sys
import json

ROOT = "src/ios"
SKIP_FILES = {"LegacyIOSCompat.swift"}
SKIP_DIRS = {"MinisTests", "MinisUITests", "Preview Content"}

# (正则, 替换, 说明)
RULES = [
    # ---- 1. 带 path 的 NavigationStack 先改，避免被后面的通配规则吃掉 ----
    (r"NavigationStack\(path: \$navigationPath\)",
     "MinisNavStackPath(path: $navigationPath)", "path 导航（主布局）"),
    (r"NavigationStack\(path: \$navPath\)",
     "MinisNavStackPath(path: $navPath)", "path 导航（设置页）"),

    # ---- 2. 其余 NavigationStack ----
    (r"\bNavigationStack\b(?!Path)", "MinisNavStack", "NavigationStack 无 path 形态"),

    # ---- 3. 值路由 ----
    (r"\.navigationDestination\(for:", ".minisNavigationDestination(for:", "navigationDestination"),

    # ---- 4. Sheet ----
    (r"\.presentationDetents\(", ".minisPresentationDetents(", "presentationDetents"),
    (r"\.presentationDragIndicator\(", ".minisPresentationDragIndicator(", "presentationDragIndicator"),

    # ---- 5. 工具栏 ----
    # toolbarBackground 调用点一律带 `, for: .navigationBar`，shim 已内建该参数
    (r"\.toolbarBackground\(([^,()]+), for: \.navigationBar\)",
     r".minisToolbarBackground(\1)", "toolbarBackground"),
    (r"\.topBarTrailing\b", ".minisTopBarTrailing", "topBarTrailing(iOS17)"),
    (r"\.topBarLeading\b", ".minisTopBarLeading", "topBarLeading(iOS17)"),

    # ---- 6. 滚动 ----
    (r"\.scrollContentBackground\(", ".minisScrollContentBackground(", "scrollContentBackground"),
    (r"\.scrollIndicators\(", ".minisScrollIndicators(", "scrollIndicators"),
    (r"\.scrollDismissesKeyboard\(", ".minisScrollDismissesKeyboard(", "scrollDismissesKeyboard"),
    (r"\.persistentSystemOverlays\(", ".minisPersistentSystemOverlays(", "persistentSystemOverlays"),

    # ---- 7. LabeledContent ----
    (r"(?<![A-Za-z0-9_])LabeledContent\(", "MinisLabeledContent(", "LabeledContent"),

    # ---- 8. View.bold()（全工程仅 1 处，其余 24 处是 Font.bold()，不能动）----
    (r"\.foregroundColor\(\.accentColor\)\.bold\(\)",
     ".foregroundColor(.accentColor).minisBold()", "View.bold()"),
]


def should_skip(path: str) -> bool:
    parts = path.replace("\\", "/").split("/")
    if os.path.basename(path) in SKIP_FILES:
        return True
    return any(d in parts for d in SKIP_DIRS)


def main() -> int:
    changed = {}
    total_edits = 0
    per_rule = {r[2]: 0 for r in RULES}

    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith(".swift"):
                continue
            full = os.path.join(dirpath, fn)
            if should_skip(full):
                continue

            with open(full, encoding="utf-8", errors="surrogateescape") as fh:
                original = fh.read()

            text = original
            file_edits = 0
            for pattern, repl, label in RULES:
                text, n = re.subn(pattern, repl, text)
                if n:
                    per_rule[label] += n
                    file_edits += n

            if text != original:
                with open(full, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
                    fh.write(text)
                changed[full] = file_edits
                total_edits += file_edits

    print("=" * 66)
    print("按规则统计")
    print("=" * 66)
    for label, n in sorted(per_rule.items(), key=lambda kv: -kv[1]):
        print(f"  {label:34s} {n:5d}")

    print()
    print("=" * 66)
    print(f"改动文件 {len(changed)} 个，替换 {total_edits} 处")
    print("=" * 66)
    for path, n in sorted(changed.items(), key=lambda kv: -kv[1])[:25]:
        print(f"  {n:4d}  {path}")
    if len(changed) > 25:
        print(f"  ... 其余 {len(changed) - 25} 个文件略")

    with open("legacy_ios15_transform_report.json", "w", encoding="utf-8") as fh:
        json.dump({"per_rule": per_rule, "changed": changed,
                   "total_edits": total_edits}, fh, ensure_ascii=False, indent=2)
    print("\n报告已写入 legacy_ios15_transform_report.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
