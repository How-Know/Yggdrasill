# Apple Developer 계정 & iOS/watchOS 개발 환경 준비 가이드

> **대상 독자**: iOS 앱을 처음 만드는 비개발자 출신 운영자.
> **목표**: Apple 계정 생성 → Apple Developer Program 가입 → Xcode 설치 → APNs 인증 키 확보 → TestFlight에 첫 빌드 올려서 본인 iPhone에서 실행까지.
> **총 소요**: 체크카드/신분증이 준비돼 있다면 **1~3일**(Apple 심사 대기가 대부분). 실제 손이 가는 시간은 약 2~3시간.

## 0. 먼저 준비할 것 (체크리스트)

시작 전에 책상에 다 꺼내두세요.

- [ ] **iPhone 1대** (테스트용, iOS 17 이상 권장)
- [ ] **Apple Watch 1대** (Series 6 이상 권장, iPhone과 페어링된 상태)
- [ ] **Mac 1대** ⚠️ **필수**. Windows/Linux로는 iOS 앱 빌드·서명·제출이 불가능합니다.
  - **MacBook Air M1/M2/M3/M4 어느 것이든 가능**. 중고 M1 MacBook Air(8GB/256GB)도 충분.
  - macOS Sonoma 14.5 이상 (Xcode 16 설치 요건)
  - 저장공간 **최소 100GB 여유** (Xcode 본체 + 시뮬레이터가 약 40~60GB)
- [ ] **신분증** (주민등록증 또는 운전면허증) — Apple이 개인 확인 시 요구할 수 있음
- [ ] **해외결제 가능한 신용/체크카드** (연회비 $99 결제용. VISA/Master 가능. 국내 체크카드 중 해외결제 설정한 것도 OK)
- [ ] **한국 휴대폰 번호** (SMS 2단계 인증용)
- [ ] **본인의 법적 이름 영문 표기** (여권 기준. App Store 판매자명으로 공개됨 — 예: "HONG GILDONG")

> **Mac이 없다면?** 중고 M1 MacBook Air가 약 60~80만 원 선. 클라우드 Mac 임대(MacStadium, MacinCloud) 도 가능하지만 Xcode 성능 이슈로 비추천. **반드시 실기 Mac**을 권장.

## 1. Apple 계정 만들기 (이미 있으면 건너뜀)

> iCloud/앱스토어에 쓰는 그 Apple 계정 그대로입니다. 있으시면 1.3번만 확인하세요.

### 1.1 계정 생성
1. 브라우저에서 https://appleid.apple.com 접속
2. 우측 상단 **"Apple 계정 만들기"** 클릭
3. 아래 정보 정확히 입력 — **여기서 쓴 이름이 나중에 App Store 판매자 이름으로 표시됩니다**
   - 이름: 영문 성/이름 (여권과 동일)
   - 생년월일
   - 이메일 (본인 사용 중인 것)
   - 비밀번호
   - 국가: 대한민국
4. 이메일/전화번호로 온 인증번호 입력

### 1.2 2단계 인증(2FA) 반드시 켜기
> **2FA가 없으면 Apple Developer Program 가입 자체가 안 됩니다.**

1. https://appleid.apple.com 로그인
2. **"로그인 및 보안"** → **"2단계 인증"** → **"설정"**
3. 신뢰할 수 있는 전화번호 등록 (본인 휴대폰)
4. 테스트로 한 번 로그아웃-재로그인 하면서 SMS 코드 입력이 뜨는지 확인

### 1.3 계정 이름/주소 확인
1. **"개인 정보"** 섹션에서 **First name / Last name 이 영문 법적 이름인지** 확인
2. **"배송 주소"** 에 실제 거주지 입력 (P.O.Box 불가). 도로명 주소 영문 표기 필요.
   - 영문 주소 변환: https://www.jusoen.com 같은 곳에서 변환 가능
   - 예: "서울특별시 강남구 테헤란로 123, 4층" → "4F, 123 Teheran-ro, Gangnam-gu, Seoul, 06134, Republic of Korea"

## 2. Apple Developer Program 가입 ($99/년)

### 2.1 iPhone에서 "Apple Developer" 앱 설치 (권장 경로)

개인 가입은 iPhone의 **Apple Developer 앱**을 쓰는 게 가장 빠릅니다. 신분증 스캔을 앱이 대신 해주기 때문.

1. iPhone 앱스토어에서 **"Apple Developer"** 검색 → 설치 → 실행
2. 본인 Apple ID로 로그인
3. 앱 하단 **"Account"** 탭 → **"Enroll"** 버튼 탭
4. **"Start Your Enrollment"** → **"Individual / Sole Proprietor"** 선택
   - ⚠️ **"Organization(회사)" 선택 금지**. 개인은 훨씬 간단합니다. 나중에 회사 계정으로 옮기는 것도 가능.
5. 이름/주소/연락처가 자동 채워짐 — 그대로 맞는지 확인 후 **Continue**
6. **신분증 스캔** 화면이 나오면 운전면허증 또는 주민등록증 앞/뒷면 촬영
7. 약관 동의
8. **결제** — $99 USD. 체크카드 해외결제 설정이 돼 있어야 함.

### 2.2 승인 대기

- 보통 **24~48시간 내 "Welcome to the Apple Developer Program"** 메일이 옵니다.
- 드물게 추가 서류 요청 메일이 올 수 있음 (이름 영문 표기가 모호하거나, 카드 결제 실패 등).
- 승인되면 https://developer.apple.com/account 에서 "Member" 표시가 뜹니다.

### 2.3 승인 후 꼭 확인할 3가지

https://developer.apple.com/account 에서:
1. **"Membership details"** → Status: **Active** / Expiration date 표시 확인
2. **"Team ID"** 10자리 영숫자 (예: `A1B2C3D4E5`) — 이후 빌드에 필요. 메모해둘 것.
3. **Agreements, Tax, and Banking** 은 **유료 앱/인앱결제를 쓸 때만** 필요. 우리는 사내 배포라 지금은 건너뛰어도 됨.

## 3. Mac에 Xcode 설치

### 3.1 Xcode 설치
1. Mac의 **App Store** 앱 열기
2. **"Xcode"** 검색 → **받기** → 설치
3. 다운로드 용량 **약 10GB**, 설치 후 추가로 시뮬레이터 포함 **30~50GB** 사용. 시간이 꽤 걸립니다 (WiFi 기준 30분~1시간).
4. 설치 완료 후 한 번 실행
5. **"Agree to License Agreement"** 동의
6. 관리자 비밀번호 입력해서 **Command Line Tools 설치** 허용

### 3.2 Xcode 버전 확인

터미널(Terminal.app) 열고:

```bash
xcodebuild -version
```

**Xcode 16.0 이상**이 보이면 OK. 낮으면 App Store에서 업데이트.

### 3.3 Xcode에 본인 Apple Developer 계정 연결

1. Xcode 실행 → 상단 메뉴 **Xcode → Settings...** (또는 ⌘,)
2. **Accounts** 탭
3. 좌하단 **+** → **Apple ID** 선택
4. Developer Program에 가입한 Apple ID/비번 입력
5. 목록에 본인 이름이 뜨고, **Team** 항목에 본인 이름과 **"Individual"** 로 팀이 생기면 성공
6. 우하단 **Manage Certificates...** 클릭 → **+** → **Apple Development** 선택 → 로컬 서명 인증서 자동 생성됨

## 4. 앱 식별자 & 프로비저닝 프로파일 생성

> 실제 앱을 처음 빌드할 때 필요합니다. Phase 2 시작 전 미리 만들어둬도 됨.

### 4.1 Bundle ID 만들기

Bundle ID는 전 세계에서 유일해야 하는 앱 식별자입니다. 규칙: **역도메인 표기법**.

권장 이름 (Yggdrasill 기준):
- iPhone 앱: `com.yggdrasill.mneme.mobile`
- watchOS 앱: `com.yggdrasill.mneme.mobile.watch`
- Watch Extension: `com.yggdrasill.mneme.mobile.watch.extension`

등록 절차:
1. https://developer.apple.com/account 로그인
2. **"Certificates, Identifiers & Profiles"** 클릭
3. 좌측 **Identifiers** → 우측 파란 **+** 버튼
4. **App IDs** 선택 → Continue
5. **App** 선택 → Continue
6. 폼 입력:
   - Description: `Yggdrasill Mobile iOS`
   - Bundle ID: **Explicit** → `com.yggdrasill.mneme.mobile`
   - Capabilities: 지금은 아래 3개만 체크
     - [x] Push Notifications
     - [x] Sign In with Apple (필요 시)
     - [x] App Groups (watchOS 연동에 필요)
7. Continue → Register
8. 위 과정을 **watch 용 Bundle ID 2개에도 반복** (Capabilities는 각각 다름 — watch는 Push/App Groups만)

### 4.2 App Group 만들기 (watch-iPhone 데이터 공유용)

1. 같은 페이지에서 좌측 **Identifiers** → 드롭다운을 **App Groups** 로 변경 → **+**
2. Description: `Yggdrasill Mobile Shared`
3. Identifier: `group.com.yggdrasill.mneme.mobile`
4. Continue → Register
5. 다시 **App IDs** 목록으로 가서 3개 Bundle ID 각각 **"Edit"** → App Groups 체크 후 방금 만든 그룹 선택

## 5. APNs 인증 키 생성 (Push 알림용)

> 설계 문서의 "silent push로 Watch context 업데이트" 기능에 필요. **인증서(.p12)가 아닌 인증 키(.p8) 방식 권장** — 만료가 없고 Apple이 공식적으로 미는 방식입니다.

### 5.1 .p8 키 발급

1. https://developer.apple.com/account 로그인
2. **Certificates, Identifiers & Profiles** → 좌측 **Keys** → 파란 **+**
3. Key Name: `Yggdrasill APNs Key`
4. **Apple Push Notifications service (APNs)** 체크
5. Continue → Register
6. **Download** 버튼 클릭 — `.p8` 파일이 다운로드됨
   - ⚠️ **다시 다운로드 불가!** 받자마자 안전한 곳에 백업(예: 1Password, 비밀번호 매니저).
   - 파일명 예: `AuthKey_ABC123DEFG.p8` ← `ABC123DEFG` 부분이 **Key ID**. 메모해둘 것.
7. **Team ID**도 메모 (https://developer.apple.com/account → Membership → Team ID)

이 3개 정보를 안전한 곳에 저장:

```
APNs Key ID:    ABC123DEFG
APNs Team ID:   A1B2C3D4E5
APNs Key File:  AuthKey_ABC123DEFG.p8  (내용 전체, BEGIN/END PRIVATE KEY 포함)
Bundle ID:      com.yggdrasill.mneme.mobile
```

### 5.2 Supabase Edge Function에 등록 (Phase 5에서)

나중에 APNs push를 보낼 Edge Function을 만들 때 아래처럼 환경변수로 등록합니다. **지금 당장 할 필요는 없음**, 참고만.

```bash
# 아직 실행하지 마세요. Phase 5에서 실제로 필요한 명령입니다.
supabase secrets set APNS_KEY_ID="ABC123DEFG"
supabase secrets set APNS_TEAM_ID="A1B2C3D4E5"
supabase secrets set APNS_BUNDLE_ID="com.yggdrasill.mneme.mobile"
supabase secrets set APNS_KEY_P8="$(cat AuthKey_ABC123DEFG.p8)"
```

> 참고: Supabase 공식 가이드는 직접 APNs 호출보다는 FCM(Firebase Cloud Messaging) 경유를 주로 안내합니다. 하지만 iOS만 필요하면 Edge Function에서 **JWT 직접 생성 → APNs HTTP/2 엔드포인트 호출** 이 의존성 적고 심플합니다. Phase 5에 결정.

## 6. TestFlight로 본인 iPhone에 빌드 올리는 법 (첫 테스트)

> 이건 실제 앱 코드가 생긴 Phase 2/3 때 다시 참고하면 되는 섹션입니다. **지금 당장 따라 할 필요는 없어요.** 구경만 하세요.

### 6.1 App Store Connect에서 앱 생성

1. https://appstoreconnect.apple.com 로그인
2. **My Apps** → **+** → **New App**
3. 폼 입력:
   - Platforms: iOS 체크
   - Name: `Yggdrasill` (이미 쓰이는 이름이면 `Yggdrasill Mobile` 등으로)
   - Primary language: Korean
   - Bundle ID: 위에서 만든 `com.yggdrasill.mneme.mobile` 선택
   - SKU: `yggdrasill-mobile-ios-001` (아무거나 유일한 값)
4. Create

### 6.2 Xcode에서 Archive 빌드

프로젝트가 열려있는 Xcode에서:
1. 상단의 디바이스 셀렉터를 **"Any iOS Device (arm64)"** 로 변경
2. 상단 메뉴 **Product → Archive**
3. 빌드가 끝나면 **Organizer** 창이 뜸
4. **Distribute App** → **TestFlight & App Store** → Next → Upload → 서명 설정 자동으로 → Upload

### 6.3 TestFlight에 본인 기기 추가

1. App Store Connect → 방금 업로드한 앱 → **TestFlight** 탭
2. **Internal Testing** → **+** → 본인을 테스터로 추가 (Apple ID 이메일)
3. 빌드가 "Processing" (보통 5~30분) 후 "Ready to Test" 로 바뀜
4. iPhone App Store에서 **"TestFlight"** 앱 설치 → 로그인 → 초대받은 Yggdrasill 앱 설치

이제 본인 iPhone에서 실제 앱이 실행됩니다. 🎉

## 7. 비용 / 기간 요약

| 항목 | 비용 | 기간 |
|---|---|---|
| Apple ID 생성 + 2FA | 0원 | 10분 |
| Apple Developer Program 연회비 | **$99/년 (약 14만원)** | 24~48h 승인 대기 |
| Mac | 중고 M1 MacBook Air ~80만 원 또는 기존 보유 | - |
| Xcode 설치 | 0원 | 1~2시간 (용량 크니 WiFi 환경) |
| 앱 식별자/키 생성 | 0원 | 30분 |
| **첫 달 총비용** | 약 **14만 원**(Mac 제외) | **실 손 작업 3~4시간** |

## 8. 자주 막히는 포인트 (FAQ)

**Q1. 카드 결제가 안 돼요.**
→ 체크카드라면 **해외결제 활성화**를 은행 앱에서 먼저 설정. 한도가 10만 원 이하이면 실패.
→ 그래도 안 되면 VISA/Master 신용카드로 시도.

**Q2. 이름이 영문이 아닌데 한글로 가입해도 돼요?**
→ ❌ 권장 안 함. App Store 판매자명에 한글/한자가 들어가면 이후 글로벌 출시 시 문제가 됩니다. 처음부터 여권 영문명으로.

**Q3. "Individual"과 "Organization" 중 뭐가 좋아요?**
→ 지금은 **Individual**. Organization은 D-U-N-S 번호(회사 고유번호)가 필요하고 심사도 오래 걸림. 나중에 회사 계정으로 **이전 가능**(단, 앱 소유권 이전은 번거로움).

**Q4. Mac이 없어서 클라우드 맥 쓰면 안 되나요?**
→ 기술적으론 가능(MacStadium ~$59/월, MacinCloud ~$30/월)하지만, Xcode가 원격 데스크톱에선 응답이 느리고 시뮬레이터가 자주 멈춥니다. **최소 중고 M1 MacBook Air**를 강력 권장.

**Q5. Windows에서 Xcode 설치할 수 있다던데요?**
→ ❌ 불가능합니다. Hackintosh / 가상머신은 Apple 약관 위반이며 서명·제출도 실패합니다.

**Q6. $99 연회비 안 내면 안 되나요?**
→ "Free Apple ID"로도 Xcode에서 본인 기기 1대에 7일짜리 임시 서명 빌드는 가능합니다. 하지만:
- 7일마다 재설치 필요
- Push 알림·App Groups·CloudKit 등 주요 capability 사용 불가
- TestFlight·App Store 배포 불가
→ **실사용은 불가능.** $99는 투자하세요.

**Q7. Apple Developer Program 가입 후 승인이 3일 넘게 안 와요.**
→ https://developer.apple.com/contact/ 에서 "Membership / Enrollment" 문의. 보통 영어로 쓰면 빠름.
→ 신분증 사진이 흐릿하거나 이름이 Apple ID와 불일치할 때 자주 막힙니다.

## 9. 지금 당장 해야 할 일 (Action Items)

오늘~이번주 안에 여기까지만 끝내두시면, 제가 Phase 1(백엔드 마이그레이션)을 진행하는 동안 Phase 2(iPhone 앱)를 바로 시작할 수 있습니다.

- [ ] **1주차**
  - [ ] 섹션 1: Apple ID 영문 이름/주소/2FA 점검
  - [ ] 섹션 2: Apple Developer Program 가입 신청 → $99 결제
  - [ ] 섹션 3: Mac에 Xcode 최신 버전 설치
- [ ] **가입 승인 직후**
  - [ ] 섹션 4: Bundle ID 3개 + App Group 1개 등록
  - [ ] 섹션 5: APNs .p8 키 발급 → **안전한 곳에 백업** (가장 중요!)
  - [ ] 위 정보 공유 (Team ID, Key ID, Bundle ID는 공유해도 됨. **.p8 파일 원본은 절대 비공개 저장소에만**)

## 10. 준비 끝났다고 알려주실 방법

아래 체크리스트를 복사해서 항목별로 완료 표시해서 알려주시면 Phase 1 마이그레이션 작업을 시작합니다:

```
[ ] Apple Developer Program 승인 완료 (Active 상태 확인)
[ ] Team ID: ____________
[ ] Xcode 16 설치 완료 (xcodebuild -version 결과: ____________)
[ ] Bundle ID 등록: com.yggdrasill.mneme.mobile
[ ] Bundle ID 등록: com.yggdrasill.mneme.mobile.watch
[ ] Bundle ID 등록: com.yggdrasill.mneme.mobile.watch.extension
[ ] App Group: group.com.yggdrasill.mneme.mobile
[ ] APNs Key ID: ____________
[ ] APNs .p8 파일 안전 보관 완료
```

---

_작성: 2026-04-21. Apple 정책은 수시로 바뀌므로, 이 문서와 실제 화면이 다르면 Apple 공식 안내를 우선하세요._
_공식 가이드: https://developer.apple.com/help/account/_
