# Infra-Hub 신규 서버 배포 가이드

새 서버에 Infra-Eye(장애 감지) + Infra-Data(자산 정보 수집)를 설치하는 전체 순서입니다.

---

## 0. 사전 확인: git 설치 여부

```bash
git --version
```

버전이 뜨면 1번으로 건너뛰기. 안 뜨면 OS에 맞게 설치:

```bash
# CentOS 7
sudo yum install -y git

# Rocky / RHEL 8,9
sudo dnf install -y git

# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y git
```

> **폐쇄망 서버는 이 방법이 안 됩니다.** 인터넷 되는 동일 OS 서버에서 git 패키지(rpm/deb)를 미리 받아 옮겨 설치하거나, 코드를 수동으로 scp 복사하세요.

---

## 1. 리포지토리 받기

`~`는 계정 홈 폴더를 가리키는데, `sudo -i`로 root 전환한 상태에서는 `~`가 `/root`로 바뀌어버립니다.
의도한 위치(`/home/mzadmin`)에 확실히 받으려면 경로를 직접 지정하세요.

```bash
cd /home/mzadmin
git clone https://github.com/wlrjs111/Infra-hub.git
cd Infra-hub
ls
```

`setup_v98.sh`, `collect_asset_info.sh`, `README.md` 세 개가 보이면 정상입니다.
이 폴더는 `/home/mzadmin/Infra-hub` 에 생성됩니다.

> `git clone`은 **최초 1회만** 실행합니다. 이후 코드가 바뀌면 7번 항목의 `git pull`로 갱신하세요.
> 같은 위치에서 `git clone`을 또 실행하면 에러가 나거나 폴더가 중첩됩니다.

---

## 2. 실행 권한 부여

```bash
chmod +x setup_v98.sh
chmod +x collect_asset_info.sh
```

---

## 3. Infra-Eye 설치 (장애 감지 + 알람)

이 서버에 처음 설치하는 경우에만 실행합니다. (이미 설치된 서버는 건너뛰기)

```bash
sudo bash setup_v98.sh
```

실행 중 아래 4가지를 입력하라는 창이 뜹니다.

| 입력값 | 설명 |
|---|---|
| `WEBHOOK_URL` | 구글챗 웹훅 URL |
| `SHEETS_URL` | Apps Script 웹 앱 URL (`/exec`로 끝남) |
| `CLIENT_NAME` | 고객사명 (예: proxmox) |
| `MANAGER_NAME` | 담당자 이름 |

입력한 값은 `/etc/telegraf/.env` 에 저장되고, 이후 `collect_asset_info.sh` 도 이 값을 그대로 재사용합니다.

설치 중간에 **HW 상태 확인 → SEL 초기화 여부(Y/N)** 를 물어봅니다.
현재 하드웨어 이상이 없는지 확인한 뒤 `Y`를 눌러 초기화하세요.
(나중에 따로 초기화하려면: `sudo ipmitool sel clear`)

---

## 4. Infra-Data 자산 정보 수집

```bash
sudo bash collect_asset_info.sh
```

OS/CPU/메모리/디스크/백업설정/설치된 애플리케이션/실행중인 서비스 정보를 수집해서 구글 시트(`infra-data` 탭)로 전송합니다.

같은 호스트에서 다시 실행하면 새 행이 아니라 **기존 행이 갱신**됩니다.

---

## 5. 정상 반영 확인

- **Infra-Eye**: 구글챗에 배포 완료 메시지 도착 확인
- **Infra-Data**: Infra-Hub 대시보드 → Infra-Data 탭에서 해당 호스트 행 확인

---

## 6. (선택) 최신 코드 자동 반영 + 주기적 자산 수집

```bash
sudo crontab -e
```

아래 한 줄 추가 (매일 새벽 3시에 최신 코드 받고 자산정보 재수집):

```
0 3 * * * cd /root/Infra-hub && git pull >> /var/log/infra_hub_pull.log 2>&1 && bash collect_asset_info.sh >> /var/log/infra_data_collect.log 2>&1
```

경로(`/root/Infra-hub`)는 실제 clone한 위치로 바꿔서 넣으세요.

---

## 7. 이후 코드가 업데이트되면

`git clone`을 다시 할 필요 없습니다. 이미 받아둔 폴더 안에서 `git pull` 한 줄이면 됩니다.

```bash
cd /home/mzadmin/Infra-hub
git pull
```

이러면 GitHub에 새로 올라온 변경사항만 받아와서, `/home/mzadmin/Infra-hub` 폴더 안의
`setup_v98.sh`, `collect_asset_info.sh`가 그 자리에서 최신 코드로 갱신됩니다.
파일 위치나 폴더 구조는 그대로 유지되고 내용만 바뀝니다.

| 상황 | 명령어 | 횟수 |
|---|---|---|
| 처음 받을 때 | `git clone ...` | 딱 1번 |
| 이후 최신화 | `git pull` | 계속 반복 |

---

## 요약 (외우기용 6줄)

```bash
cd /home/mzadmin
git clone https://github.com/wlrjs111/Infra-hub.git   # 최초 1회만
cd Infra-hub
chmod +x setup_v98.sh collect_asset_info.sh
sudo bash setup_v98.sh          # 신규 서버만
sudo bash collect_asset_info.sh
```

**코드 갱신할 때는 (매번):**
```bash
cd /home/mzadmin/Infra-hub
git pull
```
