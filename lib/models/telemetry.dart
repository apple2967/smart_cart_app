/// 카트 <-> 앱 통신 JSON 스키마.
///
/// 파싱은 관대하게 한다: 섹션이나 필드가 빠지면 null, 모르는 필드는 무시.
/// 실물 펌웨어가 필드 하나 빼먹었다고 화면 전체가 죽으면 안 된다.
library;

/// 카트 -> 앱 텔레메트리 (10Hz).
class Telemetry {
  const Telemetry({
    required this.t,
    this.link,
    this.power,
    this.drive,
    this.pose,
    this.lidar,
    this.tof,
    this.uwb,
    this.faults = const [],
  });

  factory Telemetry.fromJson(Map<String, dynamic> j) => Telemetry(
        t: _int(j['t']) ?? 0,
        link: _section(j['link'], LinkInfo.fromJson),
        power: _section(j['power'], PowerInfo.fromJson),
        drive: _section(j['drive'], DriveInfo.fromJson),
        pose: _section(j['pose'], PoseInfo.fromJson),
        lidar: _section(j['lidar'], LidarScan.fromJson),
        tof: _section(j['tof'], TofInfo.fromJson),
        uwb: _section(j['uwb'], UwbInfo.fromJson),
        faults: [
          if (j['faults'] case final List<dynamic> list)
            for (final f in list) '$f',
        ],
      );

  final int t;
  final LinkInfo? link;
  final PowerInfo? power;
  final DriveInfo? drive;
  final PoseInfo? pose;
  final LidarScan? lidar;
  final TofInfo? tof;
  final UwbInfo? uwb;

  /// 고장 코드. 앱이 모르는 코드도 그대로 화면에 표시한다.
  final List<String> faults;
}

class LinkInfo {
  const LinkInfo({required this.state, this.rttMs});

  factory LinkInfo.fromJson(Map<String, dynamic> j) =>
      LinkInfo(state: _str(j['state']) ?? 'unknown', rttMs: _int(j['rtt_ms']));

  final String state;
  final int? rttMs;
}

class PowerInfo {
  const PowerInfo({this.batteryPct, this.batteryV, this.contactor, this.estop});

  factory PowerInfo.fromJson(Map<String, dynamic> j) => PowerInfo(
        batteryPct: _int(j['battery_pct']),
        batteryV: _dbl(j['battery_v']),
        contactor: _str(j['contactor']),
        estop: _bool(j['estop']),
      );

  final int? batteryPct;

  /// 배터리 전압 (V). 선택 필드.
  /// 부하가 걸리면 전압이 처지므로, %가 튈 때 원인을 확인하는 용도.
  final double? batteryV;

  /// "closed" = 구동 전원 연결, "open" = 구동 전원 차단.
  /// 차단은 제동이 아니다. 모터 전기만 끊긴 것이라 경사에서는 굴러갈 수 있다.
  final String? contactor;

  final bool? estop;

  bool get driveCutOff => contactor == 'open';
}

/// 주행 모드. JSON에서는 [wire] 문자열로 오간다.
enum DriveMode {
  /// 조이스틱 수동 조작.
  manual('manual'),

  /// 자동: UWB 태그(사람)를 따라감.
  follow('follow');

  const DriveMode(this.wire);

  final String wire;

  /// 모르는 문자열이면 null.
  static DriveMode? fromWire(String? wire) => switch (wire) {
        'manual' => DriveMode.manual,
        'follow' => DriveMode.follow,
        _ => null,
      };
}

class DriveInfo {
  const DriveInfo({
    this.mode,
    this.dutyL,
    this.dutyR,
    this.currentL,
    this.currentR,
    this.speedMps,
  });

  factory DriveInfo.fromJson(Map<String, dynamic> j) => DriveInfo(
        mode: _str(j['mode']),
        dutyL: _dbl(j['duty_l']),
        dutyR: _dbl(j['duty_r']),
        currentL: _dbl(j['current_l']),
        currentR: _dbl(j['current_r']),
        speedMps: _dbl(j['speed_mps']),
      );

  /// 카트가 실제로 적용 중인 모드 ("manual" | "follow").
  /// 문자열로 두는 이유: 펌웨어에 새 모드가 생겨도 원문 그대로 표시하려고.
  final String? mode;

  /// 모터 출력 duty (%, -100~100). 속도가 아니다.
  /// 같은 duty라도 경사·적재량에 따라 실제 속도는 달라진다.
  final double? dutyL;
  final double? dutyR;

  /// 모터 전류 (A).
  final double? currentL;
  final double? currentR;

  /// 실측 속도 (m/s). 엔코더 장착 전에는 항상 null. 들어와도 duty는 유지한다.
  final double? speedMps;
}

/// 자세 (°).
class PoseInfo {
  const PoseInfo({this.roll, this.pitch, this.yaw});

  factory PoseInfo.fromJson(Map<String, dynamic> j) => PoseInfo(
        roll: _dbl(j['roll']),
        pitch: _dbl(j['pitch']),
        yaw: _dbl(j['yaw']),
      );

  final double? roll;
  final double? pitch;
  final double? yaw;
}

/// 라이다 1회전. 각도-거리 객체 배열 대신 시작각 + 간격 + 거리 배열로 받는다.
class LidarScan {
  const LidarScan({
    required this.seq,
    required this.startDeg,
    required this.stepDeg,
    required this.rangesMm,
  });

  factory LidarScan.fromJson(Map<String, dynamic> j) => LidarScan(
        seq: _int(j['seq']) ?? 0,
        startDeg: _dbl(j['start_deg']) ?? 0,
        stepDeg: _dbl(j['step_deg']) ?? 1,
        rangesMm: [
          if (j['ranges_mm'] case final List<dynamic> list)
            for (final r in list) _int(r) ?? 0,
        ],
      );

  final int seq;

  /// 0° = 전방, 시계방향으로 증가 (RPLIDAR 기준).
  final double startDeg;
  final double stepDeg;

  /// 거리 (mm). 0은 "측정 실패"지 거리 0이 아니다.
  final List<int> rangesMm;

  double angleDegAt(int index) => startDeg + stepDeg * index;

  int get validCount => rangesMm.where((r) => r > 0).length;
}

/// 측면 ToF 근접 센서.
class TofInfo {
  const TofInfo({this.leftMm, this.rightMm, this.cliff});

  factory TofInfo.fromJson(Map<String, dynamic> j) => TofInfo(
        leftMm: _int(j['left_mm']),
        rightMm: _int(j['right_mm']),
        cliff: _bool(j['cliff']),
      );

  final int? leftMm;
  final int? rightMm;
  final bool? cliff;
}

/// UWB 태그 = 카트가 따라갈 사람의 위치.
class UwbInfo {
  const UwbInfo({this.tag, this.distM, this.bearingDeg});

  factory UwbInfo.fromJson(Map<String, dynamic> j) => UwbInfo(
        tag: _str(j['tag']),
        distM: _dbl(j['dist_m']),
        bearingDeg: _dbl(j['bearing_deg']),
      );

  /// "ok"일 때만 거리·방향이 유효하다.
  final String? tag;
  final double? distM;

  /// 전방 기준, 음수 = 왼쪽.
  final double? bearingDeg;
}

/// 앱 -> 카트 조작 명령 (20Hz).
///
/// 모드도 매 명령에 싣는다. 모드 전환을 한 번만 보내면 그 패킷이 빠졌을 때
/// 앱과 카트의 모드가 엇갈린 채로 남는다.
///
/// follow 모드에서 카트는 throttle/steer/deadman을 무시하지만,
/// 명령이 200ms 끊기면 수동과 똑같이 출력을 끄고 manual로 돌아가야 한다.
class DriveCommand {
  const DriveCommand({
    required this.seq,
    required this.mode,
    required this.throttle,
    required this.steer,
    required this.deadman,
  });

  /// 카트(또는 테스트 서버) 쪽에서 명령을 읽을 때.
  ///
  /// 이상한 값은 가장 안전한 쪽으로 읽는다: 모르는 모드는 manual, 범위를 벗어난
  /// throttle/steer는 0(최대치로 자르지 않음 — 깨진 값을 최대 출력으로 실행하면 안 된다),
  /// deadman은 true가 확실할 때만 true.
  factory DriveCommand.fromJson(Map<String, dynamic> j) => DriveCommand(
        seq: _int(j['seq']) ?? 0,
        mode: DriveMode.fromWire(_str(j['mode'])) ?? DriveMode.manual,
        throttle: _unitOrZero(j['throttle']),
        steer: _unitOrZero(j['steer']),
        deadman: _bool(j['deadman']) ?? false,
      );

  final int seq;
  final DriveMode mode;

  /// -1.0 (후진) ~ 1.0 (전진)
  final double throttle;

  /// -1.0 (좌) ~ 1.0 (우)
  final double steer;

  /// 조이스틱에 손이 닿아 있을 때만 true.
  final bool deadman;

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'mode': mode.wire,
        'throttle': _round2(throttle),
        'steer': _round2(steer),
        'deadman': deadman,
      };
}

T? _section<T>(Object? v, T Function(Map<String, dynamic>) parse) =>
    v is Map<String, dynamic> ? parse(v) : null;

int? _int(Object? v) => v is num ? v.toInt() : null;
double? _dbl(Object? v) => v is num ? v.toDouble() : null;
bool? _bool(Object? v) => v is bool ? v : null;
String? _str(Object? v) => v is String ? v : null;

double _unitOrZero(Object? v) {
  final d = _dbl(v);
  return d != null && d.isFinite && d.abs() <= 1 ? d : 0.0;
}

double _round2(double v) => (v * 100).roundToDouble() / 100;
