import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Visual state of the hero connect button. The home screen maps the
/// VPN controller state onto this (an error maps to disconnected).
enum VpnStateVisual { disconnected, connecting, connected, disconnecting }

/// The hero connect button: a ~210 px circular core wrapped in a slowly
/// rotating dashed chakra ring, with pulse rings while connecting and a
/// gentle breathing glow while connected.
///
/// Pure Flutter animation: three controllers (rotation, pulse, press)
/// plus a breathing controller, all driving paint/transform only.
class ConnectButton extends StatefulWidget {
  final VpnStateVisual state;
  final VoidCallback onTap;

  const ConnectButton({super.key, required this.state, required this.onTap});

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton>
    with TickerProviderStateMixin {
  static const double _coreSize = 210;
  static const double _ringSize = 228;
  static const double _outerSize = 256;

  late final AnimationController _rotation;
  late final AnimationController _pulse;
  late final AnimationController _sweep;
  late final AnimationController _breath;
  late final AnimationController _press;
  late final Animation<double> _pressScale;

  Duration _rotationDuration(VpnStateVisual s) {
    switch (s) {
      case VpnStateVisual.connecting:
        return const Duration(milliseconds: 2500);
      case VpnStateVisual.disconnecting:
        return const Duration(milliseconds: 3000);
      case VpnStateVisual.connected:
        return const Duration(seconds: 40);
      case VpnStateVisual.disconnected:
        return const Duration(seconds: 24);
    }
  }

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(
      vsync: this,
      duration: _rotationDuration(widget.state),
    )..repeat();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    // Fast comet sweep around the ring while connecting.
    _sweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _pressScale = Tween<double>(begin: 1, end: 0.94).animate(
      CurvedAnimation(
        parent: _press,
        curve: Curves.fastOutSlowIn,
        reverseCurve: Curves.elasticOut,
      ),
    );
    _applyState(widget.state, initial: true);
  }

  /// Restarts the state-driven animations for [s]. Called on init and
  /// whenever the visual state changes.
  void _applyState(VpnStateVisual s, {bool initial = false}) {
    if (!initial) {
      final d = _rotationDuration(s);
      if (_rotation.duration != d) {
        _rotation
          ..duration = d
          ..repeat();
      }
    }
    if (s == VpnStateVisual.connecting) {
      if (!_pulse.isAnimating) _pulse.repeat();
      if (!_sweep.isAnimating) _sweep.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
      _sweep.stop();
      _sweep.value = 0;
    }
    if (s == VpnStateVisual.connected) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _breath.stop();
      _breath.value = 0;
    }
  }

  @override
  void didUpdateWidget(covariant ConnectButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _applyState(widget.state);
  }

  @override
  void dispose() {
    _rotation.dispose();
    _pulse.dispose();
    _sweep.dispose();
    _breath.dispose();
    _press.dispose();
    super.dispose();
  }

  Color get _stateColor {
    switch (widget.state) {
      case VpnStateVisual.connected:
        return ChakraTheme.emerald;
      case VpnStateVisual.connecting:
      case VpnStateVisual.disconnecting:
        return ChakraTheme.amber;
      case VpnStateVisual.disconnected:
        return ChakraTheme.violet;
    }
  }

  Gradient get _coreGradient {
    switch (widget.state) {
      case VpnStateVisual.connected:
        return ChakraTheme.connectedGradient;
      case VpnStateVisual.connecting:
        return const LinearGradient(
          colors: [ChakraTheme.amber, ChakraTheme.violet],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
      case VpnStateVisual.disconnecting:
        return const LinearGradient(
          colors: [ChakraTheme.amber, ChakraTheme.cyan],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
      case VpnStateVisual.disconnected:
        return ChakraTheme.brandGradient;
    }
  }

  String get _label {
    switch (widget.state) {
      case VpnStateVisual.connected:
        return 'Connected';
      case VpnStateVisual.connecting:
        return 'Connecting…';
      case VpnStateVisual.disconnecting:
        return 'Disconnecting…';
      case VpnStateVisual.disconnected:
        return 'Connect';
    }
  }

  Widget _iconFor(VpnStateVisual s) {
    switch (s) {
      case VpnStateVisual.connected:
        return const Icon(
          Icons.verified_user,
          key: ValueKey('connected'),
          size: 52,
          color: Colors.white,
        );
      case VpnStateVisual.connecting:
        return const SizedBox(
          key: ValueKey('connecting'),
          width: 52,
          height: 52,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        );
      case VpnStateVisual.disconnecting:
        return const Icon(
          Icons.hourglass_top,
          key: ValueKey('disconnecting'),
          size: 52,
          color: Colors.white,
        );
      case VpnStateVisual.disconnected:
        return const Icon(
          Icons.power_settings_new,
          key: ValueKey('disconnected'),
          size: 52,
          color: Colors.white,
        );
    }
  }

  Widget _pulseRing(double phase) {
    final scale = 1 + 0.35 * phase;
    final opacity = (1 - phase) * 0.45;
    return Transform.scale(
      scale: scale,
      child: Container(
        width: _coreSize,
        height: _coreSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: _stateColor.withValues(alpha: opacity),
            width: 2,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenable = Listenable.merge([
      _rotation,
      _pulse,
      _sweep,
      _breath,
      _pressScale,
    ]);
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _press.forward(),
      onTapUp: (_) => _press.reverse(),
      onTapCancel: () => _press.reverse(),
      child: AnimatedBuilder(
        animation: listenable,
        builder: (context, _) {
          final breathScale = widget.state == VpnStateVisual.connected
              ? 1 + 0.03 * _breath.value
              : 1.0;
          final scale = _pressScale.value * breathScale;
          final glowAlpha =
              0.45 +
              (widget.state == VpnStateVisual.connected
                  ? 0.25 * _breath.value
                  : 0);
          return Transform.scale(
            scale: scale,
            child: SizedBox(
              width: _outerSize,
              height: _outerSize,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  // Expanding pulse rings while connecting (two rings,
                  // half a cycle apart).
                  if (widget.state == VpnStateVisual.connecting) ...[
                    _pulseRing(_pulse.value),
                    _pulseRing((_pulse.value + 0.5) % 1.0),
                  ],
                  // Rotating dashed chakra ring.
                  Transform.rotate(
                    angle: _rotation.value * 2 * math.pi,
                    child: CustomPaint(
                      size: const Size(_ringSize, _ringSize),
                      painter: _DashedRingPainter(color: _stateColor),
                    ),
                  ),
                  // Fast comet sweep around the ring while connecting.
                  if (widget.state == VpnStateVisual.connecting)
                    Transform.rotate(
                      angle: _sweep.value * 2 * math.pi,
                      child: CustomPaint(
                        size: const Size(_ringSize + 18, _ringSize + 18),
                        painter: _SweepArcPainter(color: _stateColor),
                      ),
                    ),
                  // Gradient core with a state-coloured glow.
                  Container(
                    width: _coreSize,
                    height: _coreSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: _coreGradient,
                      boxShadow: [
                        BoxShadow(
                          color: _stateColor.withValues(alpha: glowAlpha),
                          blurRadius: 42,
                          spreadRadius: 4,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          transitionBuilder: (child, anim) => ScaleTransition(
                            scale: anim,
                            child: FadeTransition(opacity: anim, child: child),
                          ),
                          child: _iconFor(widget.state),
                        ),
                        const SizedBox(height: 10),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Text(
                            _label,
                            key: ValueKey(_label),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.state == VpnStateVisual.connecting
                              ? 'Tap to cancel'
                              : widget.state == VpnStateVisual.connected
                              ? 'Tap to disconnect'
                              : 'Tap to start',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Paints a dashed circle: short arc segments separated by even gaps.
class _DashedRingPainter extends CustomPainter {
  final Color color;

  const _DashedRingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 3;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.75);
    const segments = 28;
    const gapFraction = 0.42; // part of each step left blank
    final step = 2 * math.pi / segments;
    for (var i = 0; i < segments; i++) {
      final start = i * step;
      canvas.drawArc(rect, start, step * (1 - gapFraction), false, paint);
    }
    // A faint full ring underneath so the dashes read as one circle.
    final faint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.18);
    canvas.drawCircle(center, radius, faint);
  }

  @override
  bool shouldRepaint(covariant _DashedRingPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Paints a comet-like sweep arc: one bright arc segment with a
/// fading trail behind it. Rotated by the connecting-state sweep
/// controller so it races around the button.
class _SweepArcPainter extends CustomPainter {
  final Color color;

  const _SweepArcPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 4;
    final rect = Rect.fromCircle(center: center, radius: radius);
    // Head arc plus two trailing arcs, each dimmer — the comet tail.
    const spans = [1.6, 0.9, 0.45];
    const alphas = [0.95, 0.45, 0.2];
    var start = -math.pi / 2 - 1.6;
    for (var i = 0; i < spans.length; i++) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = i == 0 ? 5 : 3.5
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: alphas[i]);
      canvas.drawArc(rect, start, spans[i], false, paint);
      start -= spans[i] + 0.12;
    }
  }

  @override
  bool shouldRepaint(covariant _SweepArcPainter oldDelegate) =>
      oldDelegate.color != color;
}
