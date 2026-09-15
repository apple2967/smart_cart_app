import 'dart:async';

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
  AppLifecycleListener? _lifecycle;

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

    if (_link != null) {
      _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
      // 추종 중에는 화면을 만질 일이 없어서, 화면이 꺼지면 앱이 사라진 것으로 보고 자동이 풀린다.
      // 조작 화면이 떠 있는 동안은 화면 꺼짐을 막는다. 대신 배터리를 더 쓴다.
      unawaited(_setScreenAwake(true));
    }
  }

  void _onLifecycle(AppLifecycleState state) {
    final link = _link;
    if (link == null) return;
    switch (state) {
      case AppLifecycleState.inactive:
        // 알림창·전화 화면이 위에 뜸
        link.pauseControl(hidden: false);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // 홈·앱 전환·화면 꺼짐
        link.pauseControl(hidden: true);
      case AppLifecycleState.resumed:
        // 돌아와도 아무것도 재개하지 않는다. 조이스틱은 새로 눌러야 하고 자동은 다시 켜야 한다.
        break;
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    if (_link != null) unawaited(_setScreenAwake(false));
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

/// 안드로이드 MainActivity가 받아서 창의 FLAG_KEEP_SCREEN_ON을 켜고 끈다.
/// 플러그인을 쓰지 않는 이유: Windows에서 네이티브 플러그인을 빌드하려면 개발자 모드가 필요하다.
const _screenChannel = MethodChannel('smart_cart/screen');

/// 화면 꺼짐 방지. 편의 기능이라 지원하지 않는 환경(Windows, 테스트)에서는 조용히 넘어간다.
Future<void> _setScreenAwake(bool on) async {
  try {
    await _screenChannel.invokeMethod<void>('keepOn', on);
  } on MissingPluginException {
    // 안드로이드 외 플랫폼
  } on PlatformException {
    // 조작과 무관한 기능이라 무시
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
              const SizedBox(height: 24),
              const Text('v$appVersion', style: CartText.label),
            ],
          ),
        ),
      ),
    );
  }
}
