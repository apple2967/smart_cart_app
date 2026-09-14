import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/drive_screen.dart';
import 'theme.dart';
import 'transport/transport.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 안드로이드: 화면을 시스템 바 뒤까지 그리고, 하단 내비게이션 바에 시스템이 깔아주는
  // 반투명 막을 꺼서 다크 배경이 그대로 이어지게 한다. 데스크톱에서는 아무 일도 안 한다.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  ));
  runApp(const SmartCartApp());
}

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
