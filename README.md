# smart_cart_app

UWB 태그를 든 사람을 따라가는 스마트카트를 조작하고 상태를 보는 Flutter 앱입니다.
안드로이드 휴대폰과 Windows에서 동작합니다.

> **현재 상태**: 가짜 카트(`MockTransport`)로 동작합니다. 실물 카트 연결(`WebSocketTransport`)은 아직 없습니다.

## 안드로이드에 설치해서 써보기

[Releases](../../releases)에서 `app-release.apk`를 받아 휴대폰에 설치합니다.

- 스토어 밖에서 받은 앱이라 설치할 때 **"출처를 알 수 없는 앱 설치" 허용**이 필요합니다.
- 삼성 **자동 차단기**가 켜져 있으면 설치가 막힙니다. (설정 → 보안 및 개인정보 보호 → 자동 차단기)
- 테스트용 서명(디버그 키)이라 스토어 배포용이 아닙니다.
- 저장소가 비공개라 초대받은 사람만 받을 수 있습니다.

## 화면 구성

- **상태바**: 연결 상태·지연(RTT), 카트가 보고한 실제 모드
- **라이다**: 점군과 UWB 태그(사람) 위치
- **수치 카드**: 배터리(%·전압), 태그 거리, 모터 출력·전류, 속도, 자세, 측면 근접, 라이다 유효율
- **조작**: [수동 | 자동] 전환, 데드맨 조이스틱 / 태그 추종 표시
- **고장 주입** (Mock 전용): 통신 끊기, 태그 신호 끊김, 배터리 저하, E-stop

## 개발 환경

- Flutter (stable), Git
- Windows 빌드: Visual Studio (C++를 사용한 데스크톱 개발)
- 안드로이드 빌드: Android Studio, SDK Command-line Tools, NDK `30.0.16248370`
  (`android/app/build.gradle.kts`의 `ndkVersion`)

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d windows          # Windows에서 실행
flutter devices                 # 연결된 휴대폰 ID 확인
flutter run -d <기기ID>          # 휴대폰에서 실행
flutter build apk --release     # build/app/outputs/flutter-apk/app-release.apk
```

설치 중 막히는 부분(스마트 앱 제어, NDK, USB 디버깅, 인터넷 권한)은 [docs/PROMPT.md의 알려진 함정](docs/PROMPT.md#알려진-함정)을 보세요.

## 코드 구조

```
lib/
  main.dart                 진입점. 전송 방식을 여기서 한 줄로 교체
  theme.dart                다크 색상·타이포 토큰
  models/telemetry.dart     통신 JSON 모델
  transport/transport.dart  CartTransport 인터페이스, CartLink(명령 송신·워치독·모드), MockTransport
  widgets/lidar_view.dart   라이다 점군
  widgets/joystick.dart     데드맨 조이스틱
  screens/drive_screen.dart 주행 화면
test/widget_test.dart       파싱·링크·모드·화면·휴대폰 레이아웃 테스트
docs/PROMPT.md              Claude Code로 같은 설계를 재현·확장하는 프롬프트
```

## 통신 규약

카트 펌웨어를 만드는 사람을 위한 요약입니다. 필드별 세부 규칙은 [docs/PROMPT.md](docs/PROMPT.md)에 있습니다.

**카트 → 앱 텔레메트리 (10Hz)**

```json
{"t":0,"link":{"state":"ok","rtt_ms":18},
 "power":{"battery_pct":78,"battery_v":27.1,"contactor":"closed","estop":false},
 "drive":{"mode":"manual","duty_l":34,"duty_r":34,"current_l":4.2,"current_r":4.4},
 "pose":{"roll":0.8,"pitch":-2.1,"yaw":137.4},
 "lidar":{"seq":8821,"start_deg":0,"step_deg":1,"ranges_mm":[1820,1795,0,1740]},
 "tof":{"left_mm":62,"right_mm":65,"cliff":false},
 "uwb":{"tag":"ok","dist_m":1.4,"bearing_deg":-12},
 "faults":["lidar_slow"]}
```

**앱 → 카트 명령 (20Hz)**

```json
{"seq":4412,"mode":"manual","throttle":0.34,"steer":-0.12,"deadman":true}
```

### 카트 쪽이 반드시 지켜야 할 것

앱의 검사는 화면 안내용입니다. **안전 판단은 카트가 해야 합니다.**

- 명령이 **200ms** 끊기면 모드와 상관없이 모터 출력을 끄고 `manual`로 돌아갈 것. 이 감시는 Orange Pi가 아니라 **ESP32**에 둘 것
- `deadman`이 `false`면 수동 명령의 `throttle`/`steer`를 무시할 것
- 명령의 `mode`를 읽고, 텔레메트리 `drive.mode`에는 **실제로 적용 중인 모드**를 보낼 것
- `follow`는 태그 정상 + E-stop 아님일 때만 받아들이고, 태그가 끊기면 스스로 `manual`로 돌아갈 것
- `contactor: "open"`은 제동이 아님. 경사에서 굴러가지 않게 제동장치가 필요함
- 가능하면 `power.battery_v`도 보낼 것

## 실물 카트로 처음 움직일 때

- **바퀴를 바닥에서 띄운 상태**로 시작
- 물리 E-stop이 접촉기를 확실히 끊는지 먼저 확인
- 주행 중 휴대폰 Wi-Fi를 꺼서 카트가 0.2초 안에 출력을 끄는지 확인

## Claude Code로 이어서 개발하기

[docs/PROMPT.md](docs/PROMPT.md)에 이 앱의 설계 전체를 담은 프롬프트가 있습니다.
저장소를 받은 뒤 Claude Code에서 "`docs/PROMPT.md`의 설계 원칙을 지키면서 …해줘"라고 요청하면 됩니다.
