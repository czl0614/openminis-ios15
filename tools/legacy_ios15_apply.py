#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
legacy_ios15_apply.py

OpenMinis iOS 15.4 降级移植 —— 调用点机械替换（规范版，可在原始检出上重跑）。

用法：
    # 在干净的 upstream 检出上应用全部改造
    python tools/legacy_ios15_apply.py

    # 只处理指定文件
    python tools/legacy_ios15_apply.py --files src/ios/Views/ContentView.swift

设计要点：
  * 只做「同义改名」，语义由 LegacyIOSCompat.swift 里的 shim 负责，
    因此 iOS 16+ 的实际行为与上游一致。
  * 正则一律使用字面量转义，避免 `.` 被当成通配符吃掉 `semibold` 这类词。
  * `View.bold()` 用「整行匹配」判定 —— 独立成行的 `.bold()` 必是视图修饰符，
    而 `Font.bold()` 永远嵌在 `.font(...)` 内部，不可能独占一行。
  * 幂等：重复执行不会二次包裹（负向断言 + 已改名后不再匹配）。
"""

import argparse
import os
import re
import sys

ROOT = "src/ios"
SKIP_FILES = {"LegacyIOSCompat.swift"}
SKIP_DIRS = {"MinisTests", "MinisUITests", "Preview Content"}

# ---------------------------------------------------------------------------
# 一、逐行替换规则（整行匹配，最精确，优先执行）
# ---------------------------------------------------------------------------
LINE_RULES = [
    # 独立的 `.bold()` 行 —— 视图修饰符 View.bold()（iOS 16+）
    (re.compile(r"^(\s*)\.bold\(\)\s*$"), r"\1.minisBold()", "View.bold() 独立行"),
]

# ---------------------------------------------------------------------------
# 二、全局替换规则
# ---------------------------------------------------------------------------
RULES = [
    # ---- 带 path 的 NavigationStack 必须先改，否则会被通配规则吃掉 ----
    (re.compile(r"NavigationStack\(path: \$navigationPath\)"),
     "MinisNavStackPath(path: $navigationPath)", "path 导航（主布局）"),
    (re.compile(r"NavigationStack\(path: \$navPath\)"),
     "MinisNavStackPath(path: $navPath)", "path 导航（设置页）"),

    # ---- 其余 NavigationStack（不碰 NavigationStackCoordinator 等自有类型）----
    (re.compile(r"\bNavigationStack\b(?!Path)"), "MinisNavStack", "NavigationStack"),

    # ---- 值路由 ----
    (re.compile(r"\.navigationDestination\(for:"), ".minisNavigationDestination(for:",
     "navigationDestination"),

    # ---- Sheet ----
    (re.compile(r"\.presentationDetents\("), ".minisPresentationDetents(", "presentationDetents"),
    (re.compile(r"\.presentationDragIndicator\("), ".minisPresentationDragIndicator(",
     "presentationDragIndicator"),
    (re.compile(r"\.presentationSizing\(\.page\)"), ".minisPresentationSizingPage()",
     "presentationSizing"),

    # ---- 工具栏 ----
    (re.compile(r"\.toolbarBackground\(([^,()]+), for: \.navigationBar\)"),
     r".minisToolbarBackground(\1)", "toolbarBackground"),
    (re.compile(r"\.topBarTrailing\b"), ".minisTopBarTrailing", "topBarTrailing(iOS17)"),
    (re.compile(r"\.topBarLeading\b"), ".minisTopBarLeading", "topBarLeading(iOS17)"),

    # ---- 滚动 ----
    (re.compile(r"\.scrollContentBackground\("), ".minisScrollContentBackground(",
     "scrollContentBackground"),
    (re.compile(r"\.scrollIndicators\("), ".minisScrollIndicators(", "scrollIndicators"),
    (re.compile(r"\.scrollDismissesKeyboard\("), ".minisScrollDismissesKeyboard(",
     "scrollDismissesKeyboard"),
    (re.compile(r"\.persistentSystemOverlays\("), ".minisPersistentSystemOverlays(",
     "persistentSystemOverlays"),

    # ---- 符号动画 / 转场 ----
    (re.compile(r"\.symbolEffect\(\.pulse, options: \.repeating, isActive: ([^)]+)\)"),
     r".minisSymbolEffectPulseRepeating(isActive: \1)", "symbolEffect(.pulse,repeating)"),
    (re.compile(r"\.symbolEffect\(\.pulse\)"), ".minisSymbolEffectPulse()", "symbolEffect(.pulse)"),
    (re.compile(r"\.contentTransition\(\.numericText\(\)\)"), ".minisContentTransition(.numericText)",
     "contentTransition(.numericText)"),
    (re.compile(r"\.contentTransition\(\.interpolate\)"), ".minisContentTransition(.interpolate)",
     "contentTransition(.interpolate)"),

    # ---- LabeledContent（圆括号形式；负向断言避开已改名的 MinisLabeledContent）----
    (re.compile(r"(?<![A-Za-z0-9_])LabeledContent\("), "MinisLabeledContent(", "LabeledContent"),
]

# ---------------------------------------------------------------------------
# 三、NavigationPath -> 类型化数组（仅 ContentView.swift）
#     NavigationPath 是 iOS 16+ 类型；主布局路径元素是 String，
#     设置页路径元素是 SettingsDestination。数组与 NavigationStack(path:) 兼容。
# ---------------------------------------------------------------------------
NAVPATH_RULES = [
    ("@State private var navigationPath = NavigationPath()",
     "@State private var navigationPath: [String] = []"),
    ("@State private var pendingBackgroundNavigation: (path: NavigationPath, deferredAt: Date)?",
     "@State private var pendingBackgroundNavigation: (path: [String], deferredAt: Date)?"),
    ("private func commitNavigationPath(_ newPath: NavigationPath)",
     "private func commitNavigationPath(_ newPath: [String])"),
    ("@State private var navPath = NavigationPath()",
     "@State private var navPath: [SettingsDestination] = []"),
    ("navigationPath = NavigationPath()", "navigationPath = []"),
    ("navPath = NavigationPath()", "navPath = []"),
    ("commitNavigationPath(NavigationPath([newId]))", "commitNavigationPath([newId])"),
    ("commitNavigationPath(NavigationPath([id]))", "commitNavigationPath([id])"),
]


def should_skip(path: str) -> bool:
    parts = path.replace("\\", "/").split("/")
    if os.path.basename(path) in SKIP_FILES:
        return True
    return any(d in parts for d in SKIP_DIRS)


def collect_targets(explicit):
    if explicit:
        return [p for p in explicit if not should_skip(p)]
    out = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn.endswith(".swift"):
                full = os.path.join(dirpath, fn)
                if not should_skip(full):
                    out.append(full)
    return out


def apply_to_file(path, stats):
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        original = fh.read()
    text = original

    # 1) 整行规则
    lines = text.split("\n")
    for i, line in enumerate(lines):
        for pattern, repl, label in LINE_RULES:
            new_line, n = pattern.subn(repl, line)
            if n:
                lines[i] = new_line
                stats[label] = stats.get(label, 0) + n
    text = "\n".join(lines)

    # 2) 全局规则
    for pattern, repl, label in RULES:
        text, n = pattern.subn(repl, text)
        if n:
            stats[label] = stats.get(label, 0) + n

    # 3) NavigationPath 专项
    if "NavigationPath" in text:
        for a, b in NAVPATH_RULES:
            n = text.count(a)
            if n:
                text = text.replace(a, b)
                stats["NavigationPath->数组"] = stats.get("NavigationPath->数组", 0) + n

    if text != original:
        with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
            fh.write(text)
        return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", nargs="*", default=None)
    args = ap.parse_args()

    stats = {}
    changed = 0
    targets = collect_targets(args.files)
    for path in targets:
        if apply_to_file(path, stats):
            changed += 1

    print("=" * 62)
    for label, n in sorted(stats.items(), key=lambda kv: -kv[1]):
        print(f"  {label:34s} {n:5d}")
    print("=" * 62)
    print(f"处理 {len(targets)} 个文件，改动 {changed} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
