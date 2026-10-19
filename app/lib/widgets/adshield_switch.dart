import 'package:flutter/material.dart';

import '../core/theme.dart';

/// The AdShield on/off switch: a custom animated toggle.
///
/// - Sliding knob ([AnimatedAlign], with a springy curve so the knob
///   bounces slightly as it lands).
/// - Track colour morphs grey -> green ([AnimatedContainer]).
/// - Scale bounce on tap (a short press animation, disposed with the
///   widget).
/// - Subtle green glow while ON.
class AdShieldSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  /// When false the switch is dimmed and ignores taps (used on
  /// platforms where AdShield is unavailable).
  final bool enabled;

  const AdShieldSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<AdShieldSwitch> createState() => _AdShieldSwitchState();
}

class _AdShieldSwitchState extends State<AdShieldSwitch>
    with SingleTickerProviderStateMixin {
  static const double _trackWidth = 58;
  static const double _trackHeight = 33;
  static const double _knobSize = 25;

  late final AnimationController _press;
  late final Animation<double> _pressScale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _pressScale = Tween<double>(begin: 1.0, end: 0.86).animate(
      CurvedAnimation(
        parent: _press,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeOut,
      ),
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!widget.enabled) return;
    // Bounce: shrink fast, spring back; the value flips underneath.
    _press.forward().then((_) {
      if (mounted) _press.reverse();
    });
    widget.onChanged(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.value;
    return Opacity(
      opacity: widget.enabled ? 1.0 : 0.45,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: ScaleTransition(
          scale: _pressScale,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeInOut,
            width: _trackWidth,
            height: _trackHeight,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: on ? ChakraTheme.emerald : Colors.white24,
              border: Border.all(
                color: on
                    ? ChakraTheme.emerald.withValues(alpha: 0.9)
                    : Colors.white24,
              ),
              boxShadow: on
                  ? [
                      BoxShadow(
                        color:
                            ChakraTheme.emerald.withValues(alpha: 0.45),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 260),
              curve: Curves.elasticOut,
              alignment:
                  on ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: _knobSize,
                height: _knobSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  on ? Icons.shield : Icons.shield_outlined,
                  size: 14,
                  color: on ? ChakraTheme.emerald : Colors.black45,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
