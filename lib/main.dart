import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'env.dart';
import 'screens/drive_screen.dart';
import 'theme.dart';
import 'transport/transport.dart';
import 'transport/websocket_transport.dart';

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
  const SmartCartApp({super.key, this.config});

  /// 테스트용. 앱에서는 빌드 옵션(--dart-define)으로 정해진 [EnvConfig.current]를 쓴다.
  final EnvConfig? config;

  @override
  State<SmartCartApp> createState() => _SmartCartAppState();
}

class _SmartCartAppState extends State<SmartCartApp> {
  late final EnvConfig _config = widget.config ?? EnvConfig.current;
  CartLink? _link;
  FaultInjection? _faults;

  @override
  void initState() {
    super.initState();
    final config = _config;
    if (config.error != null) return;

    // 전송 방식은 빌드 환경으로만 정해진다. 시뮬레이션이 아닌 빌드에서는
    // isSimulationBuild가 컴파일 타임 false라 MockTransport 코드 자체가 앱에 들어가지 않는다.
    if (isSimulationBuild && config.env == CartEnv.simulation) {
      final mock = MockTransport();
      _faults = mock.faults;
      _link = CartLink(mock);
    } else if (config.url case final url?) {
      _link = CartLink(WebSocketTransport(url));
    }
  }

  @override
  void dispose() {
    _link?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    final env = _config.env;
    return MaterialApp(
      title: '스마트카트',
      debugShowCheckedModeBanner: false,
      theme: buildCartTheme(),
      home: link == null || env == null
          ? _ConfigErrorScreen(
              message: _config.error ??
                  '이 빌드에서는 ${env?.label ?? '알 수 없는'} 환경을 쓸 수 없습니다.',
            )
          : DriveScreen(
              link: link,
              env: env,
              target: _config.url,
              faultInjection: _faults,
            ),
    );
  }
}

/// 빌드 설정이 잘못됐을 때. 카트에 연결하지 않고 이유만 보여준다.
class _ConfigErrorScreen extends StatelessWidget {
  const _ConfigErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '빌드 설정 오류',
                style: CartText.title.copyWith(
                  fontSize: 22,
                  color: CartColors.warn,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                style: CartText.title.copyWith(fontWeight: FontWeight.w400),
              ),
              const SizedBox(height: 8),
              const Text('이 앱은 카트에 연결하지 않습니다.', style: CartText.label),
              const SizedBox(height: 24),
              const Text('빌드 예시', style: CartText.label),
              const SizedBox(height: 8),
              SelectableText(
                'flutter build apk --dart-define=CART_ENV=vehicle '
                '--dart-define=CART_URL=ws://192.168.4.1:8765',
                style: CartText.label.copyWith(
                  color: CartColors.text,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
