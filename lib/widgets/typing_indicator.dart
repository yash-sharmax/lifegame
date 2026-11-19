import 'package:flutter/material.dart';

/// Animated 3-dot typing indicator (v2.11.5): three dots that rise
/// and fade in turn, WhatsApp-style. Pure animation — no network,
/// no state. Shown in the typing row above the composer, next to
/// the "X is typing…" label.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color, this.size = 7});

  final Color? color;

  /// Diameter of one dot.
  final double size;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      height: widget.size * 2,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          // Each dot runs the same cycle, offset by a third, so
          // they rise in sequence.
          final start = i * 0.22;
          final bounce = Tween<double>(begin: 0, end: -widget.size * 0.7)
              .animate(
                CurvedAnimation(
                  parent: _controller,
                  curve: Interval(start, start + 0.45, curve: Curves.easeOut),
                ),
              );
          final fade = Tween<double>(begin: 0.35, end: 1).animate(
            CurvedAnimation(
              parent: _controller,
              curve: Interval(start, start + 0.45, curve: Curves.easeIn),
            ),
          );
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Padding(
              padding: EdgeInsets.only(right: i == 2 ? 0 : widget.size * 0.6),
              child: Opacity(
                opacity: fade.value,
                child: Transform.translate(
                  offset: Offset(0, bounce.value),
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
