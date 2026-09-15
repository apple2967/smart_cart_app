/// PC에서 돌리는 가짜 카트 WebSocket 서버.
///
/// 앱의 테스트 서버 빌드(CART_ENV=server)가 여기에 붙는다. 실제 Wi-Fi 위에서 앱을 확인하고,
/// 지연·손실·음영(끊겼다가 한꺼번에 몰려옴)을 일부러 넣어 볼 수 있다.
/// 카트 쪽(Orange Pi) 서버를 만들 때 통신 규약의 참고 구현으로도 쓴다.
///
/// ```
/// dart run tool/cart_server.dart [--port 8765]
/// ```
///
/// 조작은 이 창에 명령을 입력하거나, 서버를 실행한 PC의 브라우저에서 http://localhost:8765/ 를 연다.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:smart_cart_app/env.dart' show appVersion;
import 'package:smart_cart_app/models/telemetry.dart';
import 'package:smart_cart_app/sim/cart_simulator.dart';

Future<void> main(List<String> args) async {
  final portIndex = args.indexOf('--port');
  final port = portIndex >= 0 && portIndex + 1 < args.length
      ? int.tryParse(args[portIndex + 1])
      : null;

  final server = CartServer(log: stdout.writeln);
  final bound = await server.start(port: port ?? 8765);

  stdout
    ..writeln('스마트카트 테스트 서버 v$appVersion — 포트 $bound')
    ..writeln('휴대폰과 이 PC가 같은 Wi-Fi에 있어야 합니다. 앱 빌드에 쓸 수 있는 주소:');
  for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final address in nic.addresses) {
      stdout.writeln('  ws://${address.address}:$bound   (${nic.name})');
    }
  }
  stdout
    ..writeln('예) flutter run --dart-define=CART_ENV=server '
        '--dart-define=CART_URL=ws://<위 주소>:$bound')
    ..writeln('Windows 방화벽 창이 뜨면 "개인 네트워크"를 허용해야 휴대폰이 붙을 수 있습니다.')
    ..writeln('조작: 이 창에 help 입력, 또는 이 PC의 브라우저에서 http://localhost:$bound/')
    ..writeln();

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final words = line.trim().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.isEmpty) return;
    if (words.first == 'quit' || words.first == 'exit') {
      unawaited(server.close().then((_) => exit(0)));
      return;
    }
    stdout.writeln(server.control(words.first, parseArgs(words.skip(1))));
  });

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close();
    exit(0);
  });
}

/// "delay=80 loss=5" → {delay: 80, loss: 5}.
/// '=' 없는 첫 단어는 'value'로 받는다 ("preset bad", "hold 1500").
Map<String, String> parseArgs(Iterable<String> words) {
  final args = <String, String>{};
  for (final word in words) {
    final i = word.indexOf('=');
    if (i > 0) {
      args[word.substring(0, i)] = word.substring(i + 1);
    } else {
      args.putIfAbsent('value', () => word);
    }
  }
  return args;
}

/// 흉내 낼 네트워크 상태.
class NetConditions {
  const NetConditions({
    this.delayMs = 0,
    this.jitterMs = 0,
    this.lossPercent = 0,
  });

  final int delayMs;
  final int jitterMs;
  final double lossPercent;

  static const presets = {
    'good': NetConditions(),
    'weak': NetConditions(delayMs: 40, jitterMs: 60, lossPercent: 2),
    'bad': NetConditions(delayMs: 120, jitterMs: 250, lossPercent: 8),
  };

  @override
  String toString() =>
      '지연 ${delayMs}ms · 흔들림 +0~${jitterMs}ms · 손실 $lossPercent%';
}

/// 한 방향(서버→앱 또는 앱→서버)의 네트워크 흉내.
///
/// WebSocket은 TCP 위라서 메시지가 사라지거나 순서가 바뀌지 않는다. Wi-Fi에서 패킷이 빠지면
/// TCP가 재전송을 기다리는 동안 뒤 메시지들이 줄줄이 막혔다가 한꺼번에 도착한다.
/// 그래서 손실은 버리는 게 아니라 "멈춤 → 몰림"으로 흉내 내고, 순서는 항상 지킨다.
class LinkShaper {
  LinkShaper(this._deliver, {math.Random? random})
      : _rng = random ?? math.Random();

  /// [queuedMs]: 보낸 뒤 실제로 도착하기까지 걸린 시간.
  final void Function(String message, int queuedMs) _deliver;
  final math.Random _rng;

  NetConditions conditions = const NetConditions();

  final _clock = Stopwatch()..start();
  final _queue = Queue<({String message, int pushedAt, int due})>();
  Timer? _timer;
  int _lastDue = 0;
  int _holdUntil = 0;

  /// 아직 도착하지 않은 메시지 수.
  int get queued => _queue.length;

  /// 이 시간 동안 아무것도 내보내지 않고 쌓아 뒀다가 한꺼번에 내보낸다 (Wi-Fi 음영 구간).
  void holdFor(Duration duration) {
    _holdUntil = math.max(
      _holdUntil,
      _clock.elapsedMilliseconds + duration.inMilliseconds,
    );
  }

  void push(String message) {
    final now = _clock.elapsedMilliseconds;
    final c = conditions;
    // math.max는 `+` 옆에서 num으로 추론되므로 조건식으로 int를 유지한다
    var due = now +
        (c.delayMs > 0 ? c.delayMs : 0) +
        (c.jitterMs > 0 ? _rng.nextInt(c.jitterMs + 1) : 0);
    if (c.lossPercent > 0 && _rng.nextDouble() * 100 < c.lossPercent) {
      due += 200 + _rng.nextInt(401); // TCP 재전송 대기
    }
    // TCP는 순서를 바꾸지 않는다: 앞 메시지보다 먼저 도착할 수 없다
    if (due < _holdUntil) due = _holdUntil;
    if (due < _lastDue) due = _lastDue;
    _lastDue = due;
    _queue.add((message: message, pushedAt: now, due: due));
    _drain();
  }

  void _drain() {
    _timer?.cancel();
    _timer = null;
    final now = _clock.elapsedMilliseconds;
    while (_queue.isNotEmpty && _queue.first.due <= now) {
      final item = _queue.removeFirst();
      _deliver(item.message, now - item.pushedAt);
    }
    if (_queue.isNotEmpty) {
      _timer = Timer(Duration(milliseconds: _queue.first.due - now), _drain);
    }
  }

  void close() {
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }
}

/// 가짜 카트 한 대를 WebSocket으로 내보내는 서버.
class CartServer {
  CartServer({math.Random? random, void Function(String line)? log})
      : sim = CartSimulator(random: random),
        _rng = random ?? math.Random(),
        _log = log ?? _silent;

  final CartSimulator sim;
  final math.Random _rng;
  final void Function(String line) _log;

  final _clients = <_Client>[];
  HttpServer? _http;
  Timer? _ticker;
  NetConditions _conditions = const NetConditions();

  int _lateCommands = 0;
  int _lateInWindow = 0;
  int _worstLateMs = 0;
  final _lateWindow = Stopwatch();

  int get clientCount => _clients.length;

  /// 200ms 넘게 늦게 도착한 명령 누적 수.
  int get lateCommands => _lateCommands;

  NetConditions get conditions => _conditions;

  /// 실제로 열린 포트를 돌려준다 ([port]가 0이면 빈 포트를 고른다).
  Future<int> start({int port = 8765, InternetAddress? address}) async {
    final http = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _http = http;
    http.listen(_onRequest);
    _ticker = Timer.periodic(CartSimulator.tickPeriod, (_) => _tick());
    return http.port;
  }

  Future<void> close() async {
    _ticker?.cancel();
    for (final client in [..._clients]) {
      _clients.remove(client);
      await client.close();
    }
    await _http?.close(force: true);
  }

  void _tick() {
    sim.step();
    _reportLateCommands();
    if (_clients.isEmpty) return;
    final json = jsonEncode(sim.telemetryJson());
    for (final client in _clients) {
      client.down.push(json);
    }
  }

  Future<void> _onRequest(HttpRequest request) async {
    final remote = request.connectionInfo?.remoteAddress;

    if (WebSocketTransformer.isUpgradeRequest(request)) {
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        _clients.add(_Client(socket, this));
        _log('앱 접속: ${remote?.address} (현재 ${_clients.length}대)');
      } on Object catch (e) {
        _log('앱 접속 실패: $e');
      }
      return;
    }

    final response = request.response
      ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
    // 조작은 서버를 실행한 PC에서만. 같은 Wi-Fi의 다른 기기가 가짜 카트 상태를 바꾸지 못하게.
    if (remote == null || !remote.isLoopback) {
      response
        ..statusCode = HttpStatus.forbidden
        ..write('조작은 서버를 실행한 PC에서만 할 수 있습니다.');
    } else {
      final segments = request.uri.pathSegments;
      response.write(control(
        segments.isEmpty ? 'status' : segments.first,
        request.uri.queryParameters,
      ));
    }
    await response.close();
  }

  void _onCommand(String message, int queuedMs) {
    final json = _decodeObject(message);
    if (json == null) return;
    // 늦게 도착한 명령도 카트는 그대로 적용한다. 규약에 보낸 시각이 없어서
    // 오래된 명령인지 구분할 방법이 없기 때문이다. 이 위험을 눈에 보이게 기록한다.
    if (queuedMs > 200) {
      _lateCommands++;
      _lateInWindow++;
      _worstLateMs = math.max(_worstLateMs, queuedMs);
    }
    sim.receive(DriveCommand.fromJson(json));
  }

  void _reportLateCommands() {
    if (!_lateWindow.isRunning) _lateWindow.start();
    if (_lateWindow.elapsedMilliseconds < 1000) return;
    _lateWindow.reset();
    if (_lateInWindow == 0) return;
    _log('⚠ 앱→카트 명령 $_lateInWindow건이 200ms 넘게 늦게 도착 (최대 ${_worstLateMs}ms). '
        '카트는 오래된 명령인지 구분하지 못하고 그대로 실행합니다 — 규약 보강 필요');
    _lateInWindow = 0;
    _worstLateMs = 0;
  }

  void _remove(_Client client) {
    if (!_clients.remove(client)) return;
    unawaited(client.close());
    _log('앱 연결 끊김 (현재 ${_clients.length}대)');
  }

  void _setConditions(NetConditions conditions) {
    _conditions = conditions;
    for (final client in _clients) {
      client.down.conditions = conditions;
      client.up.conditions = conditions;
    }
  }

  /// 콘솔 명령과 HTTP 조작 API가 함께 쓴다. 결과 문구를 돌려준다.
  String control(String command, Map<String, String> args) {
    switch (command) {
      case 'status':
        return status();
      case 'help':
        return _help;
      case 'net':
        final c = _conditions;
        _setConditions(NetConditions(
          delayMs: math.max(0, int.tryParse(args['delay'] ?? '') ?? c.delayMs),
          jitterMs:
              math.max(0, int.tryParse(args['jitter'] ?? '') ?? c.jitterMs),
          lossPercent: (double.tryParse(args['loss'] ?? '') ?? c.lossPercent)
              .clamp(0.0, 100.0),
        ));
        return '네트워크: $_conditions';
      case 'preset':
        final name = args['name'] ?? args['value'] ?? '';
        final preset = NetConditions.presets[name];
        if (preset == null) {
          return '프리셋은 ${NetConditions.presets.keys.join(', ')} 중 하나입니다';
        }
        _setConditions(preset);
        return '네트워크($name): $_conditions';
      case 'hold':
        final ms = int.tryParse(args['ms'] ?? args['value'] ?? '') ?? 1500;
        for (final client in _clients) {
          client.hold(Duration(milliseconds: ms));
        }
        return '${ms}ms 동안 양방향 전송을 붙잡았다가 한꺼번에 내보냅니다 (Wi-Fi 음영 흉내)';
      case 'kick':
        final count = _clients.length;
        for (final client in [..._clients]) {
          _remove(client);
        }
        return '앱 연결 $count개를 끊었습니다. 앱이 스스로 다시 붙어야 합니다';
      case 'fault':
        if (args['tag'] case final v?) sim.tagLost = v == 'off';
        if (args['estop'] case final v?) sim.estop = v == 'on';
        if (args['battery'] case final v?) sim.lowBattery = v == 'low';
        return status();
      default:
        return '모르는 명령: $command\n$_help';
    }
  }

  String status() => [
        '스마트카트 테스트 서버 v$appVersion',
        '접속한 앱: ${_clients.length}대',
        '네트워크: $_conditions',
        '가짜 카트: 모드 ${sim.mode.wire} · 출력 L ${sim.dutyL.round()}% '
            'R ${sim.dutyR.round()}% · 태그 ${sim.tagLost ? '끊김' : '정상'} · '
            'E-stop ${sim.estop ? '눌림' : '아님'} · '
            '배터리 ${sim.lowBattery ? '저하' : '정상'}',
        '200ms 넘게 늦게 도착한 명령 누적: $_lateCommands건',
      ].join('\n');
}

class _Client {
  _Client(this.socket, CartServer server)
      : down = LinkShaper(
          (message, _) {
            if (socket.readyState == WebSocket.open) socket.add(message);
          },
          random: server._rng,
        ),
        up = LinkShaper(server._onCommand, random: server._rng) {
    down.conditions = server.conditions;
    up.conditions = server.conditions;
    socket.listen(
      (data) {
        if (data is String) up.push(data);
      },
      onDone: () => server._remove(this),
      onError: (Object _) => server._remove(this),
      cancelOnError: true,
    );
  }

  final WebSocket socket;

  /// 서버 → 앱 (텔레메트리)
  final LinkShaper down;

  /// 앱 → 서버 (명령)
  final LinkShaper up;

  void hold(Duration duration) {
    down.holdFor(duration);
    up.holdFor(duration);
  }

  Future<void> close() async {
    down.close();
    up.close();
    await socket.close();
  }
}

Map<String, dynamic>? _decodeObject(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}

void _silent(String _) {}

const _help = '''
명령 (이 창에 입력)                          브라우저 (이 PC에서만)
  status                                       http://localhost:8765/status
  net delay=80 jitter=120 loss=5               /net?delay=80&jitter=120&loss=5
  preset good | weak | bad                     /preset?name=bad
  hold 1500   (ms 동안 붙잡았다 한꺼번에)      /hold?ms=1500
  kick        (앱 연결 끊기, 재접속 확인)       /kick
  fault tag=off|on estop=on|off battery=low|ok /fault?tag=off
  quit        (종료)

WebSocket은 TCP라서 손실은 사라지는 게 아니라 멈췄다가 몰려오는 형태로 나타납니다.''';
