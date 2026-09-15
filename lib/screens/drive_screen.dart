import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../env.dart';
import '../models/telemetry.dart';
import '../theme.dart';
import '../transport/transport.dart';
import '../widgets/joystick.dart';
import '../widgets/lidar_view.dart';

/// 주행 화면 (수동 / 자동).
///
/// [CartLink]만 알고, 그 뒤가 WebSocket인지 Mock인지는 모른다.
class DriveScreen extends StatelessWidget {
  const DriveScreen({
    super.key,
    required this.link,
    required this.env,
    this.target,
    this.faultInjection,
  });

  final CartLink link;

  /// 빌드 환경. 상단에 항상 표시해서 시뮬레이션과 실차를 헷갈리지 않게 한다.
  final CartEnv env;

  /// 연결 대상 주소. 시뮬레이션이면 null.
  final Uri? target;

  /// Mock 전송일 때만 넘어온다. null이면 고장 주입 패널을 숨긴다.
  final FaultInjection? faultInjection;

  static const _wideBreakpoint = 960.0;
  static const _gap = SizedBox.square(dimension: 12);

  bool get _live => link.status == LinkStatus.live;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListenableBuilder(
            listenable: link,
            builder: (context, _) => LayoutBuilder(
              // 가로로 긴 화면(휴대폰 가로 포함)은 좌우 배치. 세로로 쌓으면
              // 조이스틱 카드만으로 높이가 거의 차서 넘친다.
              builder: (context, box) => box.maxWidth >= _wideBreakpoint ||
                      box.maxWidth > box.maxHeight
                  ? _buildWide(box)
                  : _buildNarrow(box),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWide(BoxConstraints box) {
    final fi = faultInjection;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusBar(link: link, env: env),
              _gap,
              _cappedAlerts(box, 0.4),
              Expanded(
                child: _dimWhenStale(_LidarCard(telemetry: link.latest)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: math.min(460.0, box.maxWidth * 0.55),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _dimWhenStale(_StatGrid(telemetry: link.latest)),
                      // 고장 주입 패널은 흐리게 하지 않는다 — 끊긴 상태에서 되돌려야 하니까.
                      // isSimulationBuild가 false인 빌드에서는 패널 코드가 통째로 빠진다.
                      if (isSimulationBuild && fi != null) ...[
                        _gap,
                        _FaultInjectionCard(faults: fi),
                      ],
                    ],
                  ),
                ),
              ),
              _gap,
              _ControlCard(link: link),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNarrow(BoxConstraints box) {
    final fi = faultInjection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusBar(link: link, env: env),
        _gap,
        _cappedAlerts(box, 0.3),
        Expanded(
          child: ListView(
            children: [
              SizedBox(
                height: 320,
                child: _dimWhenStale(_LidarCard(telemetry: link.latest)),
              ),
              _gap,
              _dimWhenStale(_StatGrid(telemetry: link.latest)),
              if (isSimulationBuild && fi != null) ...[
                _gap,
                _FaultInjectionCard(faults: fi),
              ],
            ],
          ),
        ),
        _gap,
        _ControlCard(link: link),
      ],
    );
  }

  /// 경고가 여러 개 쌓여도 주행 화면을 밀어내지 않도록 높이를 제한하고 넘치면 스크롤.
  Widget _cappedAlerts(BoxConstraints box, double maxFraction) =>
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: box.maxHeight * maxFraction),
        child: SingleChildScrollView(
          child: _Alerts(link: link, target: target),
        ),
      );

  Widget _dimWhenStale(Widget child) => AnimatedOpacity(
        opacity: _live ? 1 : 0.35,
        duration: const Duration(milliseconds: 150),
        child: child,
      );
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.link, required this.env});

  final CartLink link;
  final CartEnv env;

  @override
  Widget build(BuildContext context) {
    final t = link.latest;
    final (dotColor, text) = switch (link.status) {
      LinkStatus.connecting => (CartColors.muted, '연결 중'),
      LinkStatus.live => (CartColors.accent, '연결됨'),
      LinkStatus.lost => (CartColors.warn, '연결 끊김'),
    };
    final rtt = t?.link?.rttMs;

    return Row(
      children: [
        _EnvBadge(env: env),
        const SizedBox(width: 12),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(text, style: CartText.title),
        if (link.status == LinkStatus.live && rtt != null) ...[
          const SizedBox(width: 8),
          Text('$rtt ms', style: CartText.label),
        ],
        const Spacer(),
        // 요청한 모드가 아니라 카트가 보고한 실제 모드
        const Text('모드', style: CartText.label),
        const SizedBox(width: 6),
        Text(_modeLabel(t?.drive?.mode), style: CartText.title),
      ],
    );
  }
}

/// 빌드 환경 배지. 실제로 움직이는 환경(실차)만 주의 색으로 칠한다.
class _EnvBadge extends StatelessWidget {
  const _EnvBadge({required this.env});

  final CartEnv env;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (env) {
      CartEnv.vehicle => (CartColors.warnBg, CartColors.warn),
      CartEnv.simulation ||
      CartEnv.server =>
        (CartColors.accent.withValues(alpha: 0.16), CartColors.accent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(CartRadii.card),
      ),
      child: Text(
        env.label,
        style: CartText.label.copyWith(
          color: foreground,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _Alerts extends StatelessWidget {
  const _Alerts({required this.link, required this.target});

  final CartLink link;
  final Uri? target;

  @override
  Widget build(BuildContext context) {
    final power = link.latest?.power;
    final faults = link.latest?.faults ?? const <String>[];
    final ageSec = link.telemetryAge.inMilliseconds / 1000;
    final tagOk = link.latest?.uwb?.tag == 'ok';
    final target = this.target;

    final blocks = <Widget>[
      if (link.status == LinkStatus.connecting)
        _Block(
          title: '카트 연결 중…',
          detail: target == null
              ? '앱 안의 가짜 카트를 기다리는 중입니다'
              : '$target 에 연결하는 중입니다',
        ),
      if (link.status == LinkStatus.lost)
        _Block(
          warn: true,
          title: '연결 끊김',
          detail: '마지막 수신 ${ageSec.toStringAsFixed(1)}초 전 · '
              '명령이 200ms 끊기면 카트가 모터 출력을 끕니다 (제동 아님)',
        ),
      if (link.modeDrop case final drop?)
        _Block(
          warn: true,
          title: '자동 모드 해제됨',
          detail: switch (drop) {
            ModeDrop.rejected => '카트가 자동 전환을 받아들이지 않았습니다',
            ModeDrop.droppedByCart => tagOk
                ? '카트가 수동으로 돌아갔습니다'
                : '태그 신호가 끊겨 카트가 수동으로 돌아갔습니다',
            ModeDrop.linkLost => '연결이 끊겨 수동으로 돌아갔습니다. 다시 연결돼도 자동은 재개하지 않습니다',
          },
        ),
      if (power != null && power.driveCutOff)
        _Block(
          warn: true,
          title: '구동 전원 차단됨',
          detail: '${power.estop == true ? 'E-stop 눌림 · ' : ''}'
              '접촉기 열림. 제동이 아니므로 경사에서는 굴러갈 수 있습니다',
        ),
      if (faults.isNotEmpty) _FaultList(codes: faults),
    ];
    if (blocks.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            blocks[i],
          ],
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, this.detail, this.warn = false});

  final String title;
  final String? detail;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    return _Card(
      color: warn ? CartColors.warnBg : CartColors.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: CartText.title.copyWith(
              fontSize: 17,
              color: warn ? CartColors.warn : CartColors.text,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(detail, style: CartText.label),
          ],
        ],
      ),
    );
  }
}

/// 고장 코드 목록. 아는 코드는 한글 설명과 원문, 모르는 코드는 원문 그대로.
class _FaultList extends StatelessWidget {
  const _FaultList({required this.codes});

  final List<String> codes;

  static const _labels = {
    'battery_low': '배터리 저하',
    'lidar_slow': '라이다 수신 주기 지연',
    'estop_pressed': 'E-stop 눌림',
    'cliff': '낙차 감지',
    'uwb_tag_lost': '태그 신호 끊김',
  };

  @override
  Widget build(BuildContext context) {
    return _Card(
      color: CartColors.warnBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('고장 코드 ${codes.length}건', style: CartText.label),
          for (final code in codes)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      _labels[code] ?? code,
                      style: CartText.title.copyWith(color: CartColors.warn),
                    ),
                  ),
                  if (_labels.containsKey(code)) ...[
                    const SizedBox(width: 8),
                    Text(code, style: CartText.label),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _LidarCard extends StatelessWidget {
  const _LidarCard({required this.telemetry});

  final Telemetry? telemetry;

  @override
  Widget build(BuildContext context) {
    final scan = telemetry?.lidar;
    final uwb = telemetry?.uwb;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('라이다', style: CartText.label),
              const Spacer(),
              Text(
                scan == null ? _none : 'seq ${scan.seq} · 링 간격 1 m',
                style: CartText.label,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LidarView(
              scan: scan,
              tagBearingDeg: uwb?.bearingDeg,
              tagDistM: uwb?.distM,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.telemetry});

  final Telemetry? telemetry;

  @override
  Widget build(BuildContext context) {
    final t = telemetry;
    final power = t?.power;
    final drive = t?.drive;
    final pose = t?.pose;
    final tof = t?.tof;
    final uwb = t?.uwb;
    final battery = power?.batteryPct;
    final speed = drive?.speedMps;
    final lidarTotal = t?.lidar?.rangesMm.length ?? 0;
    final lidarValid = t?.lidar?.validCount ?? 0;

    final stats = [
      _Stat(
        label: '배터리',
        value: _num(battery, 0),
        unit: '%',
        sub: [
          if (power?.batteryV case final v?) '${_num(v, 1)} V',
          // 휴대폰 카드 폭에 맞춰 짧게. 차단 상세는 경고 블록에 따로 뜬다.
          switch (power?.contactor) {
            'closed' => '구동 연결',
            'open' => '구동 차단',
            _ => '접촉기 $_none',
          },
        ].join(' · '),
        warn: battery != null && battery <= 20,
      ),
      _Stat(
        label: '태그 거리',
        value: _num(uwb?.distM, 1),
        unit: 'm',
        sub: '방향 ${_deg(uwb?.bearingDeg, 0)} · 태그 ${uwb?.tag ?? _none}',
      ),
      _Stat(
        label: '출력 좌',
        value: _num(drive?.dutyL, 0),
        unit: '%',
        sub: '전류 ${_num(drive?.currentL, 1)} A',
      ),
      _Stat(
        label: '출력 우',
        value: _num(drive?.dutyR, 0),
        unit: '%',
        sub: '전류 ${_num(drive?.currentR, 1)} A',
      ),
      _Stat(
        label: '속도',
        value: _num(speed, 2),
        unit: 'm/s',
        sub: speed == null ? '엔코더 미장착' : '엔코더 실측',
      ),
      _Stat(
        label: '피치',
        value: _num(pose?.pitch, 1),
        unit: '°',
        sub: '롤 ${_deg(pose?.roll, 1)} · 방위 ${_deg(pose?.yaw, 0)}',
      ),
      _Stat(
        label: '측면 근접',
        value: tof == null
            ? _none
            : '${_num(tof.leftMm, 0)}/${_num(tof.rightMm, 0)}',
        unit: 'mm',
        sub: switch (tof?.cliff) {
          true => '낙차 감지',
          false => '낙차 없음',
          null => '낙차 $_none',
        },
        warn: tof?.cliff == true,
      ),
      _Stat(
        label: '라이다 유효',
        value: lidarTotal == 0 ? _none : _num(lidarValid * 100 / lidarTotal, 0),
        unit: '%',
        sub: lidarTotal == 0
            ? '스캔 없음'
            : '측정 실패 ${lidarTotal - lidarValid} / $lidarTotal',
      ),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        // 부동소수 반올림으로 한 줄에 하나씩 떨어지지 않게 내림
        final width = ((box.maxWidth - 12) / 2).floorToDouble();
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final s in stats) SizedBox(width: width, child: s)],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.unit,
    this.sub,
    this.warn = false,
  });

  final String label;
  final String value;
  final String? unit;
  final String? sub;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final unit = this.unit;
    final sub = this.sub;
    return _Card(
      color: warn ? CartColors.warnBg : CartColors.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: CartText.label),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: warn
                      ? CartText.bigNumber.copyWith(color: CartColors.warn)
                      : CartText.bigNumber,
                ),
                if (unit != null && value != _none) ...[
                  const SizedBox(width: 4),
                  Text(unit, style: CartText.unit),
                ],
              ],
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: 4),
            Text(
              sub,
              style: CartText.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// 모드 전환 + 모드별 조작 패널.
class _ControlCard extends StatelessWidget {
  const _ControlCard({required this.link});

  final CartLink link;

  @override
  Widget build(BuildContext context) {
    final auto = link.requestedMode == DriveMode.follow;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ModeSwitch(link: link),
          const SizedBox(height: 16),
          auto ? _FollowPanel(link: link) : _ManualPanel(link: link),
        ],
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.link});

  final CartLink link;

  @override
  Widget build(BuildContext context) {
    final auto = link.requestedMode == DriveMode.follow;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: CartColors.bg,
        borderRadius: BorderRadius.circular(CartRadii.card),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Segment(
              label: '수동',
              selected: !auto,
              onTap: () => link.requestMode(DriveMode.manual),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _Segment(
              label: '자동',
              selected: auto,
              enabled: auto || link.followBlock == null,
              onTap: () => link.requestMode(DriveMode.follow),
            ),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? CartColors.muted.withValues(alpha: 0.4)
        : (selected ? CartColors.text : CartColors.muted);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? CartColors.grid : CartColors.bg,
            // 바깥 트랙(18)과 안쪽 여백(4)에 맞춘 동심 모서리
            borderRadius: BorderRadius.circular(CartRadii.card - 4),
          ),
          child: Text(label, style: CartText.title.copyWith(color: color)),
        ),
      ),
    );
  }
}

class _ManualPanel extends StatelessWidget {
  const _ManualPanel({required this.link});

  final CartLink link;

  @override
  Widget build(BuildContext context) {
    final live = link.status == LinkStatus.live;
    final autoUnavailable = switch (link.followBlock) {
      FollowBlock.tagNotOk => '자동 전환 불가 · 태그 신호 없음',
      FollowBlock.driveCutOff => '자동 전환 불가 · 구동 전원 차단됨',
      _ => null,
    };

    return Row(
      children: [
        DeadmanJoystick(
          enabled: live,
          onHold: link.hold,
          onRelease: link.release,
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('수동 주행', style: CartText.title),
              const SizedBox(height: 4),
              Text(
                live ? '누르고 있는 동안만 명령이 나갑니다' : '연결되어 있을 때만 조작할 수 있습니다',
                style: CartText.label,
              ),
              if (autoUnavailable != null) ...[
                const SizedBox(height: 2),
                Text(autoUnavailable, style: CartText.label),
              ],
              const SizedBox(height: 16),
              _Readout(label: '스로틀', value: _num(link.throttle, 2)),
              const SizedBox(height: 4),
              _Readout(label: '조향', value: _num(link.steer, 2)),
            ],
          ),
        ),
      ],
    );
  }
}

class _FollowPanel extends StatelessWidget {
  const _FollowPanel({required this.link});

  final CartLink link;

  @override
  Widget build(BuildContext context) {
    final uwb = link.latest?.uwb;
    final dist = uwb?.distM;
    final pending = link.followPending;

    return Row(
      children: [
        SizedBox.square(
          dimension: 164,
          child: CustomPaint(
            painter: _TagCompassPainter(
              bearingDeg: uwb?.bearingDeg,
              active: !pending,
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(pending ? '자동 전환 중…' : '태그 추종 중', style: CartText.title),
              const SizedBox(height: 4),
              Text(
                pending ? '카트의 응답을 기다리는 중입니다' : '사람을 따라갑니다 · 조이스틱 잠김',
                style: CartText.label,
              ),
              const SizedBox(height: 16),
              _Readout(
                label: '거리',
                value: dist == null ? _none : '${_num(dist, 1)} m',
              ),
              const SizedBox(height: 4),
              _Readout(label: '방향', value: _deg(uwb?.bearingDeg, 0)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 자동 모드에서 조이스틱 자리에 표시: 카트 기준 태그 방향.
class _TagCompassPainter extends CustomPainter {
  _TagCompassPainter({required this.bearingDeg, required this.active});

  final double? bearingDeg;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(center, radius, Paint()..color = CartColors.bg);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 18, height: 26),
        const Radius.circular(4),
      ),
      Paint()..color = CartColors.muted,
    );
    final noseY = center.dy - 13;
    canvas.drawPath(
      Path()
        ..moveTo(center.dx, noseY - 8)
        ..lineTo(center.dx - 5, noseY - 1)
        ..lineTo(center.dx + 5, noseY - 1)
        ..close(),
      Paint()..color = CartColors.text,
    );

    final bearing = bearingDeg;
    if (bearing == null) return;
    final rad = bearing * math.pi / 180;
    final p = center + Offset(math.sin(rad), -math.cos(rad)) * (radius - 18);
    canvas.drawCircle(
      p,
      9,
      Paint()..color = active ? CartColors.accent : CartColors.grid,
    );
  }

  @override
  bool shouldRepaint(_TagCompassPainter old) =>
      old.bearingDeg != bearingDeg || old.active != active;
}

class _Readout extends StatelessWidget {
  const _Readout({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 56, child: Text(label, style: CartText.label)),
        Text(
          value,
          style: CartText.title.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _FaultInjectionCard extends StatelessWidget {
  const _FaultInjectionCard({required this.faults});

  final FaultInjection faults;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('고장 주입 · Mock 전용', style: CartText.label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Toggle(label: '통신 끊기', value: faults.dropLink),
              _Toggle(label: '태그 신호 끊김', value: faults.tagLost),
              _Toggle(label: '배터리 저하', value: faults.lowBattery),
              _Toggle(label: 'E-stop', value: faults.estop),
            ],
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value});

  final String label;
  final ValueNotifier<bool> value;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: value,
      builder: (context, on, _) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => value.value = !on,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: on ? CartColors.warnBg : CartColors.bg,
              borderRadius: BorderRadius.circular(CartRadii.card),
            ),
            child: Text(
              label,
              style: CartText.title.copyWith(
                fontSize: 14,
                color: on ? CartColors.warn : CartColors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.color = CartColors.card});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(CartRadii.card),
      ),
      child: child,
    );
  }
}

const _none = '—';

String _modeLabel(String? mode) => switch (mode) {
      'manual' => '수동',
      'follow' => '자동',
      final String other => other,
      null => _none,
    };

/// 숫자 포맷. 음수는 하이픈 대신 U+2212(−), "-0.0"은 "0.0"으로.
String _num(num? v, int digits) {
  if (v == null) return _none;
  final s = v.toStringAsFixed(digits);
  if (!s.startsWith('-')) return s;
  final abs = s.substring(1);
  return double.parse(abs) == 0 ? abs : '−$abs';
}

String _deg(num? v, int digits) => v == null ? _none : '${_num(v, digits)}°';
