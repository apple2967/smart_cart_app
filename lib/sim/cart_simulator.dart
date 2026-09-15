import 'dart:math' as math;

import '../models/telemetry.dart';

/// 가짜 카트 한 대. Flutter에 의존하지 않아서 앱(MockTransport)과
/// PC 테스트 서버(tool/cart_server.dart)가 함께 쓴다.
///
/// 일부러 지저분하게 만든다: 라이다 측정 실패(0) 4%, UWB 방향 흔들림,
/// 전류·RTT 노이즈, 부하에 따른 전압 처짐. 깨끗한 가짜로 만든 UI는 실물에서 무너진다.
///
/// 카트 펌웨어가 해야 할 안전 동작도 흉내 낸다:
/// - 명령이 200ms 끊기면 출력 0, 모드 manual
/// - follow는 태그 정상 + E-stop 아님일 때만 받아들이고, 태그가 끊기면 manual로 돌아감
/// - E-stop이면 출력 즉시 0
class CartSimulator {
  CartSimulator({math.Random? random}) : _rng = random ?? math.Random();

  /// [step] 한 번이 흉내 내는 시간. 텔레메트리도 이 주기로 만든다 (10Hz).
  static const tickPeriod = Duration(milliseconds: 100);

  // 고장 주입
  bool tagLost = false;
  bool lowBattery = false;
  bool estop = false;

  // 가상 복도 (m). x = 오른쪽, y = 시작 방향 기준 전방
  static const _halfWidth = 1.6;
  static const _front = 6.0;
  static const _back = 2.5;
  static const _personRadius = 0.22;

  /// duty 100%일 때 속도 (m/s). 실물 값은 모름 — 시뮬레이션용 가정.
  static const _maxSpeed = 1.2;

  final math.Random _rng;

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

  DriveMode get mode => _mode;
  double get dutyL => _dutyL;
  double get dutyR => _dutyR;

  /// 앱에서 명령 한 건이 도착함.
  void receive(DriveCommand command) {
    _lastCommand = command;
    _ticksSinceCommand = 0;
  }

  /// [tickPeriod]만큼 시간을 진행한다.
  void step() {
    _t += tickPeriod.inMilliseconds;
    _ticksSinceCommand++;

    final cmd = _lastCommand;
    final commandFresh = _ticksSinceCommand < 2; // 200ms

    _mode = cmd != null &&
            commandFresh &&
            cmd.mode == DriveMode.follow &&
            !tagLost &&
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

  /// 지금 상태의 텔레메트리 JSON. 호출할 때마다 라이다 seq가 하나 오른다.
  Map<String, dynamic> telemetryJson() {
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
