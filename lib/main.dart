import 'package:flutter/material.dart';

import 'screens/drive_screen.dart';
import 'theme.dart';
import 'transport/transport.dart';

void main() => runApp(const SmartCartApp());

class SmartCartApp extends StatefulWidget {
  const SmartCartApp({super.key});

  @override
  State<SmartCartApp> createState() => _SmartCartAppState();
}

class _SmartCartAppState extends State<SmartCartApp> {
  // 전송 방식 교체 지점. 실물 카트에 붙일 때 이 한 줄만 바꾼다:
  //   final CartTransport _transport = WebSocketTransport(Uri.parse('ws://<카트 IP>:<포트>'));
  final CartTransport _transport = MockTransport();
  late final CartLink _link = CartLink(_transport);

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '스마트카트',
      debugShowCheckedModeBanner: false,
      theme: buildCartTheme(),
      home: DriveScreen(
        link: _link,
        faultInjection: switch (_transport) {
          MockTransport(:final faults) => faults,
          _ => null,
        },
      ),
    );
  }
}
