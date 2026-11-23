#!/bin/bash
# verify.sh — 一条命令跑完所有自检
# 用法: bash verify.sh            (会先编译)
#       bash verify.sh --no-build  (跳过编译,只跑自检)
set -u
cd "$(dirname "$0")"

BIN="build/cme-uf8-router.app/Contents/MacOS/cme-uf8-router"
fails=0

if [ "${1:-}" != "--no-build" ]; then
    echo "==> 编译"
    bash build.sh > /tmp/cver-build.log 2>&1 || { echo "编译失败,详见 /tmp/cver-build.log"; exit 1; }
fi

# 跑任何路由自检前必须清场:真实键盘数据会串进探针,导致假 FAIL
pkill -x cme-uf8-router 2>/dev/null
sleep 1

run() {
    local name="$1"; shift
    printf '%-22s' "$name"
    if out=$("$BIN" "$@" 2>&1); then
        # 自检程序自身返回 0,真正的结论在输出里:出现 FAIL 就算失败
        if echo "$out" | grep -q "FAIL"; then
            echo "FAIL"
            echo "$out" | grep "FAIL" | tail -4 | sed 's/^/    /'
            fails=$((fails+1))
        else
            echo "PASS"
        fi
    else
        echo "FAIL(退出码非 0)"
        echo "$out" | tail -6 | sed 's/^/    /'
        fails=$((fails+1))
    fi
}

run "协议编解码" --selftest
run "菜单完整性" --menu-selftest
run "菜单动作"   --action-selftest
run "MIDI 路由"  --route-selftest
run "退出清理端口" --stop-selftest

# 单实例:第二个实例必须自己退出
echo -n "$(printf '%-22s' '单实例')"
"$BIN" > /tmp/cver-a1.log 2>&1 &
sleep 2
if "$BIN" > /tmp/cver-a2.log 2>&1; then
    if grep -q "已经有一个" /tmp/cver-a2.log; then echo "PASS"; else echo "FAIL(第二个实例没被拦)"; fails=$((fails+1)); fi
else
    echo "FAIL(第二个实例异常退出)"; fails=$((fails+1))
fi
pkill -x cme-uf8-router 2>/dev/null

echo "---"
if [ "$fails" -eq 0 ]; then echo "全部通过"; else echo "$fails 项失败"; fi
exit "$fails"
