#!/bin/bash
# ============================================================
# Infra-Data: 서버 자산 정보 수집 스크립트
# 기존 Infra-Eye .env(/etc/telegraf/.env)를 재사용합니다.
# ============================================================

ENV_FILE="/etc/telegraf/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "오류: $ENV_FILE 이 없습니다."
    echo "먼저 Infra-Eye setup 스크립트를 이 서버에 실행해서"
    echo "고객사명/담당자/시트URL 정보를 만들어야 합니다."
    exit 1
fi

source "$ENV_FILE"

if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

HOSTNAME_VAL=$(hostname)
IP_ADDR=$(hostname -I | awk '{print $1}')
NOW=$(date '+%Y-%m-%d %H:%M:%S')

echo "======================================================"
echo "  Infra-Data 자산 정보 수집: $HOSTNAME_VAL"
echo "======================================================"

# ------------------------------------------------------
# OS / 커널
# ------------------------------------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-Unknown}"
    OS_VER="${VERSION_ID:-Unknown}"
else
    OS_NAME="Unknown"
    OS_VER="Unknown"
fi
KERNEL=$(uname -r)
echo "OS: $OS_NAME $OS_VER / 커널: $KERNEL"

# ------------------------------------------------------
# CPU (모델명 * 소켓 수)
# ------------------------------------------------------
CPU_MODEL=$($SUDO dmidecode -t processor 2>/dev/null | grep -m1 "Version:" | sed 's/.*Version: //' | sed 's/^ *//;s/ *$//')
if [ -z "$CPU_MODEL" ]; then
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')
fi
[ -z "$CPU_MODEL" ] && CPU_MODEL="정보 없음"

CPU_SOCKETS=$($SUDO dmidecode -t processor 2>/dev/null | grep -c "^Processor Information")
[ -z "$CPU_SOCKETS" ] || [ "$CPU_SOCKETS" -eq 0 ] 2>/dev/null && CPU_SOCKETS=1

CPU_INFO="${CPU_MODEL} * ${CPU_SOCKETS}EA"
echo "CPU: $CPU_INFO"

# ------------------------------------------------------
# 메모리 (총량 + DIMM 낱개 용량/타입/속도별 그룹)
# ------------------------------------------------------
MEM_TOTAL_GB=$(free -g 2>/dev/null | awk '/^Mem:/ {print $2}')
if [ -z "$MEM_TOTAL_GB" ] || [ "$MEM_TOTAL_GB" = "0" ]; then
    MEM_TOTAL_GB=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%.0f", $2/1024}')
fi

MEM_DIMMS=$($SUDO dmidecode -t memory 2>/dev/null | awk '
BEGIN{RS="";FS="\n"}
/Memory Device/ {
    size=""; detail=""; speed=""; cfgspeed="";
    for(i=1;i<=NF;i++){
        if ($i ~ /^[ \t]*Size:/) { size=$i; sub(/.*Size: /,"",size) }
        if ($i ~ /^[ \t]*Type Detail:/) { detail=$i; sub(/.*Type Detail: /,"",detail) }
        if ($i ~ /^[ \t]*Speed:/) { speed=$i; sub(/.*Speed: /,"",speed) }
        if ($i ~ /^[ \t]*Configured Memory Speed:/) { cfgspeed=$i; sub(/.*Configured Memory Speed: /,"",cfgspeed) }
    }
    if (size != "" && size !~ /No Module Installed/) {
        finalspeed = (cfgspeed != "" && cfgspeed !~ /Unknown/) ? cfgspeed : speed
        gsub(/ MT\/s/,"MT/s",finalspeed)
        tag = "DIMM"
        if (detail ~ /Registered/) tag = "RDIMM"
        if (detail ~ /Unbuffered/) tag = "UDIMM"

        sizeval=size; unit="GB";
        if (size ~ /MB/) { gsub(/ MB/,"",sizeval); sizeval=sizeval/1024 }
        else if (size ~ /GB/) { gsub(/ GB/,"",sizeval) }
        printf "%dGB %s, %s\n", sizeval, tag, finalspeed
    }
}' 2>/dev/null)

if [ -n "$MEM_DIMMS" ]; then
    declare -A MEM_GROUPS
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        MEM_GROUPS["$key"]=$(( ${MEM_GROUPS["$key"]:-0} + 1 ))
    done <<< "$MEM_DIMMS"

    MEM_PARTS=""
    for key in "${!MEM_GROUPS[@]}"; do
        MEM_PARTS="${MEM_PARTS}(${key} * ${MEM_GROUPS[$key]}), "
    done
    MEM_PARTS=$(echo "$MEM_PARTS" | sed 's/, $//')
    MEM_TOTAL="${MEM_TOTAL_GB}GB ${MEM_PARTS}"
else
    MEM_TOTAL="${MEM_TOTAL_GB}GB (DIMM 상세정보 조회 불가 - dmidecode 권한 확인 필요)"
fi
echo "메모리 총량: $MEM_TOTAL"

# ------------------------------------------------------
# 디스크 (물리 디스크 타입/용량별 그룹 + RAID 레벨)
# ------------------------------------------------------
RAID_LEVEL=""
DISK_SUMMARY=""

if command -v ssacli >/dev/null 2>&1; then
    PD_OUT=$($SUDO ssacli ctrl slot=0 pd all show 2>/dev/null)
    DISK_ITEMS=$(echo "$PD_OUT" | awk '
    /physicaldrive/ { if (type!="" && size!="") print type" "size; type=""; size="" }
    /Interface Type:/ { match($0,/SAS|SATA|SSD|NVMe/); if(RSTART) type=substr($0,RSTART,RLENGTH) }
    /Size:/ { s=$0; if (match(s,/[0-9]+(\.[0-9]+)? (GB|TB)/)) size=substr(s,RSTART,RLENGTH) }
    END { if (type!="" && size!="") print type" "size }
    ')
    declare -A DISK_GROUPS
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        DISK_GROUPS["$key"]=$(( ${DISK_GROUPS["$key"]:-0} + 1 ))
    done <<< "$DISK_ITEMS"
    for key in "${!DISK_GROUPS[@]}"; do
        DISK_SUMMARY="${DISK_SUMMARY}${key} * ${DISK_GROUPS[$key]}EA, "
    done
    DISK_SUMMARY=$(echo "$DISK_SUMMARY" | sed 's/, $//')
    RAID_LEVEL=$($SUDO ssacli ctrl slot=0 ld all show 2>/dev/null | grep -oE "RAID [0-9]+(\+[0-9]+)?" | head -1)

elif command -v perccli >/dev/null 2>&1; then
    PD_OUT=$($SUDO perccli /c0 /eall /sall show 2>/dev/null)
    DISK_ITEMS=$(echo "$PD_OUT" | awk '
    /^[0-9]+:[0-9]+/ {
        line=$0
        typeval=""; sizeval="";
        if (match(line,/SAS|SATA|NVMe/)) typeval=substr(line,RSTART,RLENGTH)
        if (match(line,/SSD/)) typeval="SSD"
        if (match(line,/[0-9]+(\.[0-9]+)? (GB|TB)/)) sizeval=substr(line,RSTART,RLENGTH)
        if (typeval!="" && sizeval!="") print typeval" "sizeval
    }
    ')
    declare -A DISK_GROUPS
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        DISK_GROUPS["$key"]=$(( ${DISK_GROUPS["$key"]:-0} + 1 ))
    done <<< "$DISK_ITEMS"
    for key in "${!DISK_GROUPS[@]}"; do
        DISK_SUMMARY="${DISK_SUMMARY}${key} * ${DISK_GROUPS[$key]}EA, "
    done
    DISK_SUMMARY=$(echo "$DISK_SUMMARY" | sed 's/, $//')
    RAID_LEVEL=$($SUDO perccli /c0 /vall show 2>/dev/null | grep -oE "RAID[0-9]+" | head -1)

else
    declare -A DISK_GROUPS
    while read -r name size rota tran; do
        [ "$name" = "NAME" ] && continue
        [ -z "$name" ] && continue
        TYPE="HDD"
        [ "$rota" = "0" ] && TYPE="SSD"
        [ "$tran" = "nvme" ] && TYPE="NVMe"
        KEY="${TYPE} ${size}"
        DISK_GROUPS["$KEY"]=$(( ${DISK_GROUPS["$KEY"]:-0} + 1 ))
    done < <(lsblk -d -o NAME,SIZE,ROTA,TRAN 2>/dev/null | grep -vE "^loop|^sr")
    for key in "${!DISK_GROUPS[@]}"; do
        DISK_SUMMARY="${DISK_SUMMARY}${key} * ${DISK_GROUPS[$key]}EA, "
    done
    DISK_SUMMARY=$(echo "$DISK_SUMMARY" | sed 's/, $//')
fi

[ -z "$DISK_SUMMARY" ] && DISK_SUMMARY="정보 없음"
DISK_TOTAL="$DISK_SUMMARY"
[ -n "$RAID_LEVEL" ] && DISK_TOTAL="${DISK_TOTAL} (${RAID_LEVEL})"
echo "디스크: $DISK_TOTAL"

# ------------------------------------------------------
# 백업 설정 여부 (root crontab + cron.d 에서 키워드 탐색)
# ------------------------------------------------------
BACKUP_LINES=$( { $SUDO crontab -l 2>/dev/null; $SUDO cat /etc/cron.d/* 2>/dev/null; } | grep -iE "rsync|backup|duplicity|borg| tar " | grep -v "^#" )

if [ -n "$BACKUP_LINES" ]; then
    BACKUP_ENABLED="Y"
    # ">>" 뒤는 로그 리다이렉트 경로일 뿐 백업 대상이 아니므로 잘라내고,
    # 그 앞부분(실행 커맨드)에서만 경로를 추출한다.
    BACKUP_PATH=$(echo "$BACKUP_LINES" | sed 's/>>.*//' | grep -oE "(/[a-zA-Z0-9_./-]{3,})" | grep -vE "^/(usr|bin|sbin)/" | sort -u | paste -sd ', ' -)
    [ -z "$BACKUP_PATH" ] && BACKUP_PATH="(경로 자동 추출 실패 - crontab 수동 확인 필요)"
else
    BACKUP_ENABLED="N"
    BACKUP_PATH=""
fi
echo "백업 설정: $BACKUP_ENABLED"
[ -n "$BACKUP_PATH" ] && echo "백업 경로: $BACKUP_PATH"

# ------------------------------------------------------
# 설치된 애플리케이션 / 실행 중인 서비스 (지정 목록만 체크)
# ------------------------------------------------------
WATCHLIST="nginx httpd mysqld mariadb postgresql docker java python3 node redis-server php telegraf git kubelet libvirtd"

INSTALLED=""
RUNNING=""
SERVICE_INFO=""

for app in $WATCHLIST; do
    FOUND_BIN=""
    INSTALL_PATH=""
    if command -v "$app" >/dev/null 2>&1; then
        FOUND_BIN="$app"
        INSTALL_PATH=$(command -v "$app" 2>/dev/null)
    fi

    if [ -n "$FOUND_BIN" ]; then
        VER=$("$FOUND_BIN" --version 2>/dev/null | head -1)
        if [ -n "$VER" ]; then
            INSTALLED="${INSTALLED}${app} (${VER}), "
        else
            INSTALLED="${INSTALLED}${app}, "
        fi
    fi

    IS_SYSTEMD=false
    IS_RUNNING=false
    if $SUDO systemctl is-active --quiet "$app" 2>/dev/null; then
        RUNNING="${RUNNING}${app}, "
        IS_SYSTEMD=true
        IS_RUNNING=true
    elif pgrep -x "$app" >/dev/null 2>&1; then
        RUNNING="${RUNNING}${app}, "
        IS_RUNNING=true
    fi

    # 서비스별 재시작 방법 (systemd 관리 여부에 따라 다르게 판단)
    if [ -n "$INSTALL_PATH" ] || [ "$IS_RUNNING" = true ]; then
        if [ "$IS_SYSTEMD" = true ]; then
            SERVICE_INFO="${SERVICE_INFO}${app} : systemctl restart ${app}; "
        elif [ "$IS_RUNNING" = true ]; then
            RUN_PID=$(pgrep -x "$app" | head -1)
            RUN_CMD=$($SUDO ps -o cmd= -p "$RUN_PID" 2>/dev/null | cut -c1-140)
            SERVICE_INFO="${SERVICE_INFO}${app} : (수동실행) ${RUN_CMD}; "
        else
            PATH_DISPLAY="${INSTALL_PATH:-경로 미확인}"
            SERVICE_INFO="${SERVICE_INFO}${app} : 미실행 (경로: ${PATH_DISPLAY}); "
        fi
    fi
done

INSTALLED=$(echo "$INSTALLED" | sed 's/, $//')
RUNNING=$(echo "$RUNNING" | sed 's/, $//')
SERVICE_INFO=$(echo "$SERVICE_INFO" | sed 's/; $//')

# ------------------------------------------------------
# Acronis Cyber Protect 감지 (크론탭 방식이 아닌 상시 서비스형 백업)
# ------------------------------------------------------
ACRONIS_DETECTED=false
if [ -d /opt/acronis ] || pgrep -x aakore >/dev/null 2>&1; then
    ACRONIS_DETECTED=true
fi

if [ "$ACRONIS_DETECTED" = true ]; then
    if [ -n "$INSTALLED" ]; then
        INSTALLED="${INSTALLED}, Acronis Cyber Protect"
    else
        INSTALLED="Acronis Cyber Protect"
    fi
    if [ -n "$RUNNING" ]; then
        RUNNING="${RUNNING}, Acronis Cyber Protect"
    else
        RUNNING="Acronis Cyber Protect"
    fi
    BACKUP_ENABLED="Y"
    if [ -n "$BACKUP_PATH" ]; then
        BACKUP_PATH="${BACKUP_PATH}, Acronis_cloud"
    else
        BACKUP_PATH="Acronis_cloud"
    fi
fi

echo "설치된 애플리케이션: ${INSTALLED:-없음}"
echo "실행 중인 서비스: ${RUNNING:-없음}"
echo "서비스 실행정보: ${SERVICE_INFO:-없음}"
[ "$ACRONIS_DETECTED" = true ] && echo "백업: Acronis Cyber Protect 감지됨 (백업설정여부=Y, 경로=Acronis_cloud)"

# ------------------------------------------------------
# 코드 버전 (이 스크립트가 위치한 git 리포지토리 기준)
# ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_VERSION="Git 리포지토리 아님"
CODE_COMMIT=""

if [ -d "$SCRIPT_DIR/.git" ]; then
    # root(sudo)로 실행 시 저장소 소유자(예: mzadmin)와 실행 유저(root)가 달라서
    # git이 "dubious ownership" 보안 경고로 조회를 거부하고 조용히 실패하는 경우가 있음
    # (이 스크립트는 git 에러를 2>/dev/null로 숨기고 있어서 "확인 불가"로만 보임).
    # 이 저장소 경로를 안전 목록에 추가해서 근본적으로 해결. 이미 추가돼 있으면 중복 추가 안 함.
    if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$SCRIPT_DIR"; then
        git config --global --add safe.directory "$SCRIPT_DIR" 2>/dev/null
    fi

    # 주의: "git -C <path>" 옵션은 Git 1.8.5 이상에서만 지원됨.
    # CentOS 7 등 구형 OS 기본 git(1.8.3.1)은 -C를 몰라서 매번 조용히 실패했었음(2>/dev/null로 에러 숨김).
    # -> 서브셸에서 cd 후 실행하는 방식으로 대체(본 스크립트의 현재 작업 디렉토리는 그대로 유지됨).
    LOCAL_COMMIT=$(cd "$SCRIPT_DIR" && git rev-parse --short HEAD 2>/dev/null)
    COMMIT_DATE=$(cd "$SCRIPT_DIR" && git log -1 --format=%cd --date=short 2>/dev/null)
    CODE_COMMIT="$LOCAL_COMMIT"

    # "최신"/"구버전" 같은 판단은 여기서 안 함. 이 스크립트는 폐쇄망에서도 돌아가야 해서
    # 깃허브 접속 여부에 의존하는 판단을 서버 쪽에 두지 않는다.
    # 최신 여부 판정은 대시보드(Apps Script)가 깃허브 API로 실시간 조회해서 담당한다.
    # 여기서는 그냥 "지금 이 서버가 어느 커밋에 있는지"만 사실 그대로 보고.
    if [ -z "$LOCAL_COMMIT" ]; then
        CODE_VERSION="확인 불가"
    else
        CODE_VERSION="${LOCAL_COMMIT} (${COMMIT_DATE})"
    fi
fi

echo "코드 버전: ${CODE_VERSION}"
echo "코드 커밋 해시: ${CODE_COMMIT:-없음}"

# ------------------------------------------------------
# 크론탭 자동 등록 (매일 새벽 3시 git pull + Infra-Data.sh 재실행)
# 기존 크론탭 내용은 절대 건드리지 않고, 아래 마커가 없을 때만 맨 끝에 한 줄 추가한다.
# 이미 등록돼 있으면(마커 발견) 아무것도 안 하고 건너뜀 -> 매번 실행해도 중복 안 됨.
# (git 리포지토리가 아닌 위치에서 실행했으면 SCRIPT_DIR/.git이 없으므로 건너뜀)
# ------------------------------------------------------
if [ -d "$SCRIPT_DIR/.git" ]; then
    CRON_MARKER="# infra-hub-auto-update"
    CRON_LINE="0 3 * * * cd ${SCRIPT_DIR} && git pull >> /var/log/infra_hub_pull.log 2>&1 && bash ${SCRIPT_DIR}/Infra-Data.sh >> /var/log/infra_hub_pull.log 2>&1 ${CRON_MARKER}"

    EXISTING_CRON=$($SUDO crontab -l 2>/dev/null)

    if echo "$EXISTING_CRON" | grep -qF "$CRON_MARKER"; then
        echo "크론탭: 이미 자동 갱신 등록되어 있음 (건드리지 않음)"
    else
        if [ -z "$EXISTING_CRON" ]; then
            echo "$CRON_LINE" | $SUDO crontab -
        else
            { echo "$EXISTING_CRON"; echo "$CRON_LINE"; } | $SUDO crontab -
        fi
        echo "크론탭: 자동 갱신(매일 새벽 3시 git pull + 재실행) 등록 완료"
    fi
fi

# ------------------------------------------------------
# 구글 시트로 전송
# ------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
else
    echo "오류: python이 없어 전송할 수 없습니다."
    exit 1
fi

export NOW CLIENT_NAME MANAGER_NAME HOSTNAME_VAL IP_ADDR OS_NAME OS_VER KERNEL
export CPU_INFO MEM_TOTAL DISK_TOTAL BACKUP_ENABLED BACKUP_PATH INSTALLED RUNNING SERVICE_INFO CODE_VERSION CODE_COMMIT SHEETS_URL

echo ""
echo "구글 시트로 전송 중..."

$PYTHON_CMD << 'PYEOF'
# -*- coding: utf-8 -*-
import json, os, sys

PY3 = sys.version_info[0] == 3
if PY3:
    import urllib.request as urlreq
else:
    import urllib2 as urlreq

data = {
    "type": "asset_info",
    "time": os.environ.get("NOW", ""),
    "client": os.environ.get("CLIENT_NAME", ""),
    "manager": os.environ.get("MANAGER_NAME", ""),
    "host": os.environ.get("HOSTNAME_VAL", ""),
    "ip": os.environ.get("IP_ADDR", ""),
    "os": os.environ.get("OS_NAME", ""),
    "osVersion": os.environ.get("OS_VER", ""),
    "kernel": os.environ.get("KERNEL", ""),
    "cpu": os.environ.get("CPU_INFO", ""),
    "memTotal": os.environ.get("MEM_TOTAL", ""),
    "diskTotal": os.environ.get("DISK_TOTAL", ""),
    "backupEnabled": os.environ.get("BACKUP_ENABLED", ""),
    "backupPath": os.environ.get("BACKUP_PATH", ""),
    "installedApps": os.environ.get("INSTALLED", ""),
    "runningServices": os.environ.get("RUNNING", ""),
    "serviceInfo": os.environ.get("SERVICE_INFO", ""),
    "codeVersion": os.environ.get("CODE_VERSION", ""),
    "codeCommit": os.environ.get("CODE_COMMIT", "")
}

url = os.environ.get("SHEETS_URL", "")
body = json.dumps(data).encode("utf-8")

try:
    req = urlreq.Request(url, data=body, headers={"Content-Type": "application/json"})
    resp = urlreq.urlopen(req, timeout=10)
    resp_body = resp.read()
    if isinstance(resp_body, bytes):
        resp_body = resp_body.decode("utf-8", errors="replace")

    # Apps Script는 항상 HTTP 200을 반환하므로,
    # 실제 성공/실패는 응답 본문의 JSON을 열어봐야 판단 가능
    try:
        parsed = json.loads(resp_body)
        if isinstance(parsed, dict) and parsed.get("status") == "error":
            print("SEND FAILED (server error): " + str(parsed.get("message", resp_body)))
        else:
            print("SEND OK")
    except ValueError:
        # JSON이 아닌 응답(예: 순수 "OK" 텍스트)은 정상으로 간주
        print("SEND OK")

except Exception as e:
    print("SEND FAILED: " + str(e))
PYEOF

echo "------------------------------------------------------"
echo "완료: $HOSTNAME_VAL 자산 정보 수집/전송"
echo "------------------------------------------------------"