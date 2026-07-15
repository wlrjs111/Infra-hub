# Infra-Hub

서버 자산 정보 수집 및 장애 감지 자동화 스크립트

## 파일 구성

| 파일 | 역할 |
|---|---|
| `setup_v98.sh` | Infra-Eye 설치 스크립트 (HW/시스템/보안 장애 감지 + 구글챗 알람) |
| `collect_asset_info.sh` | Infra-Data 자산 정보 수집 스크립트 (OS/CPU/메모리/디스크/백업/설치앱) |

## 서버 배포 방법

### 최초 설치
```bash
git clone https://github.com/wlrjs111/Infra-hub.git
cd Infra-hub
bash setup_v98.sh
```
실행 중 WEBHOOK_URL / SHEETS_URL / CLIENT_NAME / MANAGER_NAME 을 입력하면
`/etc/telegraf/.env` 에 저장되고, 이후 `collect_asset_info.sh` 도 이 값을 그대로 재사용합니다.

### 자산 정보 수집
```bash
bash collect_asset_info.sh
```
같은 호스트로 재실행하면 새 행이 아니라 기존 행이 갱신됩니다.

### 최신 버전으로 갱신
```bash
cd Infra-hub
git pull
```

### 정기 자동 수집 (선택)
```bash
sudo crontab -e
# 추가:
0 3 * * * cd /path/to/Infra-hub && git pull >> /var/log/infra_hub_pull.log 2>&1 && bash collect_asset_info.sh >> /var/log/infra_data_collect.log 2>&1
```

## 폐쇄망 서버

GitHub 접근이 안 되는 폐쇄망 서버는 `git pull` 대신 파일을 수동으로 옮겨서 적용합니다.
