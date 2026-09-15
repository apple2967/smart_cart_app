# Claude Code 프롬프트

이 앱을 **처음부터 같은 설계로 다시 만들 때** Claude Code에 붙여넣는 프롬프트입니다.

- **새로 만들 때**: 빈 폴더에서 Claude Code를 열고, 아래 "프롬프트" 구역을 통째로 복사해 첫 메시지로 보내세요.
- **이 저장소를 받아서 이어 개발할 때**: 전부 다시 만들 필요 없습니다.
  "`docs/PROMPT.md`의 설계 원칙을 지키면서 휴대폰 백그라운드 처리를 추가해줘"처럼 요청하면 됩니다.

## 준비물

- Flutter SDK (stable), Git
- Windows 앱 빌드: Visual Studio (C++를 사용한 데스크톱 개발)
- 안드로이드 앱 빌드: Android Studio, SDK Command-line Tools, NDK

## 알려진 함정

- **Windows 11 스마트 앱 제어**가 켜져 있으면 `dart.exe`가 차단되어 Flutter 명령이 전혀 동작하지 않습니다.
  예외 등록 기능이 없고, 끄면 Windows를 재설치하기 전까지 다시 켤 수 없습니다. 끄는 대신 WSL2에서 개발하는 방법도 있습니다.
- **NDK 자동 설치 실패**: 첫 안드로이드 빌드 때 Gradle이 NDK를 자동으로 받으려다 `sdkmanager`가 비정상 종료할 수 있습니다.
  Android Studio → Settings → Android SDK → SDK Tools → **Show Package Details**에서 NDK를 직접 설치하고,
  `android/app/build.gradle.kts`의 `ndkVersion`을 설치한 버전으로 맞추세요.
- **Windows 개발자 모드**: 네이티브 코드가 들어간 Flutter 플러그인을 추가하면
  `Building with plugins requires symlink support`로 멈춥니다. 설정 → 시스템 → 개발자용 → 개발자 모드를 켜거나,
  이 저장소처럼 플러그인 없이 안드로이드 코드(MethodChannel)로 직접 구현하세요.
- **삼성 자동 차단기**가 켜져 있으면 USB 디버깅이 막힙니다. 설정 → 보안 및 개인정보 보호 → 자동 차단기.
- **안드로이드 인터넷 권한**: Flutter 기본 템플릿은 개발용 빌드에만 INTERNET 권한을 넣습니다.
  `android/app/src/main/AndroidManifest.xml`에 없으면 릴리스 APK에서만 연결이 안 됩니다. (이 저장소에는 추가되어 있음)
- **소켓 테스트**: `flutter_test`는 HTTP 클라이언트를 가짜로 바꿔 두어 실제 WebSocket 연결이 실패합니다.
  실제 소켓을 쓰는 테스트에서는 `HttpOverrides.global = null`로 잠시 풀고, 가짜 시계를 쓰는 `testWidgets` 대신 `test`로 돌리세요.

---

## 프롬프트

````
스마트카트 조작 앱을 Flutter로 만들 거야. 대상은 안드로이드 휴대폰과 Windows 데스크톱.

## 카트 사양
UWB 태그 추종 + 2D 라이다(RPLIDAR C1) + 차동구동.
24V 250W 모터 2개, Orange Pi + ESP32, 접촉기와 물리 E-stop 있음.
엔코더는 아직 없어서 속도 측정 불가, 제동장치도 미정.
UWB 태그는 사람이 들고 다니고, 자동 모드에서 카트가 그 사람을 따라간다.

## 프로젝트 구조
flutter create --org com.smartcart --platforms=android,windows,web --project-name smart_cart_app .

lib/
  main.dart                          진입점, 빌드 환경에 따라 전송 방식 선택, 안드로이드 시스템 바 설정
  env.dart                           빌드 환경(CART_ENV, CART_URL) 해석
  theme.dart                         다크 색상·타이포 토큰
  models/telemetry.dart              JSON 스키마 모델 (Telemetry, DriveCommand, DriveMode)
  transport/transport.dart           CartTransport 인터페이스, CartLink, MockTransport, FaultInjection
  transport/websocket_transport.dart WebSocket 연결 (dart:io, 재접속)
  widgets/lidar_view.dart            라이다 점군 (CustomPainter)
  widgets/joystick.dart              데드맨 조이스틱
  screens/drive_screen.dart          주행 화면 (수동/자동)
test/widget_test.dart
android/app/src/main/AndroidManifest.xml 에 INTERNET 권한 추가

## 빌드 환경
환경은 빌드할 때 --dart-define으로만 정한다. 앱 안에 전환 스위치를 두지 않는다(실수로 누를 수 있으면 언젠가 누른다).
- CART_ENV=simulation (기본값): 앱 안의 MockTransport. 옵션을 빠뜨리면 이것이 된다(실차에 잘못 붙는 것보다 안전).
- CART_ENV=server + CART_URL=ws://...: PC 등의 테스트 서버에 WebSocket 연결.
- CART_ENV=vehicle + CART_URL=ws://...: 실제 카트에 WebSocket 연결.
- server·vehicle인데 CART_URL이 없거나 ws/wss가 아니거나 호스트가 없으면, 또는 CART_ENV를 모르면
  연결하지 않고 "빌드 설정 오류" 화면(이유와 빌드 예시)만 보여준다.
- `const isSimulationBuild = String.fromEnvironment('CART_ENV', defaultValue: 'simulation') == 'simulation'`처럼
  컴파일 타임 상수로 만들고, MockTransport 생성과 고장 주입 패널을 이 상수로 감싸서
  시뮬레이션이 아닌 빌드에서는 트리 셰이킹으로 코드가 빠지게 한다.
- 화면 상단(상태바 맨 앞)에 환경 배지를 항상 표시: 시뮬레이션·테스트 서버는 액센트색, 실차는 경고색.
  연결 중 경고 블록에는 연결 대상(시뮬레이션이면 "앱 안의 가짜 카트", 아니면 ws 주소)을 표시.

## 통신 스키마
WebSocket 텍스트 프레임 하나에 JSON 하나.

카트 -> 앱 텔레메트리 (10Hz):
{"t":0,"link":{"state":"ok","rtt_ms":18},
 "power":{"battery_pct":78,"battery_v":27.1,"contactor":"closed","estop":false},
 "drive":{"mode":"manual","duty_l":34,"duty_r":34,"current_l":4.2,"current_r":4.4},
 "pose":{"roll":0.8,"pitch":-2.1,"yaw":137.4},
 "lidar":{"seq":8821,"start_deg":0,"step_deg":1,"ranges_mm":[1820,1795,0,1740]},
 "tof":{"left_mm":62,"right_mm":65,"cliff":false},
 "uwb":{"tag":"ok","dist_m":1.4,"bearing_deg":-12},
 "faults":["lidar_slow"]}

앱 -> 카트 명령 (20Hz):
{"seq":4412,"mode":"manual","throttle":0.34,"steer":-0.12,"deadman":true}

필드 규칙:
- 파싱은 관대하게. 섹션·필드가 빠지면 null, 모르는 필드는 무시. 필드 하나 때문에 화면이 죽으면 안 됨.
- duty는 출력 %지 속도가 아님. 엔코더가 들어오면 drive.speed_mps를 추가하되 duty는 유지.
- battery_v는 선택 필드. 부하가 걸리면 전압이 처져서 %가 튀므로, 원인 확인용으로 %와 함께 표시.
- contactor "open"은 구동 전원 차단. 제동이 아님. UI에 "정지"라고 쓰지 말 것.
- faults는 문자열 배열. 앱이 모르는 코드도 원문 그대로 표시.
- 라이다는 각도-거리 객체 배열 말고 시작각+간격+거리배열. 0°=전방, 시계방향 증가. 0은 측정 실패라 그리지 않음.
- uwb.bearing_deg는 전방 기준, 음수=왼쪽. tag가 "ok"일 때만 거리·방향이 유효.
- drive.mode는 카트가 실제 적용 중인 모드("manual" | "follow"). 모르는 문자열도 그대로 표시.
- 명령의 mode는 매 명령에 싣는다. 한 번만 보내면 그 패킷이 빠졌을 때 앱과 카트의 모드가 엇갈린다.
- follow 모드에서 카트는 throttle/steer/deadman을 무시한다.

## 설계 원칙
- 전송 계층은 CartTransport 인터페이스로 격리. 화면은 CartTransport와 CartLink만 알고 WebSocket을 모른다.
- WebSocketTransport: 연결 유지와 JSON 변환만. 연결 타임아웃 3초, 끊기면 0.5초부터 최대 5초까지 간격을 늘리며 재접속.
  깨진 프레임은 버린다. 연결 안 됐을 때 send는 조용히 무시(50ms 뒤 다음 명령이 감).
- CartLink(전송 방식과 무관)가 맡는 일:
  - 20Hz 명령 송신
  - 텔레메트리 워치독: 500ms 안 오면 lost. 소켓 상태가 아니라 수신 간격으로 판정
    (Wi-Fi가 흔들리면 소켓은 열린 채 데이터만 안 오는 경우가 흔함).
  - 끊기면 즉시 조작 해제(deadman:false). 스틱을 누른 채로 복구되면 손을 한 번 뗄 때까지 입력 무시
    (복구 순간 카트가 튀어나가는 것 방지).
  - 모드 전환: 앱은 요청만 하고, 확정은 텔레메트리 drive.mode로.
- 조이스틱은 데드맨. 손 떼면 다음 주기를 기다리지 않고 즉시 deadman:false 송신.
  GestureDetector pan은 터치 슬롭 뒤에 시작하므로 Listener로 포인터를 직접 받는다.
  누른 채 위젯이 사라지면(레이아웃 전환 등) dispose에서 해제.
- 카트 펌웨어(ESP32)는 명령이 200ms 끊기면 모드와 무관하게 출력을 끄고 manual로 돌아간다.
  앱의 조건 검사는 화면 안내용이고, 안전 판단은 카트가 한다.

## 자동(follow) 모드 규칙
- 요청 조건: 링크 live, 조이스틱에서 손 뗌, 구동 전원 연결, uwb.tag == "ok".
  안 되면 자동 버튼을 비활성화하고 이유를 표시.
- 요청 후 약 1초(텔레메트리 10개) 안에 카트가 follow로 안 바뀌면 거부로 보고 수동으로 되돌림.
- 추종 중 카트가 스스로 manual로 돌아가면(태그 끊김 등) 앱도 수동으로 내리고 안내.
- 자동 중 링크가 끊기면 수동으로.
- 한 번 풀린 자동은 조건이 돌아와도 스스로 재개하지 않는다. 사람이 다시 눌러야 한다.
- 자동 중에는 조이스틱 자리에 태그 방향 원을 표시하고 조이스틱은 잠금.
- 상단 모드 표시는 요청한 모드가 아니라 카트가 보고한 모드.

## 휴대폰 상태 처리
- AppLifecycleListener로 앱 상태를 받아 CartLink.pauseControl(hidden:)을 호출.
  - inactive(알림창·전화 화면이 위에 뜸): 조이스틱 즉시 해제, 자동 추종은 유지.
  - hidden·paused·detached(홈·앱 전환·화면 꺼짐): 조이스틱 해제 + 자동이면 수동으로(ModeDrop.appHidden).
  - resumed: 아무것도 재개하지 않음. 누르던 중이었다면 손을 한 번 떼야 조이스틱 동작.
- 조작 화면이 떠 있는 동안 화면 꺼짐 방지. 추종 중엔 화면을 안 만지므로 없으면 화면이 꺼지는 순간 자동이 풀린다.
  안드로이드 MainActivity에서 MethodChannel("smart_cart/screen")의 "keepOn"으로 FLAG_KEEP_SCREEN_ON을 켜고 끈다.
  (wakelock 플러그인은 Windows에서 개발자 모드가 필요해서 쓰지 않음. Windows·테스트에서는 MissingPluginException을 무시.)
- 화면 맨 아래에 "v버전 · 환경 · 연결 주소" 표시. 버전 상수(appVersion)는 pubspec.yaml version과 같아야 하고 테스트로 확인.

## 화면
- 폭 960 이상이거나 가로가 세로보다 긴 화면(휴대폰 가로 포함): 좌우 배치.
  왼쪽: 상태바·경고·라이다. 오른쪽(폭 min(460, 화면폭×0.55)): 수치 카드와 고장 주입(스크롤) + 조작 카드.
- 그 외(휴대폰 세로): 상태바·경고 / 스크롤(라이다 높이 320, 수치 카드, 고장 주입) / 조작 카드.
- 경고 영역은 화면 높이 일부로 제한하고 넘치면 스크롤. 경고가 쌓여도 조작 카드를 밀어내면 안 됨.
- 상태바: 환경 배지, 연결 상태 점·문구·RTT, 오른쪽에 카트 보고 모드.
- 수치 카드 2열: 배터리(%, "27.3 V · 구동 연결"), 태그 거리(방향·태그 상태), 출력 좌/우(duty %, 전류),
  속도(엔코더 없으면 "—"와 "엔코더 미장착"), 피치(롤·방위), 측면 근접(ToF 좌/우, 낙차), 라이다 유효율.
  휴대폰 카드 폭에서 부가 설명이 잘리지 않게 짧게.
- 경고 블록: 연결 중(연결 대상) / 연결 끊김("마지막 수신 N초 전 · 명령이 200ms 끊기면 카트가 모터 출력을 끕니다 (제동 아님)")
  / 자동 모드 해제됨(이유) / 구동 전원 차단됨(E-stop 여부, 제동이 아니라 경사에서 굴러갈 수 있음) / 고장 코드 목록.
- 연결이 끊기면 라이다·수치를 흐리게(투명도 0.35)하고 조이스틱 비활성. 고장 주입 패널은 흐리게 하지 않음.
- 조작 카드: [수동|자동] 세그먼트. 수동이면 조이스틱과 스로틀/조향 값, 자동이면 태그 방향 원과 거리/방향.
- 라이다 뷰: 카트가 중심, 전방이 위, 1 m 간격 링, 최대 6 m, UWB 태그(사람) 위치를 흰 원으로.
- 숫자: 음수는 하이픈 대신 U+2212(−), "-0.0"은 "0.0", 값 없음은 "—".
- 안드로이드: edge-to-edge, 하단 내비게이션 바의 반투명 막(contrast enforced) 끔.

## 디자인
다크 고정, 순검정(#000) 금지.
배경 #17171A, 카드 #212126, 텍스트 #F2F2F5, 흐린글씨 #8A8A92,
경고 #F09595, 경고배경 #2A2024, 액센트 #85B7EB, 그리드 #3C3C44.
테두리·구분선 없이 면 톤 차이로 구분. 모서리 18px.
큰 숫자 46px w500 letter-spacing -1.5 (tabular figures), 라벨 13px 회색. 조이스틱 164px.

## MockTransport
깨끗한 mock으로 만든 UI는 실물에서 무너진다. 일부러 지저분하게 만들 것.
- 폭 3.2 m 복도(전방 6 m, 후방 2.5 m). 카트는 duty에 따라 실제로 이동·회전하고, 태그를 든 사람이 복도를 오간다.
- 라이다: 카트 위치에서 360° 광선을 쏴 벽·사람(원)까지 거리. 0값 4% 섞기, ±12 mm 노이즈, 12 m 초과는 0.
- UWB: 거리 ±5 cm, 방향 ±6° 흔들림. 전류·RTT·자세 노이즈. 부하에 따른 전압 처짐.
- 텔레메트리는 JSON 문자열로 인코딩했다가 디코딩해서 실물과 같은 파싱 경로를 탄다.
- 카트 안전 동작 흉내: 명령이 200ms 끊기면 출력 0·manual, follow는 태그 정상+E-stop 아님일 때만,
  E-stop이면 출력 즉시 0.
- follow 제어(펌웨어 흉내): 태그 방향으로 조향, 1.2 m보다 멀면 전진.
- 고장 주입 토글: 통신 끊기, 태그 신호 끊김, 배터리 저하(앱이 모르는 코드 "bms_cell_imbalance" 포함), E-stop.

## 테스트
- 설계 예시 JSON 파싱, 섹션 누락·모르는 고장 코드
- 명령 JSON에 mode 포함
- EnvConfig: 기본값 시뮬레이션, server·vehicle의 주소 누락·잘못된 스킴·빈 호스트 오류, 모르는 환경 이름 오류
- WebSocketTransport: 로컬 HttpServer로 수신·송신, 깨진 프레임 무시, 서버가 끊으면 재접속
- CartLink: 500ms 끊김 → lost·조작 해제, 복구 후 손 떼기 전까지 입력 무시
- CartLink 자동 모드: 요청 차단 조건, 확정, 카트가 해제, 거부(약 1초), 링크 끊김
- 화면: 시뮬레이션 배지, 통신 끊기 토글 → 끊김 표시, 배터리 저하·E-stop 표시와 화면에 "정지" 단어 없음,
  자동 전환 후 태그 끊김, 실차 환경의 배지·연결 주소·고장 주입 패널 없음, 설정 오류 화면
- 레이아웃: 휴대폰 세로 390×844, 가로 844×390에서 넘침 없음(수동·자동 모두)

작업이 끝나면 flutter analyze 0건, flutter test 전부 통과를 확인해줘.
실차 빌드(--dart-define=CART_ENV=vehicle ...)의 컴파일 결과물(Windows면 data/app.so)에
MockTransport에만 있는 문자열이 없는지도 확인해줘.
````
