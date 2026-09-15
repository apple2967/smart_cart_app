/// 빌드할 때 정하는 실행 환경. 실행 중에는 바꿀 수 없다.
///
/// ```
/// flutter run                                                  # 시뮬레이션 (기본값)
/// flutter run --dart-define=CART_ENV=server --dart-define=CART_URL=ws://192.168.0.10:8765
/// flutter build apk --dart-define=CART_ENV=vehicle --dart-define=CART_URL=ws://192.168.4.1:8765
/// ```
///
/// 기본값이 시뮬레이션인 이유: 설정을 빠뜨린 빌드가 실차에 붙는 것보다 안 붙는 쪽이 안전하다.
/// 앱 안에 환경 전환 스위치를 두지 않는 이유도 같다 — 실수로 누를 수 있으면 언젠가 누른다.
library;

const cartEnvName =
    String.fromEnvironment('CART_ENV', defaultValue: 'simulation');
const cartUrl = String.fromEnvironment('CART_URL');

/// 컴파일 타임 상수. false인 빌드에서는 MockTransport와 고장 주입 패널이
/// 트리 셰이킹으로 앱에서 빠진다.
const isSimulationBuild = cartEnvName == 'simulation';

enum CartEnv {
  /// 앱 안의 가짜 카트(MockTransport). 실제 카트와 통신하지 않는다.
  simulation('시뮬레이션'),

  /// PC 등에서 돌리는 테스트 서버에 WebSocket으로 연결.
  server('테스트 서버'),

  /// 실제 카트에 WebSocket으로 연결.
  vehicle('실차');

  const CartEnv(this.label);

  final String label;
}

class EnvConfig {
  const EnvConfig._({this.env, this.url, this.error});

  factory EnvConfig.parse(String envName, String url) {
    final env = CartEnv.values.asNameMap()[envName];
    if (env == null) {
      return EnvConfig._(
        error: 'CART_ENV "$envName"은(는) 알 수 없는 환경입니다. '
            'simulation, server, vehicle 중 하나로 빌드하세요.',
      );
    }
    if (env == CartEnv.simulation) return EnvConfig._(env: env);

    final uri = Uri.tryParse(url);
    final valid = uri != null &&
        (uri.scheme == 'ws' || uri.scheme == 'wss') &&
        uri.host.isNotEmpty;
    if (!valid) {
      return EnvConfig._(
        env: env,
        error: '${env.label} 빌드에는 ws:// 로 시작하는 CART_URL이 필요합니다. '
            '지금 값: ${url.isEmpty ? '없음' : '"$url"'}',
      );
    }
    return EnvConfig._(env: env, url: uri);
  }

  /// 이 빌드의 환경.
  static final current = EnvConfig.parse(cartEnvName, cartUrl);

  /// 환경 이름을 알 수 없으면 null.
  final CartEnv? env;

  /// 연결 대상. 시뮬레이션이면 null.
  final Uri? url;

  /// 잘못된 빌드 설정. null이 아니면 앱은 카트에 연결하지 않는다.
  final String? error;
}
