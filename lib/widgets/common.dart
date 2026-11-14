import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../theme.dart';

/// Gradient circle avatar showing the user's initials.
class AvatarCircle extends StatelessWidget {
  const AvatarCircle({
    super.key,
    required this.initials,
    this.size = 56,
    this.gradient = AppTheme.violetGradient,
    this.fontSize,
  });

  final String initials;
  final double size;
  final Gradient gradient;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, gradient: gradient),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: fontSize ?? size * 0.36,
        ),
      ),
    );
  }
}

/// Animated number that counts up (or down) when [value] changes.
class CountUp extends StatelessWidget {
  const CountUp({
    super.key,
    required this.value,
    this.style,
    this.suffix = '',
    this.duration = const Duration(milliseconds: 700),
  });

  final int value;
  final TextStyle? style;
  final String suffix;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.toDouble()),
      duration: duration,
      builder: (context, animated, _) => Text(
        '${animated.round()}$suffix',
        style: style,
      ),
    );
  }
}

/// XP progress bar to the next level, with a level badge.
class XpBar extends StatelessWidget {
  const XpBar({super.key, required this.xp});

  final int xp;

  @override
  Widget build(BuildContext context) {
    final level = xp ~/ 100 + 1;
    final progress = (xp % 100) / 100;
    final toNext = 100 - (xp % 100);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppTheme.violetGradient,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'LEVEL $level',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
              const Spacer(),
              const Icon(Icons.bolt, color: Colors.white, size: 20),
              const SizedBox(width: 4),
              CountUp(
                value: xp,
                suffix: ' XP',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: progress),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 10,
                backgroundColor: Colors.white.withValues(alpha: 0.25),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppTheme.amber,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$toNext XP to Level ${level + 1}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Monthly progress ring with the % in the centre.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.fraction,
    this.size = 170,
    this.centerLabel,
  });

  final double fraction;
  final double size;
  final String? centerLabel;

  @override
  Widget build(BuildContext context) {
    final pct = (fraction.clamp(0.0, 1.0) * 100);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: fraction.clamp(0.0, 1.0)),
            duration: const Duration(milliseconds: 1100),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => PieChart(
              PieChartData(
                startDegreeOffset: -90,
                sectionsSpace: 0,
                centerSpaceRadius: size * 0.34,
                sections: [
                  PieChartSectionData(
                    value: (value * 100).clamp(0.0, 100.0),
                    color: AppTheme.violet,
                    showTitle: false,
                    radius: size * 0.11,
                  ),
                  PieChartSectionData(
                    value: (100 - value * 100).clamp(0.0, 100.0),
                    color: const Color(0xFFE8E4F5),
                    showTitle: false,
                    radius: size * 0.11,
                  ),
                ],
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: pct),
                duration: const Duration(milliseconds: 1100),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => Text(
                  '${value.toStringAsFixed(1)}%',
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              Text(
                centerLabel ?? 'this month',
                style: const TextStyle(
                  color: AppTheme.inkSoft,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Friendly empty state with a call to action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                gradient: AppTheme.heroGradient,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: 44),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.inkSoft, fontSize: 15),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add, size: 20),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    ).animate().fadeIn(duration: 400.ms).scale(begin: const Offset(0.95, 0.95));
  }
}

/// A gradient button used for primary actions in auth screens.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.gradient = AppTheme.heroGradient,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Gradient gradient;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      // Ink paints its gradient on the nearest Material. Without this
      // transparent Material the gradient would land on the Scaffold's
      // Material *behind* the white card and the button would be invisible.
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: loading ? null : onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Continue with Google" button.
class GoogleButton extends StatelessWidget {
  const GoogleButton({super.key, required this.onPressed, this.loading = false});

  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: loading ? null : onPressed,
        icon: const Text(
          'G',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Color(0xFF4285F4),
          ),
        ),
        label: const Text('Continue with Google'),
      ),
    );
  }
}
