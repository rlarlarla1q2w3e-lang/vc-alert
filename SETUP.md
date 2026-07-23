# 클라우드(GitHub Actions) 설치 가이드

이 폴더를 GitHub에 올리면, 내 PC가 꺼져 있어도 15분마다 자동으로 투자 알림을 감시합니다.
서버를 따로 관리할 필요 없이 GitHub이 무료로 실행해 줍니다.

준비물: GitHub 계정 (없으면 https://github.com/signup 에서 1분이면 가입)

---

## 방법 A. 터미널(gh CLI)로 올리기 — 가장 빠름

PowerShell을 열고 순서대로 실행하세요. (이 폴더에서 실행)

```powershell
cd D:\vc-alert\deploy

# 1) GitHub 로그인 (브라우저가 열리면 승인)
gh auth login

# 2) 저장소 생성 + 업로드 (public = Actions 무료 무제한)
gh repo create vc-alert --public --source=. --push

# 3) 텔레그램 비밀값 등록 (봇 토큰 / 채팅 ID)
gh secret set TELEGRAM_BOT_TOKEN --body "여기에_봇_토큰"
gh secret set TELEGRAM_CHAT_ID   --body "여기에_챗ID"

# 4) 모든 신규 딜 받기 옵션 (관심 투자사만 받으려면 false)
gh variable set WATCH_ALL --body "true"

# 5) 첫 실행 (기준선 저장 + '감시 시작' 메시지 도착 확인)
gh workflow run "VC Invest Alert"
```

끝입니다. 이후 15분마다 자동 실행됩니다.

> **private(비공개) 저장소로 하고 싶다면:** 위 2번에서 `--public`을 `--private`로 바꾸고,
> `.github/workflows/vc-alert.yml`의 `cron: "*/15 * * * *"`를 `"*/30 * * * *"`(30분)로 바꾸세요.
> 비공개 저장소는 무료 실행시간이 월 2000분이라, 15분 간격이면 초과합니다. 30분이면 안전합니다.
> public 저장소는 실행시간 무제한이라 15분 그대로 둬도 됩니다. (이 저장소엔 토큰이 없고
> 투자사 목록만 공개되므로 public이어도 민감정보 노출은 없습니다.)

---

## 방법 B. 웹사이트로 올리기 (CLI가 어렵다면)

1. https://github.com/new → 저장소 이름 `vc-alert` → **Public** 선택 → Create
2. 생성된 저장소에서 **Add file → Upload files**
   - 이 `deploy` 폴더 안의 파일을 **폴더째 드래그**해서 올리기
     (`.github` 폴더가 반드시 포함되어야 함 — 이게 자동 실행의 핵심)
   - Commit changes
3. **Settings → Secrets and variables → Actions → New repository secret**
   - `TELEGRAM_BOT_TOKEN` = 봇 토큰
   - `TELEGRAM_CHAT_ID` = 챗 ID
   - **Variables** 탭 → New variable → `WATCH_ALL` = `true`
4. **Actions 탭 → VC Invest Alert → Run workflow** 클릭 (첫 실행)

---

## 설치 후 반드시 할 것: 내 PC의 로컬 작업 끄기

클라우드와 로컬이 동시에 돌면 알림이 두 번 옵니다. 클라우드가 정상 작동하는 걸
확인한 뒤(텔레그램에 '감시 시작' 메시지 도착), PowerShell에서:

```powershell
Disable-ScheduledTask -TaskName VC-Invest-Alert
# 완전히 삭제하려면: Unregister-ScheduledTask -TaskName VC-Invest-Alert -Confirm:$false
```

---

## 잘 되는지 확인

- **Actions 탭**에서 실행 기록(초록 체크)이 보이면 정상.
- 빨간 X면 클릭해서 로그 확인 (보통 Secrets 오타). 저에게 로그를 주시면 봐드립니다.
- 관심 투자사·필터 수정은 `config.json`을 고쳐 저장소에 다시 올리면 반영됩니다.

## 참고: 실행 간격

GitHub의 예약 실행은 서버 부하에 따라 정시보다 5~20분 늦거나 가끔 건너뛸 수 있습니다.
투자 알림 용도로는 충분하지만, "정확히 15분"을 보장하지는 않는다는 점만 알아두세요.
