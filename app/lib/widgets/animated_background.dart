import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Ambient animated background: two large, soft colour orbs (violet and
/// cyan) drifting slowly behind the content, plus an emerald orb that
/// fades in while the VPN is connected.
///
/// The orbs are plain radial-gradient circles moved with [Transform],
/// so the animation only repaints - it never triggers layout - and the
/// whole orb layer sits inside a [RepaintBoundary].
class AnimatedBackground extends StatefulWidget {
  final bool connected;
  final Widget child;

  const AnimatedBackground({
    super.key,
    required this.connected,
    required this.child,
  });

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift;

  @override
  void initState() {
    super.initState();
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  Widget _orb({
    required double size,
    required Color color,
    required double maxAlpha,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: maxAlpha),
            color.withValues(alpha: maxAlpha * 0.45),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ChakraTheme.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _drift,
              builder: (context, _) {
                // Ease the raw controller value so the drift feels like
                // a slow breath rather than a mechanical slide.
                final t = Curves.easeInOut.transform(_drift.value);
                final dx = (t - 0.5) * 40; // +/- 20 px
                final dy = (t - 0.5) * 28; // +/- 14 px
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // Violet orb, top-left, drifts one way.
                    Positioned(
                      left: -110 + dx,
                      top: -130 + dy,
                      child: _orb(
                        size: 340,
                        color: ChakraTheme.violet,
                        maxAlpha: 0.34,
                      ),
                    ),
                    // Cyan orb, bottom-right, drifts the opposite way.
                    Positioned(
                      right: -120 - dx,
                      bottom: -140 - dy,
                      child: _orb(
                        size: 360,
                        color: ChakraTheme.cyan,
                        maxAlpha: 0.26,
                      ),
                    ),
                    // Emerald orb, centre-right: only visible while
                    // connected, so the whole scene warms up on connect.
                    Positioned(
                      right: -60 + dx * 0.5,
                      top: 180 - dy,
                      child: AnimatedOpacity(
                        opacity: widget.connected ? 1 : 0,
                        duration: const Duration(milliseconds: 900),
                        curve: Curves.easeInOut,
                        child: _orb(
                          size: 280,
                          color: ChakraTheme.emerald,
                          maxAlpha: 0.30,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}
