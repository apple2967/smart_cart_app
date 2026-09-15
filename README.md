# smart_cart_app

UWB 태그를 든 사람을 따라가는 스마트카트를 조작하고 상태를 보는 Flutter 앱입니다.
안드로이드 휴대폰과 Windows에서 동작합니다.

> **현재 상태**: 앱은 가짜 카트(시뮬레이션)와 WebSocket 연결(테스트 서버·실차)을 모두 지원합니다.
> 카트 쪽 펌웨어와 WebSocket 서버는 아직 없습니다.

## 안드로이드에 설치해서 써보기

[Releases](../../releases)에서 `app-release.apk`를 받아 휴대폰에 설치합니다. 릴리스 APK는 **시뮬레이션 빌드**입니다.

- 스토어 밖에서 받은 앱이라 설치할 때 **"출처를 알 수 없는 앱 설치" 허용**이 필요합니다.
- 삼성 **자동 차단기**가 켜져 있으면 설치가 막힙니다. (설정 → 보안 및 개인정보 보호 → 자동 차단기)
- 테스트용 서명(디버그 키)이라 스토어 배포용이 아닙니다.
- 저장소가 비공개라 초대받은 사람만 받을 수 있습니다.

## 빌드 환경: 시뮬레이션 / 테스트 서버 / 실차

환경은 **빌드할 때만** 정합니다. 앱 안에는 전환 스위치가 없습니다. 실수로 누를 수 있는 스위치는 언젠가 누르게 되기 때문입니다.

| 환경 | 연결 대상 | 화면 상단 배지 | 고장 주입 패널 |
|---|---|---|---|
| `simulation` (기본값) | 앱 안의 가짜 카트 | 파란 **시뮬레이션** | 있음 |
| `server` | PC 등의 테스트 서버 (WebSocket) | 파란 **테스트 서버** | 없음 |
| `vehicle` | 실제 카트 (WebSocket) | 붉은 **실차** | 없음 |

```bash
# 시뮬레이션 (아무 옵션 없으면 이것)
flutter run

# 테스트 서버
flutter run --dart-define=CART_ENV=server --dart-define=CART_URL=ws://192.168.0.10:8765

# 실차
flutter build apk --release --dart-define=CART_ENV=vehicle --dart-define=CART_URL=ws://192.168.4.1:8765
```

- **옵션을 빠뜨리면 시뮬레이션**이 됩니다. 설정을 빠뜨린 빌드가 실차에 붙는 것보다 안 붙는 쪽이 안전합니다.
- `server`·`vehicle`인데 `CART_URL`이 없거나 `ws://`로 시작하지 않으면, 연결하지 않고 **빌드 설정 오류** 화면만 띄웁니다.
- 시뮬레이션이 아닌 빌드에는 **가짜 카트 코드와 고장 주입 패널이 아예 들어가지 않습니다** (컴파일 시점에 제거).
- 연결이 끊기면 0.5초부터 최대 5초 간격으로 스스로 재접속합니다.
- 위 IP와 포트는 예시입니다. 카트 쪽 서버 주소가 정해지면 그 값을 쓰세요.

## 화면 구성

- **상태바**: 빌드 환경 배지, 연결 상태·지연(RTT), 카트가 보고한 실제 모드
- **라이다**: 점군과 UWB 태그(사람) 위치
- **수치 카드**: 배터리(%·전압), 태그 거리, 모터 출력·전류, 속도, 자세, 측면 근접, 라이다 유효율
- **조작**: [수동 | 자동] 전환, 데드맨 조이스틱 / 태그 추종 표시
- **고장 주입** (시뮬레이션 전용): 통신 끊기, 태그 신호 끊김, 배터리 저하, E-stop
- **맨 아래**: 앱 버전 · 빌드 환경 · 연결 주소. 필드에서 문제가 났을 때 어느 빌드였는지 확인용

## 휴대폰을 쓰는 동안의 동작

| 상황 | 조이스틱 | 자동 추종 |
|---|---|---|
| 알림창을 내림, 전화 화면이 위에 뜸 | 즉시 해제 | 유지 |
| 홈 버튼, 앱 전환, 화면 꺼짐 | 즉시 해제 | **수동으로 해제** |

- 앱으로 돌아와도 자동은 스스로 재개하지 않습니다. 누르던 중이었다면 손을 한 번 떼야 조이스틱이 다시 동작합니다.
- **조작 화면이 떠 있는 동안 휴대폰 화면이 꺼지지 않습니다** (안드로이드). 추종 중에는 화면을 만지지 않으므로,
  이게 없으면 화면이 꺼지는 순간 자동이 풀립니다. 대신 배터리를 더 씁니다.

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

설치 중 막히는 부분(스마트 앱 제어, NDK, USB 디버깅)은 [docs/PROMPT.md의 알려진 함정](docs/PROMPT.md#알려진-함정)을 보세요.

## PC 테스트 서버

실제 카트 없이 **실제 Wi-Fi 위에서** 휴대폰 앱을 확인하는 가짜 카트 서버입니다.
앱의 시뮬레이션과 같은 가짜 카트(`CartSimulator`)를 쓰고, 카트 쪽 서버를 만들 때 통신 규약의 참고 구현이 됩니다.

```bash
dart run tool/cart_server.dart          # 포트 8765
```

1. 서버를 켜면 이 PC의 주소 목록이 나옵니다. 휴대폰과 **같은 Wi-Fi**의 주소를 고르세요.
2. **Windows 방화벽** 창이 뜨면 허용을 눌러야 휴대폰이 붙습니다.
   PC의 Wi-Fi가 "공용 네트워크"로 설정돼 있으면 막힐 수 있습니다.
3. 휴대폰 앱을 테스트 서버 빌드로 설치합니다.
   ```bash
   flutter run --release --dart-define=CART_ENV=server --dart-define=CART_URL=ws://192.168.0.10:8765
   ```

서버 창에 명령을 입력하거나, **서버를 실행한 PC의 브라우저**에서 조작합니다. 다른 기기에서는 조작할 수 없습니다.

| 서버 창 명령 | 브라우저 | 하는 일 |
|---|---|---|
| `status` | `http://localhost:8765/` | 현재 상태 |
| `preset good` / `weak` / `bad` | `/preset?name=bad` | 네트워크 프리셋 |
| `net delay=80 jitter=120 loss=5` | `/net?delay=80&jitter=120&loss=5` | 지연·흔들림·손실 직접 설정 |
| `hold 1500` | `/hold?ms=1500` | 1.5초 동안 붙잡았다가 한꺼번에 내보냄 (Wi-Fi 음영) |
| `kick` | `/kick` | 앱 연결 끊기. 앱이 스스로 다시 붙는지 확인 |
| `fault tag=off estop=on battery=low` | `/fault?tag=off` | 가짜 카트 고장 |

- WebSocket은 TCP라서 **손실은 데이터가 사라지는 게 아니라 멈췄다가 한꺼번에 몰려오는 형태**로 나타납니다. 서버도 그렇게 흉내 냅니다.
- 음영 뒤 몰려온 **오래된 명령도 카트는 구분하지 못하고 그대로 실행합니다.** 서버는 200ms 넘게 늦은 명령을 경고로 보여줍니다.
  통신 규약에 보낸 시각이나 유효 기간을 넣어야 하는 이유입니다.

## 코드 구조

```
lib/
  main.dart                          진입점. 빌드 환경에 따라 전송 방식 선택, 앱 수명주기·화면 꺼짐 방지
  env.dart                           빌드 환경(CART_ENV, CART_URL)과 앱 버전
  theme.dart                         다크 색상·타이포 토큰
  models/telemetry.dart              통신 JSON 모델
  sim/cart_simulator.dart            가짜 카트 (Flutter 없이 동작, 앱과 PC 서버가 같이 씀)
  transport/transport.dart           CartTransport 인터페이스, CartLink(명령 송신·워치독·모드), MockTransport
  transport/websocket_transport.dart 실차·테스트 서버용 WebSocket 연결 (재접속)
  widgets/lidar_view.dart            라이다 점군
  widgets/joystick.dart              데드맨 조이스틱
  screens/drive_screen.dart          주행 화면
tool/cart_server.dart                PC 테스트 서버 (네트워크 흉내, 조작 API)
test/widget_test.dart                파싱·환경·가짜 카트·서버·링크·모드·수명주기·화면·레이아웃 테스트
docs/PROMPT.md                       Claude Code로 같은 설계를 재현·확장하는 프롬프트
```

## 통신 규약

카트 펌웨어를 만드는 사람을 위한 요약입니다. 필드별 세부 규칙은 [docs/PROMPT.md](docs/PROMPT.md)에 있습니다.
전송은 WebSocket 텍스트 프레임 하나에 JSON 하나입니다.

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
- 조이스틱을 오른쪽으로 밀었을 때 실제로 오른쪽으로 도는지, 태그를 왼쪽에 두었을 때 `bearing_deg`가 음수인지 확인

## Claude Code로 이어서 개발하기

[docs/PROMPT.md](docs/PROMPT.md)에 이 앱의 설계 전체를 담은 프롬프트가 있습니다.
저장소를 받은 뒤 Claude Code에서 "`docs/PROMPT.md`의 설계 원칙을 지키면서 …해줘"라고 요청하면 됩니다.

## 라이선스

[MIT](LICENSE). 저작권 표시를 남기면 누구나 자유롭게 쓰고 고치고 배포할 수 있습니다.

이 앱은 실제로 움직이는 카트를 조작합니다. 코드는 **보증 없이** 제공되며,
실차에 쓰기 전에 카트 쪽 안전장치(명령 끊김 감시, E-stop, 제동)를 반드시 직접 확인하세요.
