import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/telemetry.dart';

/// 카트와 주고받는 방법(WebSocket, BLE, Mock …)을 감춘다.
/// 화면은 이 인터페이스와 [CartLink]만 알고, 구체 구현은 main.dart에서 끼운다.
abstract interface class CartTransport {
  /// 수신 텔레메트리. 링크가 끊겨도 스트림을 닫지 않는다.
  Stream<Telemetry> get telemetry;

  /// 명령 한 건 전송. 실패해도 던지지 않는다 — 50ms 뒤 다음 명령이 간다.
  void send(DriveCommand command);

  Future<void> close();
}

enum LinkStatus {
  /// 텔레메트리를 아직 한 번도 못 받음.
  connecting,
  live,

  /// 텔레메트리가 [CartLink.telemetryTimeout] 넘게 안 옴.
  lost,
}

/// 자동 모드를 요청할 수 없는 이유.
enum FollowBlock {
  notLive,

  /// 조이스틱을 누르고 있음. 수동 조작 중에 자동으로 넘어가지 않는다.
  stickHeld,
  driveCutOff,
  tagNotOk,
}

/// 사용자가 누르지 않았는데 자동이 풀린 이유.
enum ModeDrop {
  /// 요청했지만 카트가 약 1초 안에 follow로 바뀌지 않음.
  rejected,

  /// 추종 중 카트가 스스로 manual로 돌아감 (태그 끊김 등).
  droppedByCart,

  /// 텔레메트리 끊김.
  linkLost,
}

/// 전송 방식과 무관한 링크 관리: 20Hz 명령 송신, 텔레메트리 워치독, 모드 전환.
///
/// 끊김은 소켓 상태가 아니라 수신 간격으로 판정한다.
/// Wi-Fi가 흔들리면 소켓은 열린 채 데이터만 안 오는 경우가 흔하다.
///
/// 모드는 앱이 요청하고 카트가 텔레메트리 drive.mode로 확정한다.
/// 자동이 한 번 풀리면 조건이 돌아와도 스스로 재개하지 않는다 — 사람이 다시 눌러야 한다.
class CartLink extends ChangeNotifier {
  CartLink(this._transport) {
    _sub = _transport.telemetry.listen(_onTelemetry);
    _commandTimer = Timer.periodic(commandPeriod, (_) => _sendCommand());
    _watchdog = Timer.periodic(_watchdogPeriod, (_) => _checkTelemetryAge());
  }

  static const commandPeriod = Duration(milliseconds: 50);
  static const telemetryTimeout = Duration(milliseconds: 500);
  static const _watchdogPeriod = Duration(milliseconds: 100);

  /// 자동 요청 후 텔레메트리 이만큼(약 1초) 안에 카트가 follow로 안 바뀌면 거부로 본다.
  static const _followConfirmTelemetry = 10;

  final CartTransport _transport;
  late final StreamSubscription<Telemetry> _sub;
  late final Timer _commandTimer;
  late final Timer _watchdog;

  Telemetry? _latest;
  LinkStatus _status = LinkStatus.connecting;
  int _ticksSinceTelemetry = 0;
  int _seq = 0;
  double _throttle = 0;
  double _steer = 0;
  bool _deadman = false;
  bool _needsRelift = false;

  DriveMode _requestedMode = DriveMode.manual;
  bool _followConfirmed = false;
  int _followPendingTelemetry = 0;
  ModeDrop? _modeDrop;

  /// 마지막으로 받은 텔레메트리. 끊긴 동안에도 남아 있다.
  Telemetry? get latest => _latest;
  LinkStatus get status => _status;
  double get throttle => _throttle;
  double get steer => _steer;

  /// 마지막 텔레메트리 이후 경과 시간 (100ms 단위).
  Duration get telemetryAge => _watchdogPeriod * _ticksSinceTelemetry;

  /// 앱이 카트에 요청 중인 모드. 실제 모드는 `latest.drive.mode`.
  DriveMode get requestedMode => _requestedMode;

  /// 자동을 요청했지만 카트가 아직 follow로 보고하지 않음.
  bool get followPending =>
      _requestedMode == DriveMode.follow && !_followConfirmed;

  /// 마지막으로 자동이 풀린 이유. 다음 모드 요청 때 지워진다.
  ModeDrop? get modeDrop => _modeDrop;

  /// 지금 자동을 요청할 수 없는 이유. null이면 가능.
  /// 카트도 같은 조건을 직접 확인해야 한다 — 이 검사는 화면 안내용이다.
  FollowBlock? get followBlock {
    if (_status != LinkStatus.live) return FollowBlock.notLive;
    if (_deadman) return FollowBlock.stickHeld;
    if (_latest?.power?.driveCutOff == true) return FollowBlock.driveCutOff;
    if (_latest?.uwb?.tag != 'ok') return FollowBlock.tagNotOk;
    return null;
  }

  /// 모드 전환 요청. 자동 요청이 [followBlock]에 막히면 false.
  bool requestMode(DriveMode mode) {
    _modeDrop = null;
    if (mode == _requestedMode) {
      notifyListeners();
      return true;
    }
    if (mode == DriveMode.follow) {
      if (followBlock != null) {
        notifyListeners();
        return false;
      }
      _followConfirmed = false;
      _followPendingTelemetry = 0;
    }
    _requestedMode = mode;
    _sendCommand();
    notifyListeners();
    return true;
  }

  /// 조이스틱을 누르고 있는 동안 호출.
  void hold(double throttle, double steer) {
    // 끊겼다 복구되는 순간 스틱이 밀려 있으면 카트가 튀어나간다.
    // 링크가 살아 있지 않을 때 누른 입력은 손을 한 번 뗄 때까지 무시한다.
    if (_status != LinkStatus.live) {
      _needsRelift = true;
      return;
    }
    if (_needsRelift || _requestedMode != DriveMode.manual) return;
    _throttle = throttle.clamp(-1.0, 1.0);
    _steer = steer.clamp(-1.0, 1.0);
    _deadman = true;
  }

  /// 손을 뗌. 다음 주기를 기다리지 않고 즉시 deadman:false를 보낸다.
  void release() {
    _needsRelift = false;
    _clearStick();
    _sendCommand();
  }

  void _clearStick() {
    _throttle = 0;
    _steer = 0;
    _deadman = false;
  }

  void _onTelemetry(Telemetry t) {
    _latest = t;
    _ticksSinceTelemetry = 0;
    _status = LinkStatus.live;
    if (_requestedMode == DriveMode.follow) _trackFollow(t);
    notifyListeners();
  }

  void _trackFollow(Telemetry t) {
    if (t.drive?.mode == DriveMode.follow.wire) {
      _followConfirmed = true;
    } else if (_followConfirmed) {
      _dropToManual(ModeDrop.droppedByCart);
    } else if (++_followPendingTelemetry > _followConfirmTelemetry) {
      _dropToManual(ModeDrop.rejected);
    }
  }

  void _dropToManual(ModeDrop reason) {
    _requestedMode = DriveMode.manual;
    _followConfirmed = false;
    _modeDrop = reason;
    _sendCommand();
  }

  void _checkTelemetryAge() {
    if (_status == LinkStatus.connecting) return;
    _ticksSinceTelemetry++;
    if (telemetryAge < telemetryTimeout) return;
    if (_status == LinkStatus.live) {
      _status = LinkStatus.lost;
      if (_deadman) _needsRelift = true;
      _clearStick();
      if (_requestedMode == DriveMode.follow) {
        _dropToManual(ModeDrop.linkLost);
      } else {
        _sendCommand();
      }
    }
    // 끊긴 동안에는 경과 시간 표시를 위해 계속 갱신
    notifyListeners();
  }

  void _sendCommand() {
    _transport.send(DriveCommand(
      seq: _seq++,
      mode: _requestedMode,
      throttle: _throttle,
      steer: _steer,
      deadman: _deadman,
    ));
  }

  @override
  void dispose() {
    _commandTimer.cancel();
    _watchdog.cancel();
    _requestedMode = DriveMode.manual;
    _clearStick();
    _sendCommand();
    _sub.cancel();
    unawaited(_transport.close());
    super.dispose();
  }
}

/// Mock 전용 고장 주입 스위치.
class FaultInjection {
  final dropLink = ValueNotifier(false);
  final lowBattery = ValueNotifier(false);
  final estop = ValueNotifier(false);
  final tagLost = ValueNotifier(false);

  void dispose() {
    dropLink.dispose();
    lowBattery.dispose();
    estop.dispose();
    tagLost.dispose();
  }
}

/// 실물 없이 UI를 만들기 위한 가짜 카트.
///
/// 일부러 지저분하게 만든다: 라이다 측정 실패(0) 4%, UWB 방향 흔들림,
/// 전류·RTT 노이즈, 부하에 따른 전압 처짐. 깨끗한 mock으로 만든 UI는 실물에서 무너진다.
///
/// 카트 쪽 안전 동작도 흉내 낸다:
/// - 명령이 200ms 끊기면 출력 0, 모드 manual
/// - follow는 태그 정상 + E-stop 아님일 때만 받아들이고, 태그가 끊기면 manual로 돌아감
class MockTransport implements CartTransport {
  MockTransport({math.Random? random}) : _rng = random ?? math.Random() {
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  final faults = FaultInjection();

  final math.Random _rng;
  final _controller = StreamController<Telemetry>.broadcast();
  late final Timer _timer;

  // 가상 복도 (m). x = 오른쪽, y = 시작 방향 기준 전방
  static const _halfWidth = 1.6;
  static const _front = 6.0;
  static const _back = 2.5;
  static const _personRadius = 0.22;

  /// duty 100%일 때 속도 (m/s). 실물 값은 모름 — 시뮬레이션용 가정.
  static const _maxSpeed = 1.2;

  int _t = 0;
  int _lidarSeq = 8800;
  double _battery = 78;
  double _dutyL = 0;
  double _dutyR = 0;

  // 카트 위치·방향 (복도 좌표)
  double _cx = 0;
  double _cy = 0;
  double _heading = 0; // °, 시계방향

  DriveMode _mode = DriveMode.manual;
  DriveCommand? _lastCommand;
  int _ticksSinceCommand = 0;

  @override
  Stream<Telemetry> get telemetry => _controller.stream;

  @override
  void send(DriveCommand command) {
    if (faults.dropLink.value) return;
    _lastCommand = command;
    _ticksSinceCommand = 0;
  }

  @override
  Future<void> close() async {
    _timer.cancel();
    faults.dispose();
    await _controller.close();
  }

  void _tick() {
    _t += 100;
    _ticksSinceCommand++;
    _stepDrive();
    // 통신 끊김: 카트는 돌지만 앱에는 아무것도 도착하지 않는다
    if (faults.dropLink.value) return;
    // 실물과 같은 경로를 타도록 JSON 문자열을 거쳐 파싱한다
    final wire = jsonEncode(_buildJson());
    _controller.add(Telemetry.fromJson(jsonDecode(wire) as Map<String, dynamic>));
  }

  void _stepDrive() {
    final cmd = _lastCommand;
    final commandFresh = _ticksSinceCommand < 2; // 200ms
    final estop = faults.estop.value;

    _mode = cmd != null &&
            commandFresh &&
            cmd.mode == DriveMode.follow &&
            !faults.tagLost.value &&
            !estop
        ? DriveMode.follow
        : DriveMode.manual;

    var throttle = 0.0;
    var steer = 0.0;
    if (cmd != null && commandFresh && !estop) {
      if (_mode == DriveMode.follow) {
        (throttle, steer) = _followControl();
      } else if (cmd.deadman) {
        throttle = cmd.throttle;
        steer = cmd.steer;
      }
    }

    if (estop) {
      // 접촉기가 열리면 출력은 즉시 0 (램프 없음)
      _dutyL = 0;
      _dutyR = 0;
    } else {
      // 모터 드라이버 램프: 틱당 최대 15%p
      _dutyL = _approach(_dutyL, (throttle + steer).clamp(-1.0, 1.0) * 100, 15);
      _dutyR = _approach(_dutyR, (throttle - steer).clamp(-1.0, 1.0) * 100, 15);
    }

    _heading = (_heading + (_dutyL - _dutyR) * 0.04) % 360;
    final v = (_dutyL + _dutyR) / 200 * _maxSpeed;
    final h = _heading * math.pi / 180;
    _cx = (_cx + v * 0.1 * math.sin(h))
        .clamp(-_halfWidth + 0.4, _halfWidth - 0.4);
    _cy = (_cy + v * 0.1 * math.cos(h)).clamp(-_back + 0.5, _front - 0.5);

    _battery = math.max(
      0.0,
      _battery - 0.0005 - (_dutyL.abs() + _dutyR.abs()) * 0.00002,
    );
  }

  /// 펌웨어가 할 법한 단순 추종: 태그 쪽으로 돌고, 1.2 m보다 멀면 전진.
  /// 실물 펌웨어는 흔들리는 UWB 값을 걸러서 써야 한다. 여기선 참값을 쓴다.
  (double, double) _followControl() {
    final (dist, bearing) = _tagRelative();
    final steer = (bearing / 45).clamp(-0.6, 0.6);
    final aligned = (1 - bearing.abs() / 60).clamp(0.0, 1.0);
    final throttle = ((dist - 1.2) * 0.6).clamp(0.0, 0.5) * aligned;
    return (throttle, steer);
  }

  /// 태그를 든 사람: 복도를 천천히 오가며 좌우로 흔들린다.
  (double, double) _personWorld() {
    final s = _t / 1000;
    return (
      0.6 * math.sin(s * 2 * math.pi / 17),
      2.6 + 2.0 * math.sin(s * 2 * math.pi / 40),
    );
  }

  /// 카트 기준 태그 (거리 m, 방향 °). 노이즈 없는 참값.
  (double, double) _tagRelative() {
    final (px, py) = _personWorld();
    final rx = px - _cx;
    final ry = py - _cy;
    final bearing = math.atan2(rx, ry) * 180 / math.pi - _heading;
    return (math.sqrt(rx * rx + ry * ry), _wrap180(bearing));
  }

  Map<String, dynamic> _buildJson() {
    final lowBattery = faults.lowBattery.value;
    final estop = faults.estop.value;
    final tagLost = faults.tagLost.value;
    final batteryPct = lowBattery ? 12.0 : _battery;
    final (tagDist, tagBearing) = _tagRelative();
    // 24V 리튬 7S 가정 (21.0~29.4 V). 부하가 걸리면 전압이 처진다.
    final sag = (_dutyL.abs() + _dutyR.abs()) / 200 * 1.2;

    return {
      't': _t,
      'link': {'state': 'ok', 'rtt_ms': 14 + _rng.nextInt(18)},
      'power': {
        'battery_pct': batteryPct.round(),
        'battery_v': _round(21.0 + batteryPct / 100 * 8.4 - sag, 1),
        'contactor': estop ? 'open' : 'closed',
        'estop': estop,
      },
      'drive': {
        'mode': _mode.wire,
        'duty_l': _dutyL.round(),
        'duty_r': _dutyR.round(),
        'current_l': estop ? 0 : _current(_dutyL),
        'current_r': estop ? 0 : _current(_dutyR),
      },
      'pose': {
        'roll': _round(_jitter(0.8, 0.3), 1),
        'pitch': _round(_jitter(-2.1, 0.3), 1),
        'yaw': _round((137.4 + _heading) % 360, 1),
      },
      'lidar': {
        'seq': _lidarSeq++,
        'start_deg': 0,
        'step_deg': 1,
        'ranges_mm': _scan(),
      },
      'tof': {
        'left_mm': 60 + _rng.nextInt(6),
        'right_mm': 62 + _rng.nextInt(6),
        'cliff': false,
      },
      'uwb': tagLost
          ? {'tag': 'lost'}
          : {
              'tag': 'ok',
              // 실물 UWB처럼 흔들리게: 거리 ±5 cm, 방향 ±6°
              'dist_m': _round(tagDist + _jitter(0, 0.05), 2),
              'bearing_deg': _round(_wrap180(tagBearing + _jitter(0, 6)), 1),
            },
      'faults': [
        // 두 번째 코드는 앱이 모르는 코드 — 원문 그대로 표시되는지 확인용
        if (lowBattery) ...['battery_low', 'bms_cell_imbalance'],
        if (estop) 'estop_pressed',
        if (tagLost) 'uwb_tag_lost',
      ],
    };
  }

  /// 카트 위치·방향에서 360° 광선을 쏴서 복도 벽과 사람까지의 거리를 구한다.
  List<int> _scan() {
    final (px, py) = _personWorld();
    final rx = px - _cx;
    final ry = py - _cy;

    return List.generate(360, (i) {
      // 실물 RPLIDAR도 반사가 약한 면에서 흔히 0을 낸다
      if (_rng.nextDouble() < 0.04) return 0;

      // 카트 기준 각 -> 복도 기준 각
      final w = (i + _heading) * math.pi / 180;
      final dx = math.sin(w);
      final dy = math.cos(w);

      var d = math.min(
        dx > 0
            ? (_halfWidth - _cx) / dx
            : (dx < 0 ? (-_halfWidth - _cx) / dx : double.infinity),
        dy > 0
            ? (_front - _cy) / dy
            : (dy < 0 ? (-_back - _cy) / dy : double.infinity),
      );

      // 사람(원)과의 교차
      final b = dx * rx + dy * ry;
      final disc = b * b - (rx * rx + ry * ry - _personRadius * _personRadius);
      if (disc >= 0) {
        final hit = b - math.sqrt(disc);
        if (hit > 0 && hit < d) d = hit;
      }

      final mm = (d * 1000 + _jitter(0, 12)).round();
      return mm > 12000 ? 0 : mm; // C1 최대 측정거리 12 m
    });
  }

  double _current(double duty) =>
      _round(0.3 + duty.abs() * 0.11 + _rng.nextDouble() * 0.4, 1);

  double _jitter(double center, double amplitude) =>
      center + (_rng.nextDouble() * 2 - 1) * amplitude;
}

double _approach(double from, double to, double maxStep) =>
    from + (to - from).clamp(-maxStep, maxStep);

double _wrap180(double deg) => (deg + 180) % 360 - 180;

double _round(double v, int digits) {
  final f = math.pow(10, digits);
  return (v * f).round() / f;
}
