import 'package:flutter/material.dart';

import '../theme.dart';

/// 데드맨 조이스틱. 손가락이 닿아 있는 동안만 [onHold], 떼는 순간 [onRelease].
///
/// GestureDetector의 pan은 터치 슬롭만큼 움직인 뒤에야 시작하므로,
/// 누르는 즉시 반응하도록 Listener로 포인터를 직접 받는다.
class DeadmanJoystick extends StatefulWidget {
  const DeadmanJoystick({
    super.key,
    required this.onHold,
    required this.onRelease,
    this.enabled = true,
    this.size = 164,
  });

  /// throttle: 위 = +1, steer: 오른쪽 = +1
  final void Function(double throttle, double steer) onHold;
  final VoidCallback onRelease;
  final bool enabled;
  final double size;

  @override
  State<DeadmanJoystick> createState() => _DeadmanJoystickState();
}

class _DeadmanJoystickState extends State<DeadmanJoystick> {
  static const _knobSize = 64.0;
  static const _deadZone = 0.06;

  int? _pointer;

  /// 단위 원 안의 스틱 위치 (y는 아래가 +).
  Offset _stick = Offset.zero;

  double get _travel => (widget.size - _knobSize) / 2;

  @override
  void didUpdateWidget(DeadmanJoystick oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 누른 채 비활성화되면 풀어준다. 지금 누르고 있는 손가락은 무시되므로
    // 다시 조작하려면 손을 뗐다가 새로 눌러야 한다.
    if (!widget.enabled && _pointer != null) {
      _pointer = null;
      _stick = Offset.zero;
      widget.onRelease();
    }
  }

  @override
  void dispose() {
    // 레이아웃 전환 등으로 누른 채 위젯이 사라지면 포인터 업이 오지 않는다.
    if (_pointer != null) widget.onRelease();
    super.dispose();
  }

  void _onDown(PointerDownEvent e) {
    if (!widget.enabled || _pointer != null) return;
    _pointer = e.pointer;
    _update(e);
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer == _pointer) _update(e);
  }

  void _onUp(PointerEvent e) {
    if (e.pointer != _pointer) return;
    setState(() {
      _pointer = null;
      _stick = Offset.zero;
    });
    widget.onRelease();
  }

  void _update(PointerEvent e) {
    final center = Offset(widget.size / 2, widget.size / 2);
    var v = (e.localPosition - center) / _travel;
    if (v.distance > 1) v = v / v.distance;
    setState(() => _stick = v);
    widget.onHold(_applyDeadZone(-v.dy), _applyDeadZone(v.dx));
  }

  double _applyDeadZone(double x) => x.abs() < _deadZone ? 0 : x;

  @override
  Widget build(BuildContext context) {
    final knobColor = !widget.enabled
        ? CartColors.grid.withValues(alpha: 0.5)
        : (_pointer != null ? CartColors.accent : CartColors.grid);

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: SizedBox.square(
        dimension: widget.size,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: CartColors.bg,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Transform.translate(
              offset: _stick * _travel,
              child: Container(
                width: _knobSize,
                height: _knobSize,
                decoration: BoxDecoration(
                  color: knobColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
