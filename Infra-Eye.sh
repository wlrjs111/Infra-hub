#!/bin/bash

clear
echo "======================================================"
echo "  Infra-Eye v9.8: 다중 장애 감지 & 구글 시트 연동"
echo "======================================================"

INSTALL_LOG="/var/log/infra_eye_install.log"
echo "=== Infra-Eye Install Log ===" > "$INSTALL_LOG"

if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# ======================================================
# [1] 환경 변수 Interactive 설정 (.env 자동 생성)
# ======================================================
ENV_FILE="/etc/telegraf/.env"
TELEGRAF_DIR="/etc/telegraf"

[ ! -d "$TELEGRAF_DIR" ] && $SUDO mkdir -p "$TELEGRAF_DIR"

if [ ! -f "$ENV_FILE" ]; then
    echo "========== 필수 환경 변수 입력 =========="
    read -p "WEBHOOK_URL: " IN_WEBHOOK
    read -p "SHEETS_URL: " IN_SHEETS
    read -p "CLIENT_NAME (예: proxmox): " IN_CLIENT
    read -p "MANAGER_NAME: " IN_MANAGER
    echo "========================================="

    $SUDO tee "$ENV_FILE" > /dev/null <<EOF
WEBHOOK_URL="$IN_WEBHOOK"
SHEETS_URL="$IN_SHEETS"
CLIENT_NAME="$IN_CLIENT"
MANAGER_NAME="$IN_MANAGER"
EOF
    $SUDO chmod 600 "$ENV_FILE"
fi

source "$ENV_FILE"

# ======================================================
# [2] IP 자동 추출 (Failover 추가)
# ======================================================
echo "서버 IP 주소 확인 중..."
if ping -c 3 -W 2 8.8.8.8 >> "$INSTALL_LOG" 2>&1; then
    SERVER_IP=$(curl -4 -s --connect-timeout 2 ifconfig.me || curl -4 -s --connect-timeout 2 icanhazip.com || curl -4 -s --connect-timeout 2 api.ipify.org)
    CLOSED_NETWORK=false
else
    SERVER_IP=""
    CLOSED_NETWORK=true
fi

if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "폐쇄망 감지됨. 사설 IP($SERVER_IP) 대체."
else
    echo "공인 IP 확인 완료: $SERVER_IP"
fi

# ======================================================
# [3] OS별 로그 경로 확인
# ======================================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID,,}"
    OS_VER="${VERSION_ID%%.*}"
else
    OS_ID="unknown"
    OS_VER="0"
fi

if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    SYS_PATH="/var/log/syslog"
    SEC_PATH="/var/log/auth.log"
    PM="apt-get"
elif [[ "$OS_ID" =~ ^(rocky|rhel|centos|almalinux|ol)$ ]] && [ "$OS_VER" -ge 9 ]; then
    PM="dnf"
    SYS_PATH="/var/log/messages"
    SEC_PATH="/var/log/secure"
    if [ "$CLOSED_NETWORK" = false ]; then
        $SUDO $PM install -y rsyslog >> "$INSTALL_LOG" 2>&1
        $SUDO systemctl enable --now rsyslog >> "$INSTALL_LOG" 2>&1
    fi
    [ ! -f /var/log/secure ]   && $SUDO touch /var/log/secure   && $SUDO chmod 600 /var/log/secure
    [ ! -f /var/log/messages ] && $SUDO touch /var/log/messages && $SUDO chmod 644 /var/log/messages
elif [[ "$OS_ID" =~ ^(rocky|rhel|centos|almalinux)$ ]]; then
    SYS_PATH="/var/log/messages"
    SEC_PATH="/var/log/secure"
    PM="yum"
else
    if [ -f /var/log/syslog ]; then
        SYS_PATH="/var/log/syslog"; SEC_PATH="/var/log/auth.log"; PM="apt-get"
    else
        SYS_PATH="/var/log/messages"; SEC_PATH="/var/log/secure"; PM="yum"
    fi
fi
echo "OS 감지 완료: $OS_ID $OS_VER"

# ======================================================
# [4] HW 툴 설치 (acl 포함)
# ======================================================
echo "필수 유틸리티 설치 중..."
if [ "$CLOSED_NETWORK" = false ]; then
    $SUDO $PM install -y dmidecode ipmitool smartmontools acl >> "$INSTALL_LOG" 2>&1
fi
$SUDO modprobe ipmi_devintf >> "$INSTALL_LOG" 2>&1
$SUDO modprobe ipmi_si     >> "$INSTALL_LOG" 2>&1

VENDOR=$($SUDO dmidecode -s system-manufacturer 2>>"$INSTALL_LOG" | tr 'A-Z' 'a-z')
if [[ "$VENDOR" == *"dell"* ]]; then
    if ! command -v perccli >/dev/null 2>&1 && [ "$CLOSED_NETWORK" = false ]; then
        curl -s https://linux.dell.com/repo/hardware/dsu/bootstrap.cgi | $SUDO bash >> "$INSTALL_LOG" 2>&1
        $SUDO $PM install perccli -y >> "$INSTALL_LOG" 2>&1
        $SUDO ln -s /opt/MegaRAID/perccli/perccli64 /usr/bin/perccli 2>>"$INSTALL_LOG"
    fi
elif [[ "$VENDOR" == *"hp"* || "$VENDOR" == *"hewlett"* ]]; then
    if ! command -v ssacli >/dev/null 2>&1 && [ "$CLOSED_NETWORK" = false ]; then
        $SUDO $PM install ssacli -y >> "$INSTALL_LOG" 2>&1
    fi
fi

# ======================================================
# [NEW-A] SEL 백업 & 현재 HW 상태 스캔
# ======================================================
SEL_BACKUP_DIR="/var/log/infra_eye_sel"
$SUDO mkdir -p "$SEL_BACKUP_DIR"
SEL_BACKUP_FILE="$SEL_BACKUP_DIR/sel_backup_$(date +%Y%m%d_%H%M%S).txt"
DEPLOY_TIME=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME_VAL=$(hostname)

echo ""
echo "======================================================"
echo "  [HW 사전 점검] SEL 백업 & 현재 상태 스캔"
echo "======================================================"

# -- SEL 백업 --
IPMI_AVAILABLE=false
if command -v ipmitool >/dev/null 2>&1; then
    if $SUDO ipmitool sel info >> "$INSTALL_LOG" 2>&1; then
        IPMI_AVAILABLE=true
        echo "SEL 로그 백업 중: $SEL_BACKUP_FILE"
        $SUDO ipmitool sel elist > "$SEL_BACKUP_FILE" 2>/dev/null
        echo "백업 완료 ($(wc -l < "$SEL_BACKUP_FILE")건)"
    else
        echo "IPMI 미지원 서버 - SEL 백업 Skip"
    fi
else
    echo "ipmitool 없음 - SEL 백업 Skip"
fi

# -- 현재 HW 상태 스캔 --
echo ""
echo "------------------------------------------------------"
echo "  현재 HW 상태 점검 결과"
echo "------------------------------------------------------"

HW_ISSUES=()
HW_OK=()

# 1) RAID 상태
if command -v perccli >/dev/null 2>&1; then
    RAID_OUT=$($SUDO perccli /c0 /eall /sall show 2>/dev/null)
    RAID_FAIL=$(echo "$RAID_OUT" | grep -iE "Degraded|Failed" | tr '|' '-' | tr -s ' ')
    if [ -n "$RAID_FAIL" ]; then
        while IFS= read -r line; do
            HW_ISSUES+=("[RAID] $line")
        done <<< "$RAID_FAIL"
    else
        HW_OK+=("RAID (Dell perccli): 정상")
    fi
elif command -v ssacli >/dev/null 2>&1; then
    RAID_OUT=$($SUDO ssacli ctrl all show config detail 2>/dev/null)
    RAID_FAIL=$(echo "$RAID_OUT" | grep -iE "Failed|Degraded")
    if [ -n "$RAID_FAIL" ]; then
        while IFS= read -r line; do
            HW_ISSUES+=("[RAID] $line")
        done <<< "$RAID_FAIL"
    else
        HW_OK+=("RAID (HP ssacli): 정상")
    fi
else
    HW_OK+=("RAID 툴 없음 - RAID 점검 Skip")
fi

# 2) 디스크 SMART 상태
if command -v smartctl >/dev/null 2>&1; then
    for disk in /dev/sd? /dev/nvme?; do
        [ -e "$disk" ] || continue
        SMART_OUT=$($SUDO smartctl -H "$disk" 2>/dev/null)
        SMART_STATUS=$(echo "$SMART_OUT" | grep -i "overall-health\|result" | head -1)
        if echo "$SMART_STATUS" | grep -iqE "FAILED|FAILING"; then
            HW_ISSUES+=("[DISK] $disk SMART: $SMART_STATUS")
        else
            HW_OK+=("DISK $disk SMART: 정상")
        fi
    done
else
    HW_OK+=("smartctl 없음 - 디스크 SMART 점검 Skip")
fi

# 3) IPMI 센서
if [ "$IPMI_AVAILABLE" = true ]; then
    SDR_OUT=$($SUDO ipmitool sdr list 2>/dev/null)
    SDR_FAIL=$(echo "$SDR_OUT" | grep -iE "fail|critical|nr\b" | grep -v "ok\|ns\|na")
    if [ -n "$SDR_FAIL" ]; then
        while IFS= read -r line; do
            HW_ISSUES+=("[IPMI] $line")
        done <<< "$SDR_FAIL"
    else
        HW_OK+=("IPMI 센서 (전원/온도/팬): 정상")
    fi

    # 4) PSU 상태
    PSU_OUT=$($SUDO ipmitool sdr type "Power Supply" 2>/dev/null)
    PSU_FAIL=$(echo "$PSU_OUT" | grep -iv "ok\|ns\|na" | grep -iE "fail|lost|absent")
    if [ -n "$PSU_FAIL" ]; then
        while IFS= read -r line; do
            HW_ISSUES+=("[PSU] $line")
        done <<< "$PSU_FAIL"
    else
        HW_OK+=("PSU (파워 서플라이): 정상")
    fi

    # 5) SEL 최근 이상 항목
    if [ -f "$SEL_BACKUP_FILE" ]; then
        SEL_WARN=$(grep -iE "Critical|Non-Recoverable|Failed|Degraded|Power Supply" "$SEL_BACKUP_FILE" \
                   | grep -iv "OS Boot\|graceful shutdown\|OS Critical Stop" \
                   | tail -5)
        if [ -n "$SEL_WARN" ]; then
            HW_ISSUES+=("[SEL] 주의 이벤트 감지:")
            while IFS= read -r line; do
                HW_ISSUES+=("     - $line")
            done <<< "$SEL_WARN"
        fi
    fi
fi

# -- 결과 출력 --
for item in "${HW_OK[@]}"; do
    echo "  $item"
done

if [ ${#HW_ISSUES[@]} -gt 0 ]; then
    echo ""
    echo "  *** 주의 필요 항목 발견 ***"
    for item in "${HW_ISSUES[@]}"; do
        echo "  $item"
    done
fi

echo "------------------------------------------------------"
echo ""

# -- 확인 프롬프트 -> SEL Clear --
if [ "$IPMI_AVAILABLE" = true ]; then
    echo "위 HW 상태를 확인하셨습니까?"
    echo "확인 후 SEL을 초기화하면 앞으로 발생하는 새 장애만 감지됩니다."
    echo ""
    read -p "SEL 초기화 진행하시겠습니까? [y/N]: " CONFIRM_SEL
    if [[ "$CONFIRM_SEL" =~ ^[Yy]$ ]]; then
        $SUDO ipmitool sel clear >> "$INSTALL_LOG" 2>&1
        echo "SEL 초기화 완료"
        SEL_CLEARED=true
    else
        echo "SEL 초기화 Skip - 기존 로그 유지"
        SEL_CLEARED=false
    fi
else
    SEL_CLEARED=false
fi

echo ""

# ======================================================
# [5] Python 감지
# ======================================================
if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
else
    PYTHON_CMD=""
fi

# ======================================================
# [6] HW 센서 스크립트 구성
# ======================================================
echo "센서 스크립트 구축 중..."
HW_SCRIPT="$TELEGRAF_DIR/check_hw_sensors.sh"
$SUDO tee "$HW_SCRIPT" > /dev/null << 'HWEOF'
#!/bin/bash
CHK_SUDO=""
[ "$EUID" -ne 0 ] && CHK_SUDO="sudo"

if command -v ipmitool >/dev/null 2>&1; then
    $CHK_SUDO ipmitool sel elist 2>/dev/null | grep -iE "Critical|Non-Recoverable|Failed|Asserted" | while read -r line; do
        [ -z "$line" ] && continue
        clean=$(echo "$line" | tr '|' '-' | tr -d '"\\' | tr -s ' ')
        echo "hw_monitor value=\"IPMI Sensor Alert: ${clean}\""
    done
fi

if command -v perccli >/dev/null 2>&1; then
    $CHK_SUDO perccli /c0 /eall /sall show 2>/dev/null | awk '/Drive Information/,/^[ \t]*$/' | grep -iE "Degraded|Failed" | while read -r line; do
        [ -z "$line" ] && continue
        clean=$(echo "$line" | tr '|' '-' | tr -d '"\\' | tr -s ' ')
        echo "hw_monitor value=\"Dell RAID Fault: ${clean}\""
    done
elif command -v ssacli >/dev/null 2>&1; then
    $CHK_SUDO ssacli ctrl all show config detail 2>/dev/null | awk '/physicaldrive/,/^[ \t]*$/' | grep -iE "Failed|Degraded" | while read -r line; do
        [ -z "$line" ] && continue
        clean=$(echo "$line" | tr '|' '-' | tr -d '"\\' | tr -s ' ')
        echo "hw_monitor value=\"HPE RAID Fault: ${clean}\""
    done
fi
HWEOF

$SUDO chown root:root "$HW_SCRIPT"
$SUDO chmod 755 "$HW_SCRIPT"

# ======================================================
# [7] 발송 엔진 구성 (Python / Bash)
# ======================================================
echo "발송 엔진 구축 중..."
if [ -n "$PYTHON_CMD" ]; then
    PY_SCRIPT="$TELEGRAF_DIR/send_gchat.py"
    $SUDO tee "$PY_SCRIPT" > /dev/null << PYEOF
# -*- coding: utf-8 -*-
from __future__ import print_function, unicode_literals
import sys, json, re, datetime

PY3 = sys.version_info[0] == 3
if PY3:
    import io, urllib.request as urlreq
    stdin = io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='ignore')
else:
    import urllib2 as urlreq
    reload(sys)
    sys.setdefaultencoding('utf-8')
    stdin = sys.stdin

try:
    from collections import deque
except ImportError:
    deque = list

WEBHOOK_URL = "$WEBHOOK_URL"
SHEETS_URL  = "$SHEETS_URL"
CLIENT      = "$CLIENT_NAME"
MANAGER     = "$MANAGER_NAME"
IP_ADDR     = "$SERVER_IP"
recent_alerts = deque(maxlen=100)

SYS_REGEX        = re.compile(r"(Out of memory|Killed process|Kernel panic|EXT4-fs error|Read-only file system)", re.IGNORECASE)
SEC_ACTION_REGEX = re.compile(r"(Accepted password for root|account locked|pam_faillock|pam_tally2|maximum authentication attempts)", re.IGNORECASE)
SEC_INFO_REGEX   = re.compile(r"(Failed password|Invalid user|authentication failure)", re.IGNORECASE)
HW_REGEX         = re.compile(r"(I/O error|sector error|rejecting I/O)", re.IGNORECASE)

def http_post(url, data_dict):
    try:
        data = json.dumps(data_dict)
        data = data.encode('utf-8') if PY3 else data.encode('utf-8') if isinstance(data, type(u'')) else data
        req  = urlreq.Request(url, data=data, headers={'Content-Type': 'application/json'})
        urlreq.urlopen(req, timeout=5)
    except Exception:
        pass

def record_to_sheet(cat, host, msg, now_str):
    labels = {"System": "시스템 오류", "Hardware": "HW 장애", "Security_action": "보안 경고", "Security_info": "보안 참고"}
    status = "참고" if cat == "Security_info" else "미조치"
    http_post(SHEETS_URL, {
        "timestamp": now_str, "category": labels.get(cat, cat),
        "client": CLIENT, "manager": MANAGER,
        "ip": IP_ADDR, "host": host, "message": msg, "status": status
    })

def send_google_chat(cat, host, msg):
    if msg in recent_alerts:
        return
    recent_alerts.append(msg)
    if len(msg) > 500:
        msg = msg[:500] + " ... (truncated)"
    now_str = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    icons  = {"System": "[SYS]", "Hardware": "[HW]", "Security_action": "[SEC]", "Security_info": "[INFO]"}
    labels = {"System": "시스템 오류", "Hardware": "HW 장애", "Security_action": "보안 경고", "Security_info": "보안 참고"}

    text = (
        "{icon} *[{label}] 장애 감지*\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "시간: {now}\n"
        "고객사: {client}\n"
        "담당자: {manager}\n"
        "서버IP: {ip}\n"
        "호스트: {host}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "내용: {msg}"
    ).format(icon=icons.get(cat,"[ALERT]"), label=labels.get(cat,"알람"),
             now=now_str, client=CLIENT, manager=MANAGER,
             ip=IP_ADDR, host=host, msg=msg)

    http_post(WEBHOOK_URL, {"text": text})
    record_to_sheet(cat, host, msg, now_str)

while True:
    line = stdin.readline()
    if not line:
        break
    try:
        host    = line.split('host=')[1].split(',')[0].split(' ')[0] if 'host=' in line else 'Unknown'
        if 'value="' not in line:
            continue
        raw_msg = line.split('value="', 1)[1].rsplit('"', 1)[0]
        if not raw_msg.strip() or 'auditbeat' in raw_msg:
            continue

        if line.startswith("hw_monitor"):
            send_google_chat("Hardware", host, raw_msg)
        elif line.startswith("syslog_monitor") and (SYS_REGEX.search(raw_msg) or HW_REGEX.search(raw_msg)):
            send_google_chat("System", host, raw_msg)
        elif line.startswith("authlog_monitor") and SEC_ACTION_REGEX.search(raw_msg):
            send_google_chat("Security_action", host, raw_msg)
        elif line.startswith("authlog_monitor") and SEC_INFO_REGEX.search(raw_msg):
            send_google_chat("Security_info", host, raw_msg)
    except Exception:
        pass
PYEOF
    $SUDO chown root:root "$PY_SCRIPT"
    $SUDO chmod 755 "$PY_SCRIPT"
    CMD_ARRAY="\"$PYTHON_CMD\", \"-u\", \"$PY_SCRIPT\""
else
    BASH_SCRIPT="$TELEGRAF_DIR/send_gchat.sh"
    $SUDO tee "$BASH_SCRIPT" > /dev/null << BASHEOF
#!/bin/bash
source /etc/telegraf/.env
IP_ADDR="$SERVER_IP"

SYS_PATTERN="Out of memory|Killed process|Kernel panic|EXT4-fs error|Read-only file system|I/O error|sector error|rejecting I/O"
SEC_ACTION_PATTERN="Accepted password for root|account locked|pam_faillock|pam_tally2|maximum authentication attempts"
SEC_INFO_PATTERN="Failed password|Invalid user|authentication failure"

send_gchat() {
    local label="\$1" host="\$2" msg="\$3"
    local now="\$(date '+%Y-%m-%d %H:%M:%S')"
    local text="\${label} 장애 감지\n시간: \${now}\n고객사: \${CLIENT_NAME}\n담당자: \${MANAGER_NAME}\n서버IP: \${IP_ADDR}\n호스트: \${host}\n내용: \${msg}"
    curl -s -X POST "\${WEBHOOK_URL}" -H "Content-Type: application/json" -d "{\"text\":\"\${text}\"}" > /dev/null 2>&1
}

record_sheet() {
    local cat="\$1" host="\$2" msg="\$3" status="\$4"
    local now="\$(date '+%Y-%m-%d %H:%M:%S')"
    curl -s -X POST "\${SHEETS_URL}" -H "Content-Type: application/json" \
        -d "{\"timestamp\":\"\${now}\",\"category\":\"\${cat}\",\"client\":\"\${CLIENT_NAME}\",\"manager\":\"\${MANAGER_NAME}\",\"ip\":\"\${IP_ADDR}\",\"host\":\"\${host}\",\"message\":\"\${msg}\",\"status\":\"\${status}\"}" > /dev/null 2>&1
}

while IFS= read -r line; do
    host=\$(echo "\$line" | sed -n 's/.*host=\([^, ]*\).*/\1/p')
    [ -z "\$host" ] && host="Unknown"
    raw_msg=\$(echo "\$line" | sed 's/.*value="//; s/"$//')
    [ -z "\$raw_msg" ] && continue
    echo "\$raw_msg" | grep -q "auditbeat" && continue

    if echo "\$line" | grep -q "^hw_monitor"; then
        send_gchat "[HW 장애]" "\$host" "\$raw_msg"
        record_sheet "HW 장애" "\$host" "\$raw_msg" "미조치"
    elif echo "\$line" | grep -q "^syslog_monitor"; then
        if echo "\$raw_msg" | grep -qiE "\$SYS_PATTERN"; then
            send_gchat "[시스템 오류]" "\$host" "\$raw_msg"
            record_sheet "시스템 오류" "\$host" "\$raw_msg" "미조치"
        fi
    elif echo "\$line" | grep -q "^authlog_monitor"; then
        if echo "\$raw_msg" | grep -qiE "\$SEC_ACTION_PATTERN"; then
            send_gchat "[보안 경고]" "\$host" "\$raw_msg"
            record_sheet "보안 경고" "\$host" "\$raw_msg" "미조치"
        elif echo "\$raw_msg" | grep -qiE "\$SEC_INFO_PATTERN"; then
            send_gchat "[보안 참고]" "\$host" "\$raw_msg"
            record_sheet "보안 참고" "\$host" "\$raw_msg" "참고"
        fi
    fi
done
BASHEOF
    $SUDO chown root:root "$BASH_SCRIPT"
    $SUDO chmod 755 "$BASH_SCRIPT"
    CMD_ARRAY="\"/bin/bash\", \"$BASH_SCRIPT\""
fi

# ======================================================
# [8] 플러그인 설정 및 권한/Logrotate 구성
# ======================================================
echo "플러그인 및 권한 설정 중..."
$SUDO mkdir -p "$TELEGRAF_DIR/telegraf.d"
CONF_FILE="$TELEGRAF_DIR/telegraf.d/infra_eye_alarm.conf"

$SUDO tee "$CONF_FILE" > /dev/null << CONFEOF
[[inputs.tail]]
  files = ["$SYS_PATH"]
  from_beginning = false
  name_override = "syslog_monitor"
  data_format = "value"
  data_type = "string"
[[inputs.tail]]
  files = ["$SEC_PATH"]
  from_beginning = false
  name_override = "authlog_monitor"
  data_format = "value"
  data_type = "string"
[[inputs.exec]]
  commands = ["sudo $HW_SCRIPT"]
  name_override = "hw_monitor"
  data_format = "influx"
  interval = "60s"
[[outputs.execd]]
  command = [$CMD_ARRAY]
  data_format = "influx"
CONFEOF

$SUDO chmod 644 "$CONF_FILE"

echo "telegraf ALL=(ALL) NOPASSWD: /usr/bin/ipmitool, /usr/bin/perccli, /usr/sbin/ssacli, $HW_SCRIPT" | $SUDO tee /etc/sudoers.d/telegraf > /dev/null

# -- 로그 읽기 권한: ACL 우선, 실패 시 그룹 폴백 (모든 OS 대응) --
echo "telegraf 로그 읽기 권한 부여 중..."

if ! command -v setfacl >/dev/null 2>&1 && [ "$CLOSED_NETWORK" = false ]; then
    $SUDO $PM install -y acl >> "$INSTALL_LOG" 2>&1
fi

ACL_OK=true
if command -v setfacl >/dev/null 2>&1; then
    $SUDO setfacl -m u:telegraf:r "$SEC_PATH" >> "$INSTALL_LOG" 2>&1 || ACL_OK=false
    $SUDO setfacl -m u:telegraf:r "$SYS_PATH" >> "$INSTALL_LOG" 2>&1 || ACL_OK=false
else
    ACL_OK=false
fi

if [ "$ACL_OK" = true ]; then
    echo "  ACL 권한 부여 완료 (setfacl)"
    SETFACL_BIN=$(command -v setfacl)
    LOGROTATE_ACL="/etc/logrotate.d/infra_eye_acl"
    $SUDO tee "$LOGROTATE_ACL" > /dev/null << ACLEOF
# Infra-Eye: 로그 로테이션 후 telegraf ACL 재적용
$SEC_PATH $SYS_PATH {
    postrotate
        $SETFACL_BIN -m u:telegraf:r $SEC_PATH 2>/dev/null || true
        $SETFACL_BIN -m u:telegraf:r $SYS_PATH 2>/dev/null || true
    endscript
}
ACLEOF
    $SUDO chmod 644 "$LOGROTATE_ACL"
    echo "  logrotate ACL 유지 설정 완료"
else
    echo "  ACL 미지원 - 그룹 권한 방식으로 폴백"
    SEC_GROUP=$($SUDO stat -c "%G" "$SEC_PATH" 2>/dev/null || echo "root")
    SYS_GROUP=$($SUDO stat -c "%G" "$SYS_PATH" 2>/dev/null || echo "root")
    $SUDO usermod -aG "$SEC_GROUP" telegraf >> "$INSTALL_LOG" 2>&1
    [ "$SEC_GROUP" != "$SYS_GROUP" ] && $SUDO usermod -aG "$SYS_GROUP" telegraf >> "$INSTALL_LOG" 2>&1
    $SUDO chmod g+r "$SEC_PATH" 2>/dev/null
    $SUDO chmod g+r "$SYS_PATH" 2>/dev/null
fi

echo "Telegraf 데몬 재시작 중..."
$SUDO systemctl daemon-reload >> "$INSTALL_LOG" 2>&1
$SUDO systemctl stop telegraf >> "$INSTALL_LOG" 2>&1
$SUDO systemctl start telegraf >> "$INSTALL_LOG" 2>&1

# ======================================================
# [NEW-B] 배포 완료 알림 -> 구글 챗 발송 (Python JSON 처리)
# ======================================================
HW_SUMMARY=""
if [ ${#HW_ISSUES[@]} -gt 0 ]; then
    HW_STATUS_ICON="⚠️"
    HW_STATUS_TEXT="주의 필요 항목 있음"
    for item in "${HW_ISSUES[@]}"; do
        HW_SUMMARY="${HW_SUMMARY}\n${item}"
    done
else
    HW_STATUS_ICON="✅"
    HW_STATUS_TEXT="이상 없음"
    for item in "${HW_OK[@]}"; do
        HW_SUMMARY="${HW_SUMMARY}\n${item}"
    done
fi

SEL_STATUS="초기화 완료"
[ "$SEL_CLEARED" = false ] && SEL_STATUS="Skip (유지)"
[ "$IPMI_AVAILABLE" = false ] && SEL_STATUS="IPMI 미지원"

DEPLOY_MSG="🚀 *[Infra-Eye v9.8] 배포 완료*\n"
DEPLOY_MSG+="━━━━━━━━━━━━━━━━━━━━\n"
DEPLOY_MSG+="배포 시각: ${DEPLOY_TIME}\n"
DEPLOY_MSG+="고객사: ${CLIENT_NAME}\n"
DEPLOY_MSG+="담당자: ${MANAGER_NAME}\n"
DEPLOY_MSG+="서버 IP: ${SERVER_IP}\n"
DEPLOY_MSG+="호스트: ${HOSTNAME_VAL}\n"
DEPLOY_MSG+="SEL 초기화: ${SEL_STATUS}\n"
DEPLOY_MSG+="━━━━━━━━━━━━━━━━━━━━\n"
DEPLOY_MSG+="${HW_STATUS_ICON} HW 초기 상태: ${HW_STATUS_TEXT}"
DEPLOY_MSG+="${HW_SUMMARY}\n"
DEPLOY_MSG+="━━━━━━━━━━━━━━━━━━━━\n"
DEPLOY_MSG+="이제부터 실시간 장애 감시를 시작합니다."

# JSON 안전 처리: Python이 있으면 json.dumps로, 없으면 sed 폴백
DEPLOY_MSG_REAL=$(echo -e "$DEPLOY_MSG")

if [ -n "$PYTHON_CMD" ]; then
    JSON_PAYLOAD=$(DEPLOY_MSG="$DEPLOY_MSG_REAL" $PYTHON_CMD -c 'import json,os; print(json.dumps({"text": os.environ["DEPLOY_MSG"]}))')
else
    ESCAPED=$(printf '%s' "$DEPLOY_MSG_REAL" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
    JSON_PAYLOAD="{\"text\":\"$ESCAPED\"}"
fi

curl -s -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD" \
    >> "$INSTALL_LOG" 2>&1

# ======================================================
# 배포 완료
# ======================================================
echo "------------------------------------------------------"
echo "배포 완료! (Infra-Eye v9.8)"
echo "SEL 백업 위치: $SEL_BACKUP_FILE"
echo "설치 로그:     $INSTALL_LOG"

if [ "$IPMI_AVAILABLE" = true ] && [ "$SEL_CLEARED" = false ]; then
    echo "------------------------------------------------------"
    echo "⚠️  SEL 초기화를 건너뛰셨습니다."
    echo "    HW 상태를 확인하신 뒤, 아래 명령어로 나중에 직접 초기화할 수 있습니다:"
    echo ""
    echo "    sudo ipmitool sel clear"
    echo ""
    echo "    초기화 전까지는 과거 SEL 이벤트가 계속 알람으로 재발송될 수 있습니다."
fi

echo "------------------------------------------------------"