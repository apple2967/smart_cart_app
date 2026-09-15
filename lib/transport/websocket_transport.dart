import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/telemetry.dart';
import 'transport.dart';

/// WebSocket으로 실제 카트나 PC 테스트 서버와 통신한다.
///
/// 연결 유지와 JSON 변환만 맡는다. 끊김 판정과 조작 해제는 [CartLink]가
/// 수신 간격으로 하므로, 소켓이 열려 있다고 해서 연결된 것으로 보지 않는다.
///
/// dart:io를 쓰므로 웹 빌드에서는 동작하지 않는다 (대상은 안드로이드·Windows).
class WebSocketTransport implements CartTransport {
  WebSocketTransport(this.url) {
    unawaited(_connect());
  }

  final Uri url;

  static const _connectTimeout = Duration(seconds: 3);
  static const _minBackoff = Duration(milliseconds: 500);
  static const _maxBackoff = Duration(seconds: 5);

  final _controller = StreamController<Telemetry>.broadcast();
  WebSocket? _socket;
  Timer? _retry;
  Duration _backoff = _minBackoff;
  bool _closed = false;

  @override
  Stream<Telemetry> get telemetry => _controller.stream;

  Future<void> _connect() async {
    if (_closed) return;
    try {
      final socket = await WebSocket.connect(
        url.toString(),
        customClient: HttpClient()..connectionTimeout = _connectTimeout,
      );
      if (_closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      _backoff = _minBackoff;
      socket.listen(
        _onMessage,
        onDone: _scheduleReconnect,
        onError: (Object _) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } on Object {
      // 카트가 아직 안 켜졌거나 Wi-Fi가 다른 망에 붙은 경우. 계속 다시 시도한다.
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final json = jsonDecode(data);
      if (json is Map<String, dynamic>) {
        _controller.add(Telemetry.fromJson(json));
      }
    } on FormatException {
      // 깨진 프레임은 버린다. 계속 깨지면 CartLink가 수신 끊김으로 판정한다.
    }
  }

  void _scheduleReconnect() {
    _socket = null;
    if (_closed || (_retry?.isActive ?? false)) return;
    _retry = Timer(_backoff, _connect);
    final next = _backoff * 2;
    _backoff = next > _maxBackoff ? _maxBackoff : next;
  }

  @override
  void send(DriveCommand command) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    try {
      socket.add(jsonEncode(command.toJson()));
    } on Object {
      // 보내다 끊기면 재접속 흐름이 처리한다. 50ms 뒤 다음 명령이 간다.
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _socket?.close();
    await _controller.close();
  }
}
