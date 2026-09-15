import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_cart_app/env.dart';
import 'package:smart_cart_app/main.dart';
import 'package:smart_cart_app/models/telemetry.dart';
import 'package:smart_cart_app/screens/drive_screen.dart';
import 'package:smart_cart_app/sim/cart_simulator.dart';
import 'package:smart_cart_app/theme.dart';
import 'package:smart_cart_app/transport/transport.dart';
import 'package:smart_cart_app/transport/websocket_transport.dart';

import '../tool/cart_server.dart' show CartServer, LinkShaper, NetConditions;

/// 설계 문서의 텔레메트리 예시 그대로.
const _specExample = '''
{"t":0,"link":{"state":"ok","rtt_ms":18},
 "power":{"battery_pct":78,"contactor":"closed","estop":false},
 "drive":{"mode":"manual","duty_l":34,"duty_r":34,"current_l":4.2,"current_r":4.4},
 "pose":{"roll":0.8,"pitch":-2.1,"yaw":137.4},
 "lidar":{"seq":8821,"start_deg":0,"step_deg":1,"ranges_mm":[1820,1795,0,1740]},
 "tof":{"left_mm":62,"right_mm":65,"cliff":false},
 "uwb":{"tag":"ok","dist_m":1.4,"bearing_deg":-12},
 "faults":["lidar_slow"]}
''';

/// 설계 문서 예시에서 모드와 태그 상태만 바꾼 텔레메트리.
Telemetry _telemetry({String mode = 'manual', String tag = 'ok'}) {
  final j = jsonDecode(_specExample) as Map<String, dynamic>;
  (j['drive'] as Map<String, dynamic>)['mode'] = mode;
  (j['uwb'] as Map<String, dynamic>)['tag'] = tag;
  return Telemetry.fromJson(j);
}

class _FakeTransport implements CartTransport {
  final controller = StreamController<Telemetry>.broadcast();
  final sent = <DriveCommand>[];

  @override
  Stream<Telemetry> get telemetry => controller.stream;

  @override
  void send(DriveCommand command) => sent.add(command);

  @override
  Future<void> close() => controller.close();
}

/// 모든 패널이 스크롤 없이 보이는 크기로 테스트 화면을 잡는다.
void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('Telemetry.fromJson', () {
    test('설계 문서 예시를 파싱한다', () {
      final t = _telemetry();
      expect(t.drive?.dutyL, 34);
      expect(t.drive?.speedMps, isNull);
      expect(t.power?.driveCutOff, isFalse);
      expect(t.power?.batteryV, isNull);
      expect(t.lidar?.rangesMm, [1820, 1795, 0, 1740]);
      expect(t.lidar?.validCount, 3);
      expect(t.uwb?.bearingDeg, -12);
      expect(t.faults, ['lidar_slow']);
    });

    test('섹션이 빠지거나 모르는 고장 코드가 와도 죽지 않는다', () {
      final t = Telemetry.fromJson({
        't': 5,
        'faults': ['code_from_future_firmware'],
      });
      expect(t.lidar, isNull);
      expect(t.power, isNull);
      expect(t.faults, ['code_from_future_firmware']);
    });

    test('명령 JSON에 모드가 실린다', () {
      const cmd = DriveCommand(
        seq: 1,
        mode: DriveMode.follow,
        throttle: 0.123,
        steer: -0.5,
        deadman: false,
      );
      expect(cmd.toJson(), {
        'seq': 1,
        'mode': 'follow',
        'throttle': 0.12,
        'steer': -0.5,
        'deadman': false,
      });
    });
  });

  group('EnvConfig', () {
    test('이 테스트 빌드는 시뮬레이션이다', () {
      expect(isSimulationBuild, isTrue);
      expect(EnvConfig.current.env, CartEnv.simulation);
      expect(EnvConfig.current.error, isNull);
    });

    test('테스트 서버·실차는 ws 주소가 없거나 틀리면 오류', () {
      expect(EnvConfig.parse('vehicle', '').error, isNotNull);
      expect(EnvConfig.parse('server', 'http://192.168.0.10:8765').error,
          isNotNull);
      expect(EnvConfig.parse('vehicle', 'ws://').error, isNotNull);

      final ok = EnvConfig.parse('vehicle', 'ws://192.168.4.1:8765');
      expect(ok.error, isNull);
      expect(ok.env, CartEnv.vehicle);
      expect(ok.url?.host, '192.168.4.1');
      expect(ok.url?.port, 8765);
    });

    test('모르는 환경 이름은 오류', () {
      final c = EnvConfig.parse('field', 'ws://192.168.4.1:8765');
      expect(c.env, isNull);
      expect(c.error, isNotNull);
    });

    test('앱에 표시하는 버전이 pubspec.yaml과 같다', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(r'^version:\s*([0-9.]+)\+', multiLine: true)
          .firstMatch(pubspec);
      expect(match?.group(1), appVersion);
    });
  });

  test('명령 JSON 읽기: 되돌리면 같고, 이상한 값은 가장 안전한 쪽으로', () {
    const cmd = DriveCommand(
      seq: 9,
      mode: DriveMode.follow,
      throttle: 0.25,
      steer: -0.5,
      deadman: true,
    );
    expect(DriveCommand.fromJson(cmd.toJson()).toJson(), cmd.toJson());

    final weird = DriveCommand.fromJson({
      'mode': 'turbo',
      'throttle': 7,
      'steer': double.nan,
      'deadman': 'yes',
    });
    expect(weird.mode, DriveMode.manual);
    expect(weird.throttle, 0); // 최대치로 자르지 않고 0
    expect(weird.steer, 0);
    expect(weird.deadman, isFalse);
  });

  test('CartSimulator: 명령이 200ms 끊기면 출력 0, 태그가 없으면 follow 거부', () {
    final sim = CartSimulator(random: math.Random(1));
    const drive = DriveCommand(
      seq: 1,
      mode: DriveMode.manual,
      throttle: 0.5,
      steer: 0,
      deadman: true,
    );
    for (var i = 0; i < 5; i++) {
      sim.receive(drive);
      sim.step();
    }
    expect(sim.dutyL, greaterThan(40));

    for (var i = 0; i < 10; i++) {
      sim.step();
    }
    expect(sim.dutyL, 0);

    const follow = DriveCommand(
      seq: 2,
      mode: DriveMode.follow,
      throttle: 0,
      steer: 0,
      deadman: false,
    );
    sim.tagLost = true;
    sim.receive(follow);
    sim.step();
    expect(sim.mode, DriveMode.manual);

    sim.tagLost = false;
    sim.receive(follow);
    sim.step();
    expect(sim.mode, DriveMode.follow);
  });

  test('LinkShaper: 지연·손실이 있어도 순서는 그대로, 붙잡으면 몰려서 나온다', () async {
    final got = <String>[];
    final ages = <int>[];
    final shaper = LinkShaper(
      (message, queuedMs) {
        got.add(message);
        ages.add(queuedMs);
      },
      random: math.Random(7),
    )..conditions =
        const NetConditions(delayMs: 20, jitterMs: 40, lossPercent: 30);
    addTearDown(shaper.close);

    for (var i = 0; i < 20; i++) {
      shaper.push('$i');
    }
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(got, [for (var i = 0; i < 20; i++) '$i']);

    got.clear();
    ages.clear();
    shaper
      ..conditions = const NetConditions()
      ..holdFor(const Duration(milliseconds: 300));
    for (var i = 0; i < 3; i++) {
      shaper.push('h$i');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(got, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(got, ['h0', 'h1', 'h2']);
    expect(ages.first, greaterThanOrEqualTo(250));
  });

  test('테스트 서버: 앱이 붙어 조작하고, 음영이면 끊김 판정, 서버가 끊어도 다시 붙는다', () async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = saved);

    final server = CartServer(random: math.Random(3));
    final port = await server.start(port: 0, address: InternetAddress.loopbackIPv4);
    addTearDown(server.close);

    final link = CartLink(WebSocketTransport(Uri.parse('ws://127.0.0.1:$port')));
    addTearDown(link.dispose);

    Future<void> waitFor(String what, bool Function() condition) async {
      final watch = Stopwatch()..start();
      while (!condition()) {
        if (watch.elapsed > const Duration(seconds: 4)) fail('시간 초과: $what');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    await waitFor('연결', () => link.status == LinkStatus.live);
    expect(server.clientCount, 1);

    // 조이스틱 명령이 서버의 가짜 카트까지 닿는다
    link.hold(0.6, 0);
    await waitFor('가짜 카트 출력', () => server.sim.dutyL > 30);
    link.release();

    // Wi-Fi 음영 1초: 앱은 500ms 뒤 끊김으로 보고, 몰려온 뒤 다시 연결됨으로
    expect(server.control('hold', {'ms': '1000'}), contains('1000ms'));
    await waitFor('끊김 판정', () => link.status == LinkStatus.lost);
    await waitFor('복구', () => link.status == LinkStatus.live);

    // 서버가 연결을 끊으면 앱이 스스로 다시 붙는다
    server.control('kick', {});
    expect(server.clientCount, 0);
    await waitFor('재접속', () => server.clientCount == 1);
  });

  // 실제 소켓을 쓰므로 가짜 시계(testWidgets)가 아니라 일반 test로 돌린다.
  test('WebSocketTransport: 수신·송신, 깨진 프레임 무시, 서버가 끊으면 재접속', () async {
    // flutter_test는 기본적으로 HTTP를 가짜로 바꿔 두므로 이 테스트에서만 실제 소켓을 쓴다
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = saved);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var accepted = Completer<WebSocket>();
    server.transform(WebSocketTransformer()).listen((ws) {
      if (!accepted.isCompleted) accepted.complete(ws);
    });

    final transport =
        WebSocketTransport(Uri.parse('ws://127.0.0.1:${server.port}'));
    addTearDown(transport.close);
    const timeout = Duration(seconds: 3);

    final first = await accepted.future.timeout(timeout);
    final received = transport.telemetry.first;
    first.add('{not json');
    first.add(_specExample);
    expect((await received.timeout(timeout)).drive?.dutyL, 34);

    final command = Completer<String>();
    first.listen((m) {
      if (!command.isCompleted) command.complete(m as String);
    });
    transport.send(const DriveCommand(
      seq: 7,
      mode: DriveMode.manual,
      throttle: 0.5,
      steer: 0,
      deadman: true,
    ));
    final sent =
        jsonDecode(await command.future.timeout(timeout)) as Map<String, dynamic>;
    expect(sent['seq'], 7);
    expect(sent['mode'], 'manual');
    expect(sent['deadman'], isTrue);

    accepted = Completer<WebSocket>();
    await first.close();
    final second = await accepted.future.timeout(timeout);
    expect(identical(second, first), isFalse);
  });

  // testWidgets는 가짜 시계를 쓰므로 타이머를 실제로 기다리지 않는다.
  testWidgets('CartLink: 500ms 끊기면 lost + 조작 해제, 복구 후엔 손을 다시 떼야 함',
      (tester) async {
    final fake = _FakeTransport();
    final link = CartLink(fake);

    fake.controller.add(_telemetry());
    await tester.pump();
    expect(link.status, LinkStatus.live);

    link.hold(0.5, 0.1);
    await tester.pump(const Duration(milliseconds: 60));
    expect(fake.sent.last.deadman, isTrue);
    expect(fake.sent.last.throttle, 0.5);

    await tester.pump(const Duration(milliseconds: 600));
    expect(link.status, LinkStatus.lost);
    expect(fake.sent.last.deadman, isFalse);
    expect(fake.sent.last.throttle, 0);

    // 복구돼도 스틱을 계속 밀고 있으면 명령이 나가지 않는다
    fake.controller.add(_telemetry());
    await tester.pump();
    expect(link.status, LinkStatus.live);
    link.hold(0.5, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(fake.sent.last.deadman, isFalse);

    // 손을 뗐다가 다시 누르면 정상
    link.release();
    expect(fake.sent.last.deadman, isFalse);
    link.hold(0.5, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(fake.sent.last.deadman, isTrue);

    link.dispose();
  });

  testWidgets('CartLink: 자동 모드 확정·카트 해제·거부·끊김', (tester) async {
    final fake = _FakeTransport();
    final link = CartLink(fake);

    Future<void> receive({String mode = 'manual', String tag = 'ok'}) async {
      fake.controller.add(_telemetry(mode: mode, tag: tag));
      await tester.pump();
    }

    // 태그 신호가 없으면 자동 요청 불가
    await receive(tag: 'lost');
    expect(link.followBlock, FollowBlock.tagNotOk);
    expect(link.requestMode(DriveMode.follow), isFalse);
    expect(link.requestedMode, DriveMode.manual);

    // 조이스틱을 누르고 있어도 불가
    await receive();
    link.hold(0.3, 0);
    expect(link.followBlock, FollowBlock.stickHeld);
    link.release();

    // 요청 즉시 명령에 mode:follow, 카트가 follow로 보고하면 확정
    expect(link.requestMode(DriveMode.follow), isTrue);
    expect(fake.sent.last.mode, DriveMode.follow);
    expect(link.followPending, isTrue);
    await receive(mode: 'follow');
    expect(link.followPending, isFalse);

    // 자동 중엔 조이스틱 입력 무시
    link.hold(0.5, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(fake.sent.last.deadman, isFalse);

    // 카트가 스스로 수동으로 돌아가면 앱도 요청을 내린다 — 태그가 돌아와도 재개 안 함
    await receive(mode: 'manual', tag: 'lost');
    expect(link.requestedMode, DriveMode.manual);
    expect(link.modeDrop, ModeDrop.droppedByCart);
    await receive();
    expect(fake.sent.last.mode, DriveMode.manual);

    // 카트가 끝내 follow로 안 바뀌면 거부
    link.requestMode(DriveMode.follow);
    expect(link.modeDrop, isNull);
    for (var i = 0; i < 11; i++) {
      await receive();
    }
    expect(link.requestedMode, DriveMode.manual);
    expect(link.modeDrop, ModeDrop.rejected);

    // 자동 중 링크가 끊기면 수동으로
    link.requestMode(DriveMode.follow);
    await receive(mode: 'follow');
    await tester.pump(const Duration(milliseconds: 600));
    expect(link.status, LinkStatus.lost);
    expect(link.requestedMode, DriveMode.manual);
    expect(link.modeDrop, ModeDrop.linkLost);
    expect(fake.sent.last.mode, DriveMode.manual);

    link.dispose();
  });

  testWidgets('CartLink: 앱이 가려지면 조작 해제, 사라지면 자동도 해제', (tester) async {
    final fake = _FakeTransport();
    final link = CartLink(fake);
    fake.controller.add(_telemetry());
    await tester.pump();

    // 누르던 중 가려짐 → 즉시 deadman:false. 돌아와서 스틱이 밀린 채면 무시
    link.hold(0.4, 0);
    link.pauseControl(hidden: false);
    expect(fake.sent.last.deadman, isFalse);
    link.hold(0.4, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(fake.sent.last.deadman, isFalse);
    link.release();

    // 자동 중 가려지기만 하면(알림창·전화) 유지
    expect(link.requestMode(DriveMode.follow), isTrue);
    fake.controller.add(_telemetry(mode: 'follow'));
    await tester.pump();
    link.pauseControl(hidden: false);
    expect(link.requestedMode, DriveMode.follow);

    // 사라지면(홈·앱 전환·화면 꺼짐) 수동으로
    link.pauseControl(hidden: true);
    expect(link.requestedMode, DriveMode.manual);
    expect(link.modeDrop, ModeDrop.appHidden);
    expect(fake.sent.last.mode, DriveMode.manual);

    link.dispose();
  });

  testWidgets('좁은 화면: 시뮬레이션 배지, 통신 끊기 토글로 연결 끊김 화면 전환',
      (tester) async {
    _setSurface(tester, const Size(800, 1600));

    await tester.pumpWidget(const SmartCartApp());
    expect(find.text('연결 중'), findsOneWidget);
    expect(find.text('시뮬레이션'), findsOneWidget);
    expect(find.text('앱 안의 가짜 카트를 기다리는 중입니다'), findsOneWidget);
    expect(find.text('v$appVersion · 시뮬레이션'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('연결됨'), findsOneWidget);

    await tester.tap(find.text('통신 끊기'));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('연결 끊김'), findsWidgets);
    expect(find.text('연결되어 있을 때만 조작할 수 있습니다'), findsOneWidget);

    await tester.tap(find.text('통신 끊기'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('연결됨'), findsOneWidget);
  });

  testWidgets('넓은 화면: 배터리 저하·E-stop 표시, 모르는 코드는 원문 그대로',
      (tester) async {
    _setSurface(tester, const Size(1280, 1200));

    await tester.pumpWidget(const SmartCartApp());
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('고장 주입 · Mock 전용'), findsOneWidget);

    await tester.tap(find.text('배터리 저하'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('battery_low'), findsOneWidget);
    expect(find.text('bms_cell_imbalance'), findsOneWidget);

    await tester.tap(find.text('E-stop'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('구동 전원 차단됨'), findsWidgets);
    expect(find.textContaining('정지'), findsNothing);
  });

  testWidgets('자동 전환 후 태그가 끊기면 수동으로 돌아오고 안내가 뜬다', (tester) async {
    _setSurface(tester, const Size(1280, 1200));

    await tester.pumpWidget(const SmartCartApp());
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('수동 주행'), findsOneWidget);

    await tester.tap(find.text('자동'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('태그 추종 중'), findsOneWidget);

    await tester.tap(find.text('태그 신호 끊김'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('자동 모드 해제됨'), findsOneWidget);
    expect(find.text('수동 주행'), findsOneWidget);
    expect(find.text('자동 전환 불가 · 태그 신호 없음'), findsOneWidget);
  });

  testWidgets('앱 수명주기: 알림창에는 자동 유지, 홈으로 나가면 자동 해제', (tester) async {
    _setSurface(tester, const Size(1280, 1200));

    await tester.pumpWidget(const SmartCartApp());
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('자동'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('태그 추종 중'), findsOneWidget);

    // 알림창을 내렸다 올림: 자동 유지
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('태그 추종 중'), findsOneWidget);

    // 홈으로 나갔다가 돌아옴: 자동 해제, 저절로 재개하지 않음
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('자동 모드 해제됨'), findsOneWidget);
    expect(
      find.text('앱이 화면에서 사라져 수동으로 돌아갔습니다. 돌아와도 자동은 재개하지 않습니다'),
      findsOneWidget,
    );
    expect(find.text('수동 주행'), findsOneWidget);
  });

  testWidgets('실차 환경: 주의색 배지와 연결 주소가 보이고 고장 주입 패널은 없다',
      (tester) async {
    _setSurface(tester, const Size(1280, 1200));
    final link = CartLink(_FakeTransport());

    await tester.pumpWidget(MaterialApp(
      theme: buildCartTheme(),
      home: DriveScreen(
        link: link,
        env: CartEnv.vehicle,
        target: Uri.parse('ws://192.168.4.1:8765'),
      ),
    ));
    expect(find.text('실차'), findsOneWidget);
    expect(find.text('시뮬레이션'), findsNothing);
    // 연결 중 안내 + 하단 빌드 정보
    expect(find.textContaining('ws://192.168.4.1:8765'), findsNWidgets(2));
    expect(find.text('v$appVersion · 실차 · ws://192.168.4.1:8765'), findsOneWidget);
    expect(find.text('고장 주입 · Mock 전용'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    link.dispose();
  });

  testWidgets('설정이 잘못된 빌드는 연결하지 않고 오류 화면만 보여준다', (tester) async {
    await tester.pumpWidget(SmartCartApp(config: EnvConfig.parse('vehicle', '')));
    expect(find.text('빌드 설정 오류'), findsOneWidget);
    expect(find.text('수동 주행'), findsNothing);
  });

  // 레이아웃이 넘치면 Flutter가 예외를 던지므로, 화면을 띄우는 것만으로 검사가 된다.
  testWidgets('휴대폰 세로(390×844): 수동·자동 화면이 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const SmartCartApp());
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('수동 주행'), findsOneWidget);

    await tester.tap(find.text('자동'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('태그 추종 중'), findsOneWidget);
  });

  testWidgets('휴대폰 가로(844×390): 수동·자동 화면이 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(2532, 1170);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const SmartCartApp());
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('수동 주행'), findsOneWidget);

    await tester.tap(find.text('자동'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('태그 추종 중'), findsOneWidget);
  });
}
