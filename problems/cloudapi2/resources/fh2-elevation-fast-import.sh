#!/usr/bin/env bash
# fh2-elevation-fast-import.sh —— 一键旁路高程导入（k3s 首节点 root，需 kubectl / python3）
# 自动：环境自检 → 选数据集(含 status=2 恢复) → 拉包 → python3 解压(ZIP64) → Job 切片/上传/写 PG/gzip → 更新状态 → 校验
# 用法：sudo bash fh2-elevation-fast-import.sh [--id N] [--list] [--dry-run] [--no-state-update] [--keep-workdir]

set -euo pipefail

NS="${NS:-flighthub2}"; CM="${CM:-es-management-mapconfig}"
SRC_BUCKET="${SRC_BUCKET:-file-storage-privatization}"; STATIC_BUCKET="${STATIC_BUCKET:-digital-elevation-privatization}"
MAIN_ENDPOINT="${MAIN_ENDPOINT:-http://minio:9000}"; STATIC_ENDPOINT="${STATIC_ENDPOINT:-http://minio-static:9000}"
PG_HOST="${PG_HOST:-postgresql}"; PG_PORT="${PG_PORT:-5432}"; PG_DB="${PG_DB:-digital_elevation_data_service}"
TERRAIN_PREFIX="${TERRAIN_PREFIX:-terrain}"; TIMEOUT="${TIMEOUT:-7200}"; JOB_TTL="${JOB_TTL:-3600}"
TOOL_IMAGE="${TOOL_IMAGE:-}"; SVC_IMAGE="${SVC_IMAGE:-}"
WORK_ROOT="${WORK_ROOT:-/data/flighthub2/elevation-fast-import}"; KEEP_WORKDIR=0

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; }

ID=""; LIST=0; STATE_UPDATE=1; DRY_RUN=0
while [ $# -gt 0 ]; do case "$1" in
    -i|--id) ID="${2:-}"; shift 2 ;;
    --no-state-update) STATE_UPDATE=0; shift ;;
    --keep-workdir) KEEP_WORKDIR=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -l|--list) LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（-h 查看用法）" ;;
esac; done

preflight() {
    log "======== 环境自检 ========"
    [ "$(id -u)" = "0" ] || die "请用 root 运行：sudo bash $0 --id <id>"
    command -v kubectl >/dev/null 2>&1 || die "未找到 kubectl"
    command -v python3 >/dev/null 2>&1 || die "未找到 python3（脚本用 python3 解压大包）"
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    [ -r "$KUBECONFIG" ] || die "读不到 $KUBECONFIG（请用 root 或设置 KUBECONFIG）"
    kubectl get ns "$NS" >/dev/null 2>&1 || die "连不上 k8s apiserver 或无命名空间 $NS"
    if [ -z "${FH2_PACKAGE_DIR:-}" ]; then
        FH2_PACKAGE_DIR=$(systemctl show -p Environment flighthub2-mgmt.service 2>/dev/null | tr ' ' '\n' | sed -n 's/^FH2_PACKAGE_DIR=//p' | tail -1)
    fi
    if [ -z "${FH2_PACKAGE_DIR:-}" ] || [ ! -d "${FH2_PACKAGE_DIR:-}" ]; then
        for d in /data/fh2-privatization-install-packages /data/*/fh2-privatization-install-packages /opt/*/fh2-privatization-install-packages /home/*/fh2-privatization-install-packages; do
            [ -d "$d" ] && { FH2_PACKAGE_DIR="$d"; break; }
        done
    fi
    export FH2_PACKAGE_DIR
    if [ -n "${FH2_PACKAGE_DIR:-}" ] && [ -d "$FH2_PACKAGE_DIR" ]; then log "安装包目录: $FH2_PACKAGE_DIR"; else log "警告: 未找到 fh2-privatization-install-packages，改用集群内镜像探测"; fi
    kubectl -n "$NS" get secret minio minio-static postgresql >/dev/null 2>&1 || die "缺少必要 Secret（minio / minio-static / postgresql）"
    local kb; kb=$(df -Pk /data 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "$kb" ] && [ "$kb" -lt 5242880 ] && die "/data 空闲空间不足 5GB，请清理后重试"
    log "环境自检通过"
}
preflight

NODE_NAME=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -x "$(hostname)" | head -1 || true)
if [ -z "$NODE_NAME" ] && hostname -I >/dev/null 2>&1; then
    HOSTIPS=$(hostname -I)
    NODE_NAME=$(kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.name}{\" \"}{.status.addresses[?(@.type=='InternalIP')].address}{\"\\n\"}{end}" 2>/dev/null | awk -v ips="$HOSTIPS" 'BEGIN{n=split(ips,a," ")} {for(i=1;i<=n;i++) if($2==a[i]){print $1; exit}}' || true)
fi
[ -n "$NODE_NAME" ] || die "无法确定当前节点名（hostPath 需要把 Job 固定到本节点）"

get_state() { kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.state\.json}'; }

if [ "$LIST" = "1" ]; then
    log "高程数据集列表："
    get_state | python3 -c 'import sys,json; s=json.load(sys.stdin); m={"0":"启用","1":"停用","2":"处理中","3":"失败"}; [print("  id=%s status=%s(%s) name=%s objectKey=%s"%(e.get("id"),e.get("status"),m.get(str(e.get("status")),"未知"),e.get("name"),(e.get("objectKey") or ""))) for e in sorted(s.get("elevations",[]),key=lambda x:int(x.get("id",0)))]'
    exit 0
fi

AUTO_PICK=""
if [ -z "$ID" ]; then
    PICK=$(get_state | python3 -c 'import sys,json; st=json.load(sys.stdin); c=[e for e in st.get("elevations",[]) if str(e.get("objectKey","")).strip()]; p=[e for e in c if str(e.get("status",""))=="2"]; print("%s|single"%c[0]["id"] if len(c)==1 else ("%s|processing"%p[0]["id"] if len(p)==1 else "|"))')
    ID="${PICK%%|*}"; AUTO_PICK="${PICK#*|}"
    if [ -z "$ID" ]; then
        get_state | python3 -c 'import sys,json; s=json.load(sys.stdin); [print("  id=%s status=%s name=%s objectKey=%s"%(e.get("id"),e.get("status"),e.get("name"),(e.get("objectKey") or ""))) for e in s.get("elevations",[])]' >&2
        die "存在多条可发布/处理中的高程数据集，请用 --id <数字> 指定（可先执行 --list 查看）"
    fi
    [ "$AUTO_PICK" = "processing" ] && { log "自动选中处理中的数据集 id=$ID；如需发布其他数据集，请 Ctrl+C 后用 --id 重跑"; sleep 5; }
fi

STATE=$(get_state); [ -n "$STATE" ] || die "ConfigMap $NS/$CM 里没有 state.json"
IFS='|' read -r NAME OBJ_KEY STATUS < <(printf '%s' "$STATE" | python3 -c 'import sys,json; st=json.load(sys.stdin); d=int(sys.argv[1]); e=next((x for x in st.get("elevations",[]) if int(x.get("id",-1))==d),None); print("%s|%s|%s"%(e.get("name","-"),e.get("objectKey","-"),e.get("status",-1)) if e else "-|-|-1")' "$ID")
[ "$OBJ_KEY" != "-" ] && [ -n "$OBJ_KEY" ] || die "数据集 $ID 没有 objectKey（随包预置数据无需旁路导入）"

if [ "$STATUS" = "2" ]; then
    log "数据集 $ID 状态=2（处理中），检查是否有活动导入 Job..."
    RUNNING=$(kubectl -n "$NS" get jobs -l app.kubernetes.io/component=elevation-import -o jsonpath='{range .items[?(@.status.active)]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
    [ -n "${RUNNING// }" ] && die "有导入 Job 正在运行：$RUNNING。请等它结束或先删除后再试"
    log "无活动 Job，自动把 status=2 改为 1 以便继续"
    python3 - "$NS" "$CM" "$ID" <<'PY'
import json, sys, subprocess
ns, cmname, did = sys.argv[1], sys.argv[2], sys.argv[3]
cm = json.loads(subprocess.check_output(["kubectl","-n",ns,"get","cm",cmname,"-o","json"]))
st = json.loads(cm["data"]["state.json"])
for e in st.get("elevations", []):
    if str(e.get("id")) == did: e["status"] = 1
cm["data"]["state.json"] = json.dumps(st, ensure_ascii=False, indent=2)
subprocess.run(["kubectl","-n",ns,"replace","-f","-"], input=json.dumps(cm).encode(), check=True)
print("status 2 -> 1 done")
PY
    STATUS=1
fi

if [ -z "$TOOL_IMAGE" ]; then
    for f in "${FH2_PACKAGE_DIR:-}/charts/images-app.txt" /opt/flighthub2/current/charts/images-app.txt; do
        [ -f "$f" ] || continue
        TOOL_IMAGE=$(grep -m1 'elevation-data-update-tool' "$f" || true)
        [ -n "$TOOL_IMAGE" ] && break
    done
fi
[ -n "$TOOL_IMAGE" ] || die "找不到 elevation-data-update-tool 镜像，请用 TOOL_IMAGE=... 指定"
[ -z "$SVC_IMAGE" ] && SVC_IMAGE=$(kubectl -n "$NS" get deploy es-digital-elevation-data -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[ -n "$SVC_IMAGE" ] || die "找不到 es-digital-elevation-data 镜像，请用 SVC_IMAGE=... 指定"

JOB="elevation-fast-import-${ID}-$(date +%s)"; WORKDIR="$WORK_ROOT/$JOB"
log "dataset=$ID name=$NAME status=$STATUS"; log "job=$JOB"; log "node=$NODE_NAME"; log "workdir=$WORKDIR"; log "tool=$TOOL_IMAGE"; log "svc =$SVC_IMAGE"

PY_HELPER=$(mktemp); JOB_YAML=""; STATE_PROCESSING=0; STATE_DONE=0
on_exit() { local rc=$?; [ "${STATE_PROCESSING:-0}" = "1" ] && [ "${STATE_DONE:-0}" = "0" ] && update_state 3 "fast-import aborted (rc=$rc)" "${JOB:-}" 0 || true; rm -f "${PY_HELPER:-}" "${JOB_YAML:-}" 2>/dev/null || true; }
trap on_exit EXIT
cat > "$PY_HELPER" <<'PY'
import datetime, json, sys
cm = json.load(sys.stdin); did = int(sys.argv[1]); status = int(sys.argv[2]); err = sys.argv[3]; job = sys.argv[4]; dis = sys.argv[5] == "1"
st = json.loads(cm["data"]["state.json"]); now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for e in st.get("elevations", []):
    if int(e.get("id", -1)) == did:
        e["status"] = status; e["updatedAt"] = now
        if job: e["jobName"] = job
        if err: e["errMsg"] = err
        else: e.pop("errMsg", None)
    elif dis and e.get("status") == 0:
        e["status"] = 1; e["updatedAt"] = now
cm["data"]["state.json"] = json.dumps(st, ensure_ascii=False, indent=2); json.dump(cm, sys.stdout)
PY
update_state() { local i; for i in 1 2 3 4 5; do
    kubectl -n "$NS" get cm "$CM" -o json | python3 "$PY_HELPER" "$ID" "$1" "${2:-}" "${3:-}" "${4:-0}" | kubectl replace -f - >/dev/null 2>&1 && return 0
    sleep 1
done; return 1; }

JOB_YAML=$(mktemp)
cat > "$JOB_YAML" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
  labels: {app.kubernetes.io/part-of: ${NS}, app.kubernetes.io/component: elevation-fast-import}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: ${JOB_TTL}
  template:
    metadata:
      labels: {app.kubernetes.io/component: elevation-fast-import}
    spec:
      restartPolicy: Never
      nodeName: ${NODE_NAME}
      volumes:
        - {name: data, hostPath: {path: ${WORKDIR}/data, type: Directory}}
        - {name: cfg, emptyDir: {}}
      initContainers:
        - name: render-config
          image: ${TOOL_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - {name: MINIO_STATIC_ENDPOINT, value: "${STATIC_ENDPOINT}"}
            - {name: MINIO_STATIC_BUCKET_NAME, value: "${STATIC_BUCKET}"}
            - {name: MINIO_STATIC_ACCESS_KEY_ID, valueFrom: {secretKeyRef: {name: minio-static, key: MINIO_ROOT_USER}}}
            - {name: MINIO_STATIC_ACCESS_KEY_SECRET, valueFrom: {secretKeyRef: {name: minio-static, key: MINIO_ROOT_PASSWORD}}}
            - {name: PG_HOST, value: "${PG_HOST}"}
            - {name: PG_PORT, value: "${PG_PORT}"}
            - {name: PG_USER, valueFrom: {secretKeyRef: {name: postgresql, key: POSTGRES_USER}}}
            - {name: PG_DB, value: "${PG_DB}"}
            - {name: PG_PASSWORD, valueFrom: {secretKeyRef: {name: postgresql, key: POSTGRES_PASSWORD}}}
          command: ["sh", "-c"]
          args:
            - |
              set -e
              printf 'database:\n  charset: utf8\n  database: %s\n  disable_ssl: true\n  host: %s\n  password: %s\n  port: %s\n  ssl_mode: disable\n  user_name: %s\nterrain_object_key:\n  egm96_terrain_object_key: ${TERRAIN_PREFIX}/global\n  wgs84_terrain_object_key: ${TERRAIN_PREFIX}/global_ellipsoid\nobject_storage:\n  access_key_id: %s\n  access_key_secret: %s\n  bucket: ${STATIC_BUCKET}\n  endpoint: %s\ndatabase_pool:\n  idle_timeout: 60\n  max_active: 100\n  max_idle: 100\n  max_lifetime: 100\n' "\$PG_DB" "\$PG_HOST" "\$PG_PASSWORD" "\$PG_PORT" "\$PG_USER" "\$MINIO_STATIC_ACCESS_KEY_ID" "\$MINIO_STATIC_ACCESS_KEY_SECRET" "\$MINIO_STATIC_ENDPOINT" > /cfg/service_config.yaml
              echo render-elevation-config-done
          volumeMounts:
            - {name: cfg, mountPath: /cfg}
        - name: db-migrate
          image: ${SVC_IMAGE}
          imagePullPolicy: IfNotPresent
          # 不写 workingDir：沿用镜像自带 WORKDIR（migration 与 main 同目录）
          command: ["sh", "-c", "./migration -conf /app/service_config.yaml || ./migration /app/service_config.yaml"]
          volumeMounts:
            - {name: cfg, mountPath: /app/service_config.yaml, subPath: service_config.yaml}
      containers:
        - name: import
          image: ${TOOL_IMAGE}
          imagePullPolicy: IfNotPresent
          # 不写 workingDir：沿用镜像自带 WORKDIR（./main 所在目录）
          env:
            - {name: MINIO_STATIC_ENDPOINT, value: "${STATIC_ENDPOINT}"}
            - {name: MINIO_STATIC_BUCKET_NAME, value: "${STATIC_BUCKET}"}
            - {name: MINIO_STATIC_ACCESS_KEY_ID, valueFrom: {secretKeyRef: {name: minio-static, key: MINIO_ROOT_USER}}}
            - {name: MINIO_STATIC_ACCESS_KEY_SECRET, valueFrom: {secretKeyRef: {name: minio-static, key: MINIO_ROOT_PASSWORD}}}
            - {name: PG_HOST, value: "${PG_HOST}"}
            - {name: PG_PORT, value: "${PG_PORT}"}
            - {name: PG_USER, valueFrom: {secretKeyRef: {name: postgresql, key: POSTGRES_USER}}}
            - {name: PG_DB, value: "${PG_DB}"}
            - {name: PG_PASSWORD, valueFrom: {secretKeyRef: {name: postgresql, key: POSTGRES_PASSWORD}}}
            - {name: PGHOST, value: "${PG_HOST}"}
            - {name: PGPORT, value: "${PG_PORT}"}
            - {name: PGUSER, valueFrom: {secretKeyRef: {name: postgresql, key: POSTGRES_USER}}}
            - {name: PGDATABASE, value: "${PG_DB}"}
            - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: postgresql, key: POSTGRES_PASSWORD}}}
          command: ["sh", "-c"]
          args:
            - |
              set -e
              i=0
              until mc alias set s3 ${STATIC_ENDPOINT} "\$MINIO_STATIC_ACCESS_KEY_ID" "\$MINIO_STATIC_ACCESS_KEY_SECRET" >/dev/null 2>&1; do
                i=\$((i+1)); [ "\$i" -gt 300 ] && { echo "timeout waiting for minio-static" >&2; exit 1; }; sleep 2
              done
              ./main
              mc anonymous set download "s3/${STATIC_BUCKET}"
              PREFIX="s3/${STATIC_BUCKET}/${TERRAIN_PREFIX}"
              SAMPLE=\$(mc find "\$PREFIX" --name "*.terrain" 2>/dev/null | head -1)
              if [ -z "\$SAMPLE" ]; then echo "[elevation] no terrain, skip gzip"
              elif mc stat --json "\$SAMPLE" 2>/dev/null | grep -qi '"contentEncoding" *: *"gzip"'; then echo "[elevation] terrain already gzip"
              else echo "[elevation] tagging terrain gzip (P=16)"; mc find "\$PREFIX" --name "*.terrain" 2>/dev/null | xargs -r -P 16 -I{} mc cp --attr Content-Encoding=gzip --quiet {} {} >/dev/null 2>&1 || true; fi
              echo elevation-fast-import-done
          volumeMounts:
            - {name: data, mountPath: /data/elevation}
            - {name: cfg, mountPath: /go/src/es310-update-elevation/service_config.yaml, subPath: service_config.yaml}
EOF

[ "$DRY_RUN" = "1" ] && { cat "$JOB_YAML"; exit 0; }

if [ "$STATE_UPDATE" = "1" ]; then update_state 2 "" "$JOB" 0 || die "更新 state.json 为处理中失败"; STATE_PROCESSING=1; log "state.json -> 处理中"; fi

mkdir -p "$WORKDIR"; FETCH_POD="elevation-fetch-${ID}-$(date +%s)"
log "fetch: $OBJ_KEY -> $WORKDIR/elevation.zip"
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${FETCH_POD}
  namespace: ${NS}
  labels: {app.kubernetes.io/component: elevation-fast-import-fetch}
spec:
  restartPolicy: Never
  nodeName: ${NODE_NAME}
  volumes:
    - {name: work, hostPath: {path: ${WORKDIR}, type: Directory}}
  containers:
    - name: fetch
      image: ${TOOL_IMAGE}
      imagePullPolicy: IfNotPresent
      env:
        - {name: MINIO_ACCESS_KEY_ID, valueFrom: {secretKeyRef: {name: minio, key: MINIO_ROOT_USER}}}
        - {name: MINIO_ACCESS_KEY_SECRET, valueFrom: {secretKeyRef: {name: minio, key: MINIO_ROOT_PASSWORD}}}
      command: ["sh", "-c"]
      args:
        - |
          set -e
          mc alias set src ${MAIN_ENDPOINT} "\$MINIO_ACCESS_KEY_ID" "\$MINIO_ACCESS_KEY_SECRET"
          mc cp "src/${SRC_BUCKET}/${OBJ_KEY}" /work/elevation.zip
          ls -lh /work/elevation.zip
      volumeMounts:
        - {name: work, mountPath: /work}
EOF

fetch_phase=""
for _ in $(seq 1 600); do
    fetch_phase=$(kubectl -n "$NS" get pod "$FETCH_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$fetch_phase" = "Succeeded" ] && break
    if [ "$fetch_phase" = "Failed" ]; then kubectl -n "$NS" logs "$FETCH_POD" -c fetch --tail=40 2>/dev/null || true; die "fetch pod 失败（$FETCH_POD）"; fi
    sleep 2
done
[ "$fetch_phase" = "Succeeded" ] || die "fetch pod 超时（$FETCH_POD）"
kubectl -n "$NS" delete pod "$FETCH_POD" --ignore-not-found >/dev/null 2>&1 || true

log "解压中（python3 zipfile，支持 ZIP64）..."
mkdir -p "$WORKDIR/data"
python3 - "$WORKDIR/elevation.zip" "$WORKDIR/data" <<'PYEOF'
import sys, zipfile
zp, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zp) as z:
    for info in z.infolist():
        name = info.filename; parts = name.replace("\\", "/").split("/")
        if name.startswith("/") or ".." in parts: raise SystemExit("unsafe path: " + name)
        ftype = (info.external_attr >> 16) & 0o170000
        if ftype == 0o120000: raise SystemExit("symlink not allowed: " + name)
        if ftype not in (0, 0o040000, 0o100000): raise SystemExit("unsupported file type %o: %s" % (ftype, name))
        z.extract(info, dest)
PYEOF
if [ -d "$WORKDIR/data/elevation" ]; then
    other=0; for x in "$WORKDIR/data"/*; do [ "$x" = "$WORKDIR/data/elevation" ] || other=1; done
    [ "$other" = "0" ] && { mv "$WORKDIR/data/elevation"/* "$WORKDIR/data"/; rmdir "$WORKDIR/data/elevation"; }
fi
rm -f "$WORKDIR/elevation.zip"
log "源就绪: $(find "$WORKDIR/data" -type f | wc -l) files, $(du -sh "$WORKDIR/data" | cut -f1)"

kubectl -n "$NS" apply -f "$JOB_YAML" >/dev/null
log "Job 已创建，等待完成（最多 ${TIMEOUT}s，可用 TIMEOUT=... 调整）"
result=0; deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    s=$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    f=$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null || true)
    [ "${s:-0}" -ge 1 ] && { result=1; break; }
    [ "${f:-0}" -ge 1 ] && { result=0; break; }
    sleep 5
done

postcheck() {
    log "======== 结果校验 ========"
    local reg tc sc
    reg=$(kubectl -n "$NS" exec deploy/pf-device-service -- curl -s http://es-digital-elevation-data:8090/dem/api/v2/terrain-tiles/wgs84/layer.json 2>/dev/null | tr -d '\n' | grep -o '"region":{[^}]*}' || true)
    tc=$( { kubectl -n "$NS" exec minio-static-0 -- sh -c 'mc alias set chk http://minio-static:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; mc ls -r chk/'"${STATIC_BUCKET}"'/'"${TERRAIN_PREFIX}"'/' 2>/dev/null || true; } | wc -l )
    sc=$(kubectl -n "$NS" exec postgresql-0 -- sh -c 'psql -U "${POSTGRES_USER:-postgres}" -d '"${PG_DB}"' -tAc "select count(*) from tif_slices"' 2>/dev/null || echo 0)
    log "layer.json ${reg:-未取到}"; log "terrain 对象数: ${tc}"; log "PG tif_slices: ${sc}"
    if [ -n "$reg" ] && [ "${tc:-0}" -gt 0 ] && [ "${sc:-0}" -gt 0 ]; then
        log "结果校验通过 ✔（若前端仍显示旧范围，请用无痕窗口/强刷，layer.json 有缓存）"
    elif [ -n "$reg" ]; then log "Job 已成功，layer.json 已返回 $reg。若计数不可用属统计命令差异，不代表导入失败。"
    else log "结果校验未完全通过：请查看上面的日志（terrain=$tc tif_slices=$sc）"; fi
}

if [ "$result" = "1" ]; then
    log "Job 成功，主容器日志尾部："; kubectl -n "$NS" logs "job/$JOB" -c import --tail=20 || true
    if [ "$STATE_UPDATE" = "1" ]; then STATE_DONE=1; update_state 0 "" "$JOB" 1 && log "state.json -> 处理中" || log "WARN: Job 成功但 state.json 写回失败，请手动检查"; fi
    postcheck
    log "完成。清理 Job：kubectl -n $NS delete job $JOB"
    if [ "$KEEP_WORKDIR" = "0" ]; then rm -rf "$WORKDIR"; log "workdir 已清理：$WORKDIR"; else log "workdir 保留：$WORKDIR"; fi
else
    log "Job 未成功（失败或超时），诊断日志："; kubectl -n "$NS" describe job "$JOB" 2>/dev/null | tail -20 || true
    for c in render-config db-migrate import; do echo "----- $c -----"; kubectl -n "$NS" logs "job/$JOB" -c "$c" --tail=40 2>/dev/null || true; done
    if [ "$STATE_UPDATE" = "1" ]; then update_state 3 "fast-import job failed: $JOB" "$JOB" 0 && STATE_DONE=1 && log "state.json -> 失败"; fi
    log "失败。Job 保留便于排查：kubectl -n $NS logs job/$JOB -c import"; exit 1
fi