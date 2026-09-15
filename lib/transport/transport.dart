import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/telemetry.dart';
import '../sim/cart_simulator.dart';

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

  /// 앱이 화면에서 사라짐 (홈 버튼, 앱 전환, 화면 꺼짐).
  appHidden,
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

  /// 앱이 화면에서 가려질 때 호출.
  ///
  /// 가려지기만 한 경우(알림창, 전화 화면이 위에 뜸): 조이스틱만 해제하고 자동 추종은 유지한다.
  /// 아예 사라진 경우([hidden]: 홈, 앱 전환, 화면 꺼짐): 사람이 카트를 보고 있다고 볼 수
  /// 없으므로 자동도 내린다. 돌아와도 자동은 스스로 재개하지 않는다.
  void pauseControl({required bool hidden}) {
    final wasHeld = _deadman;
    _clearStick();
    // 시스템이 손가락 떼기를 전달하지 않았을 수 있다. 돌아와서 스틱이 밀린 채면 한 번 떼야 한다.
    if (wasHeld) _needsRelift = true;
    if (hidden && _requestedMode == DriveMode.follow) {
      _dropToManual(ModeDrop.appHidden);
    } else {
      _sendCommand();
    }
    notifyListeners();
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

/// 앱 안의 가짜 카트. 실제 동작은 [CartSimulator]가 하고, 여기서는 10Hz로 돌리면서
/// 고장 주입 스위치를 반영하고 텔레메트리를 앱에 넘긴다.
///
/// PC 테스트 서버(tool/cart_server.dart)도 같은 [CartSimulator]를 쓴다.
class MockTransport implements CartTransport {
  MockTransport({math.Random? random})
      : _sim = CartSimulator(random: random) {
    _timer = Timer.periodic(CartSimulator.tickPeriod, (_) => _tick());
  }

  final faults = FaultInjection();

  final CartSimulator _sim;
  final _controller = StreamController<Telemetry>.broadcast();
  late final Timer _timer;

  @override
  Stream<Telemetry> get telemetry => _controller.stream;

  @override
  void send(DriveCommand command) {
    if (faults.dropLink.value) return;
    _sim.receive(command);
  }

  @override
  Future<void> close() async {
    _timer.cancel();
    faults.dispose();
    await _controller.close();
  }

  void _tick() {
    _sim
      ..tagLost = faults.tagLost.value
      ..lowBattery = faults.lowBattery.value
      ..estop = faults.estop.value
      ..step();
    // 통신 끊김: 카트는 돌지만 앱에는 아무것도 도착하지 않는다
    if (faults.dropLink.value) return;
    // 실물과 같은 경로를 타도록 JSON 문자열을 거쳐 파싱한다
    final wire = jsonEncode(_sim.telemetryJson());
    _controller.add(Telemetry.fromJson(jsonDecode(wire) as Map<String, dynamic>));
  }
}
