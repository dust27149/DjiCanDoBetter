#!/bin/sh
# 临时把 isv_webhook_url 写进运行中的 Pod 并使其生效(gateway + notify 两个服务)。
#
# 背景:物料包 env 里 ISV_WEBHOOK_URL 有非空默认值,但库内是空串。旧版 installer 的
# preserveLiveEnvValues 只判键是否存在,于是空串顶掉了包内默认值 → values.yaml.tmpl
# 渲染出空叶 → 被 config_tool.pruneEmptyLeaves 整块剪掉 → render-config init 容器的
# 环境里压根没有 ISV_WEBHOOK_URL 这个变量(它的 env > /work/env.map 取的就是容器自身
# 环境)→ config.tmpl.yaml 的 {{.ISV_WEBHOOK_URL}} 渲染成**字面量** <no value>。
#
# 本脚本改的是 rendered(emptyDir)上的 /config/config.yaml,再重启主进程重读。
# init 容器只在 **Pod 创建** 时执行一次,所以容器重启(kill 1)不会把它覆盖回去;
# 但 Pod 一旦被重建(helm upgrade / 驱逐 / 节点漂移 / delete pod)即失效,需重跑本脚本。
#
# 重启为什么杀 `pidof server` 而不是 PID 1 —— 踩过的坑,别改回去:
# gateway 的 PID 1 就是 /app/server(Go),notify 的 PID 1 是 `sh -c ./run_server.sh`,
# 业务进程在子进程里(run_server.sh 末尾 exec 成 /app/server)。对 notify 执行 kill 1
# **完全无效**:内核只向 PID 1 投递它显式注册过 handler 的信号,而非交互 sh 不为
# SIGTERM 注册 handler,信号被直接丢弃(SIGKILL 同理,照样屏蔽)。实测 /proc/1/status:
#   notify  SigCgt=0000000000010002  仅 SIGINT(2)+SIGCHLD(17),无 SIGTERM(15)
#   gateway SigCgt=fffffffdffc3feff  Go runtime 全捕获
# 现象是 kill 1 返回成功、RESTARTS 却一直是 0,极易误判成"重启了但配置被冲掉"。
# 改杀业务进程后两边统一:gateway 的 pidof server=1(Go 有 handler,正常退出),
# notify 的 =7(它退出 → 外层 sh 的 wait 返回 → sh 自然退出 → 容器重启)。
#
# notify 的 run_server.sh 起 CodeMeterLin 后要 sleep 20(ARM 上前台不返回),
# 故它的重启就绪明显比 gateway 慢,TIMEOUT 别调太小。
#
# notify 另有 isv_config.auth_enabled 开关(现场已是 true),本脚本不碰它 ——
# 改它等于改鉴权行为,超出"补一个地址"的范围。
#
# 根治路径:换上修复后的 installer 二进制再执行 cli update,值会真正写进 env.map
# 与 deployment,不再依赖本脚本。
#
# 用法: ./fix-isv-webhook.sh <webhook_url>

set -eu

NS="${NS:-flighthub2}"
KUBECTL="${KUBECTL:-sudo kubectl}"
TIMEOUT="${TIMEOUT:-180}"
FORCE="${FORCE:-0}"
CFG="${CFG:-/config/config.yaml}"

# 处理范围固定为这两个服务,不开放成参数 —— 这两个是现场确认需要 isv_webhook_url 的
# 全部服务,放开反而让调用方有机会漏配或配错对象。
SERVICES="pf-gateway-service pf-notify-service"

usage() {
    cat >&2 <<EOF
用法: $0 <webhook_url>
  例: $0 http://pf-gateway-service:8080/gateway/test/webhook-auth

环境变量:
  NS       namespace,默认 flighthub2
  KUBECTL  kubectl 调用方式,默认 "sudo kubectl"
  CFG      Pod 内配置文件路径,默认 /config/config.yaml
  TIMEOUT  等待容器重启并就绪的秒数,默认 180(需覆盖 CrashLoopBackOff 退避)
  FORCE    1=配置已是目标值时仍强制重启主进程,默认 0(跳过)
EOF
    exit 2
}

[ $# -eq 1 ] || usage
URL="$1"

# 只接受 http(s),且禁掉 sed 分隔符 —— URL 里出现 | 会把替换表达式截断成非法命令。
case "$URL" in
    http://*|https://*) ;;
    *) echo "错误: URL 必须以 http:// 或 https:// 开头,实为 '$URL'" >&2; exit 2 ;;
esac
case "$URL" in
    *"|"*) echo "错误: URL 不能包含 '|' 字符(sed 分隔符)" >&2; exit 2 ;;
esac

# find_pods 列出某服务所有 Running 的 Pod。
# 优先用 helm 标准标签;标签对不上时回退到按名字过滤,免得换个 chart 版本就失灵。
find_pods() {
    svc="$1"
    pods=$($KUBECTL -n "$NS" get pod -l "app.kubernetes.io/name=$svc" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    if [ -z "$pods" ]; then
        pods=$($KUBECTL -n "$NS" get pod --field-selector=status.phase=Running \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
            | grep "^${svc}-" || true)
    fi
    echo "$pods"
}

# restart_count 取容器当前重启次数;查不到时回传空串由调用方判。
restart_count() {
    $KUBECTL -n "$NS" get pod "$1" \
        -o jsonpath='{.status.containerStatuses[?(@.name=="'"$CONTAINER"'")].restartCount}' 2>/dev/null || true
}

# wait_restarted 等容器真正重启完并就绪。
#
# 判据必须同时满足 restartCount 增长与 ready=true,缺一不可:
# kill 1 之后 kubelet 要过一会儿才更新 Pod status,此时只查 ready 会读到**重启前**
# 残留的 true 而提前返回,紧接着的 exec 正撞上容器重建,报 "container not found"
# 被误判成"配置被冲掉"。先确认 restartCount 比基线大,才证明这一轮重启确实发生过。
wait_restarted() {
    pod="$1"
    base="$2"
    waited=0
    while [ "$waited" -lt "$TIMEOUT" ]; do
        sleep 3
        waited=$((waited + 3))
        cnt=$(restart_count "$pod")
        [ -n "$cnt" ] || continue
        [ "$cnt" -gt "$base" ] 2>/dev/null || continue
        ready=$($KUBECTL -n "$NS" get pod "$pod" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="'"$CONTAINER"'")].ready}' 2>/dev/null || true)
        [ "$ready" = "true" ] && return 0
    done
    return 1
}

# read_url 取 Pod 内当前的 webhook_url 行(已去掉前导缩进)。
read_url() {
    $KUBECTL -n "$NS" exec "$1" -c "$CONTAINER" -- \
        grep -m1 'webhook_url:' "$CFG" 2>/dev/null | sed 's/^[[:space:]]*//' || true
}

# server_pid 取业务进程 pid(gateway=1,notify=7);取不到时回传空串。
# pidof 可能返回多个,取第一个;awk 跑在本机而非容器内,不依赖容器里有 awk。
server_pid() {
    $KUBECTL -n "$NS" exec "$1" -c "$CONTAINER" -- pidof server 2>/dev/null \
        | awk '{print $1}' || true
}

# mtime 取 Pod 内某路径的 mtime 秒级时间戳。/proc/<pid> 目录的 mtime 即进程创建时刻。
mtime() {
    $KUBECTL -n "$NS" exec "$1" -c "$CONTAINER" -- stat -c %Y "$2" 2>/dev/null || true
}

# config_loaded 判断业务进程是否已经加载了当前这份配置文件。
#
# 不能只拿文件内容当判据:上一轮若"文件改了但重启失败",文件内容已是目标值,
# 纯比内容会误判成"已生效"而跳过重启,配置永远不被进程读到(实测踩过)。
# 用进程启动时刻 ≥ 配置 mtime 才算已加载;取不到任何一个时间就保守地当未加载。
config_loaded() {
    pod="$1"
    pid=$(server_pid "$pod")
    [ -n "$pid" ] || return 1
    cm=$(mtime "$pod" "$CFG")
    pm=$(mtime "$pod" "/proc/$pid")
    [ -n "$cm" ] && [ -n "$pm" ] || return 1
    [ "$pm" -ge "$cm" ] 2>/dev/null
}

# restart_server 杀业务进程让容器重启并重读配置,等到重启完成且就绪。
# 这只重启**容器**,不重建 Pod,故 emptyDir 上刚改的 config.yaml 原样保留。
restart_server() {
    pod="$1"
    pid=$(server_pid "$pod")
    [ -n "$pid" ] || pid=1
    base=$(restart_count "$pod")
    [ -n "$base" ] || base=0
    echo "  重启业务进程(kill $pid,重启前计数=$base)…"
    $KUBECTL -n "$NS" exec "$pod" -c "$CONTAINER" -- kill "$pid" 2>/dev/null || true
    wait_restarted "$pod" "$base"
}

# process_pod 改一个 Pod 的配置并重启生效。成功返回 0,否则 1(由调用方汇总)。
process_pod() {
    pod="$1"
    before=$(read_url "$pod")
    if [ -z "$before" ]; then
        echo "  跳过: $CFG 里找不到 webhook_url 字段" >&2
        return 1
    fi
    echo "  当前: $before"

    # 值已对**且进程确实加载过**才跳过重启。
    #
    # 每次重启都让容器以非 0 码退出,kubelet 按 CrashLoopBackOff 退避,连着跑几次
    # 退避会涨到分钟级,把一次本可秒级完成的运维拖成"看起来挂了"。重复执行本脚本
    # (例如写进巡检)是常态,所以默认把这一步做成空操作;确需重放重启用 FORCE=1。
    if [ "$before" = "webhook_url: $URL" ] && [ "$FORCE" != "1" ]; then
        if config_loaded "$pod"; then
            echo "  已是目标值且进程已加载,跳过重启(需强制重启请加 FORCE=1)"
            return 0
        fi
        echo "  值已对但进程启动早于配置改动,仍需重启使其重读"
    fi

    if [ "$before" != "webhook_url: $URL" ]; then
        # 整行替换而非匹配 <no value>:这样无论当前是占位符、空值还是别的地址都能改,
        # 重复执行也幂等。\1 保住原缩进(YAML 对缩进敏感)。
        $KUBECTL -n "$NS" exec "$pod" -c "$CONTAINER" -- \
            sed -i "s|^\\([[:space:]]*webhook_url:\\).*|\\1 ${URL}|" "$CFG"

        after=$(read_url "$pod")
        if [ "$after" != "webhook_url: $URL" ]; then
            echo "  失败: 写入后为 '$after',未重启进程" >&2
            return 1
        fi
        echo "  改后: $after"
    fi

    if ! restart_server "$pod"; then
        echo "  失败: 容器 ${TIMEOUT}s 内未完成重启并就绪(可能仍在 CrashLoopBackOff 退避)" >&2
        echo "        请查 $KUBECTL -n $NS logs $pod -c $CONTAINER" >&2
        return 1
    fi

    # 重启后复核:确认改动没被 init 容器重跑冲掉(Pod 若被重建就会)。
    final=$(read_url "$pod")
    if [ "$final" != "webhook_url: $URL" ]; then
        echo "  失败: 重启后被冲回 '$final' —— Pod 可能被重建了,请重跑本脚本" >&2
        return 1
    fi
    echo "  已生效(容器重启次数=$(restart_count "$pod"),Pod 未重建)"
    return 0
}

rc=0
for svc in $SERVICES; do
    # 容器名与服务名同名(helm chart 约定),restart_count/read_url 经全局 CONTAINER 取用。
    CONTAINER="$svc"
    PODS=$(find_pods "$svc")
    if [ -z "$PODS" ]; then
        echo "错误: namespace $NS 下没有 Running 的 $svc Pod" >&2
        rc=1
        continue
    fi
    for pod in $PODS; do
        echo "===== $svc / $pod ====="
        process_pod "$pod" || rc=1
    done
done

if [ "$rc" -eq 0 ]; then
    cat <<EOF

全部完成。验证鉴权链路是否真的在走:
  $KUBECTL -n $NS logs <pod> -c <服务名> --tail=50 | grep isv-webhook-auth

注意:本配置存活于 emptyDir,Pod 一旦重建即失效,需重跑本脚本。
EOF
fi
exit "$rc"
