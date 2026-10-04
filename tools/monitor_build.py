#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
monitor_build.py —— 轮询 GitHub Actions 构建，完成后输出结论并抓取失败日志。

用法：
    GH_TOKEN=xxx python monitor_build.py <owner> <repo> <run_id>
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

TOKEN = os.environ.get("GH_TOKEN", "")
OWNER, REPO, RUN_ID = sys.argv[1], sys.argv[2], sys.argv[3]
API = "https://api.github.com"
HEADERS = {
    "Authorization": f"token {TOKEN}",
    "Accept": "application/vnd.github+json",
    "User-Agent": "openminis-build-monitor",
}

POLL_SECONDS = 90
MAX_WAIT_SECONDS = 5 * 60 * 60  # 5 小时上限


def api(path, raw=False):
    req = urllib.request.Request(f"{API}{path}", headers=HEADERS)
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read()
    if raw:
        return data
    return json.loads(data.decode("utf-8"))


def fetch_job_log(job_id):
    """用 curl 抓取作业日志。

    日志接口会 302 跳到对象存储，urllib 转发 Authorization 头会导致
    403（签名不匹配），而 curl 在跨主机重定向时会自动去掉该头。
    """
    import subprocess

    url = f"{API}/repos/{OWNER}/{REPO}/actions/jobs/{job_id}/logs"
    res = subprocess.run(
        ["curl", "-sL", "-H", f"Authorization: token {TOKEN}", url],
        capture_output=True,
        timeout=300,
    )
    if res.returncode != 0:
        raise RuntimeError(res.stderr.decode("utf-8", errors="replace")[:300])
    return res.stdout.decode("utf-8", errors="replace")


def main():
    started = time.time()
    last_line = ""
    while True:
        if time.time() - started > MAX_WAIT_SECONDS:
            print("监控超时退出")
            return 1

        try:
            run = api(f"/repos/{OWNER}/{REPO}/actions/runs/{RUN_ID}")
        except urllib.error.HTTPError as e:
            print(f"查询失败: {e}")
            time.sleep(POLL_SECONDS)
            continue

        status = run.get("status")
        conclusion = run.get("conclusion")

        # 打印当前正在执行的步骤，作为心跳
        try:
            jobs = api(f"/repos/{OWNER}/{REPO}/actions/runs/{RUN_ID}/jobs")["jobs"]
        except Exception:
            jobs = []

        current = ""
        for j in jobs:
            for s in j.get("steps", []):
                if s.get("status") == "in_progress":
                    current = f"{s['number']}. {s['name']}"
        if current and current != last_line:
            elapsed = int(time.time() - started)
            print(f"[{elapsed // 60:3d}min] 进行中: {current}", flush=True)
            last_line = current

        if status == "completed":
            print("\n" + "=" * 70)
            print(f"构建结束: {conclusion}")
            print("=" * 70)
            for j in jobs:
                print(f"\nJob: {j['name']} -> {j.get('conclusion')}")
                for s in j.get("steps", []):
                    mark = "OK " if s.get("conclusion") == "success" else "FAIL"
                    if s.get("conclusion") in (None, "skipped"):
                        mark = "-- "
                    print(f"  [{mark}] {s['number']:2d}. {s['name']}")

            # 失败时抓取日志
            if conclusion != "success":
                for j in jobs:
                    if j.get("conclusion") == "failure":
                        try:
                            log = fetch_job_log(j["id"])
                            out = f"build_failure_log_{RUN_ID}.txt"
                            with open(out, "w", encoding="utf-8") as fh:
                                fh.write(log)
                            print(f"\n完整日志已写入 {out}（{len(log)} 字符）")
                            # 只打印错误行，控制体积
                            errs = [
                                ln
                                for ln in log.split("\n")
                                if ("error:" in ln.lower() or "FAILED" in ln or "ninja: error" in ln)
                                and "warning" not in ln.lower()
                            ]
                            print(f"\n--- 错误行（共 {len(errs)} 条，前 60 条）---")
                            for ln in errs[:60]:
                                print(ln[:300])
                        except Exception as e:
                            print(f"日志抓取失败: {e}")
            else:
                print("\n构建成功，IPA 已产出。")
            return 0

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
