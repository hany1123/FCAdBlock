#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
括号预检：在推 CI 之前先抓「少一个 ] / 少一个 )」这类低级错误。

顺序很关键 —— **必须先去字符串，再去注释**。
反过来做的话，字符串里的 `@"https://api"` 会被当成行注释吃掉后半截，
剩下的半截字符串会把后面的字符串剥离全部打乱，统计结果就成了噪声
（v54 就吃过这个亏：一个真错误被误判为噪声，白跑一轮 CI）。

用法： python tools/balance_check.py src/*.m src/*.h
"""
import re
import sys


def strip_code(s: str) -> str:
    t = re.sub(r'@?"(?:\\.|[^"\\\n])*"', '""', s)      # 字符串（含 @"..." 字面量）
    t = re.sub(r"'(?:\\.|[^'\\\n])*'", "''", t)        # 字符常量
    t = re.sub(r'/\*.*?\*/', '', t, flags=re.S)        # 块注释
    t = re.sub(r'//[^\n]*', '', t)                     # 行注释
    return t


def main(paths):
    bad = 0
    for p in paths:
        try:
            src = open(p, encoding='utf-8', errors='replace').read()
        except OSError as e:
            print(f'  !! {p}: {e}')
            bad += 1
            continue
        t = strip_code(src)
        d = {
            '[': t.count('[') - t.count(']'),
            '(': t.count('(') - t.count(')'),
            '{': t.count('{') - t.count('}'),
        }
        ok = all(v == 0 for v in d.values())
        print(f'  {"OK " if ok else "BAD"} {p}  [={d["["]:+d} (={d["("]:+d} {{={d["{"]:+d}')
        if not ok:
            bad += 1
    print('全部平衡' if not bad else f'{bad} 个文件括号不平衡')
    return 1 if bad else 0


if __name__ == '__main__':
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(args))
