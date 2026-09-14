import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/telemetry.dart';
import '../theme.dart';

/// 라이다 점군. 카트가 중심, 전방이 위.
class LidarView extends StatelessWidget {
  const LidarView({
    super.key,
    required this.scan,
    this.tagBearingDeg,
    this.tagDistM,
    this.maxRangeM = 6,
  });

  final LidarScan? scan;
  final double? tagBearingDeg;
  final double? tagDistM;

  /// 화면 가장자리까지의 거리 (m). 1 m마다 링을 그린다.
  final double maxRangeM;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _LidarPainter(
            scan: scan,
            tagBearingDeg: tagBearingDeg,
            tagDistM: tagDistM,
            maxRangeM: maxRangeM,
          ),
        ),
      ),
    );
  }
}

class _LidarPainter extends CustomPainter {
  _LidarPainter({
    required this.scan,
    required this.tagBearingDeg,
    required this.tagDistM,
    required this.maxRangeM,
  });

  final LidarScan? scan;
  final double? tagBearingDeg;
  final double? tagDistM;
  final double maxRangeM;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 8;
    if (radius <= 0) return;
    final pxPerM = radius / maxRangeM;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = CartColors.grid;
    for (var m = 1; m <= maxRangeM; m++) {
      canvas.drawCircle(center, m * pxPerM, ring);
    }

    final s = scan;
    if (s != null) {
      final maxMm = maxRangeM * 1000;
      final points = <Offset>[];
      for (var i = 0; i < s.rangesMm.length; i++) {
        final mm = s.rangesMm[i];
        // 0은 측정 실패. 그대로 찍으면 카트 중심에 가짜 장애물이 생긴다.
        if (mm <= 0 || mm > maxMm) continue;
        final rad = s.angleDegAt(i) * math.pi / 180;
        final r = mm / 1000 * pxPerM;
        points.add(center + Offset(math.sin(rad) * r, -math.cos(rad) * r));
      }
      canvas.drawPoints(
        ui.PointMode.points,
        points,
        Paint()
          ..color = CartColors.accent
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round,
      );
    }

    // 카트 (폭 0.6 m × 길이 0.9 m, 작은 화면에서도 보이게 최소 크기)
    final bodyW = math.max(12.0, 0.6 * pxPerM);
    final bodyH = math.max(16.0, 0.9 * pxPerM);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: bodyW, height: bodyH),
        const Radius.circular(4),
      ),
      Paint()..color = CartColors.muted,
    );
    final noseY = center.dy - bodyH / 2;
    canvas.drawPath(
      Path()
        ..moveTo(center.dx, noseY - 8)
        ..lineTo(center.dx - 5, noseY - 1)
        ..lineTo(center.dx + 5, noseY - 1)
        ..close(),
      Paint()..color = CartColors.text,
    );

    final bearing = tagBearingDeg;
    final dist = tagDistM;
    if (bearing != null && dist != null && dist <= maxRangeM) {
      final rad = bearing * math.pi / 180;
      final p = center + Offset(math.sin(rad), -math.cos(rad)) * (dist * pxPerM);
      canvas.drawCircle(
        p,
        10,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = CartColors.text,
      );
    }
  }

  @override
  bool shouldRepaint(_LidarPainter old) =>
      old.scan != scan ||
      old.tagBearingDeg != tagBearingDeg ||
      old.tagDistM != tagDistM ||
      old.maxRangeM != maxRangeM;
}
