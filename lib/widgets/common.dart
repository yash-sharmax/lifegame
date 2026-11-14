import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../logic/xp.dart';
import '../theme.dart';

/// Desktop breakpoint: screens 600px and wider use the desktop layout
/// (centred content, multi-column sections, side navigation) instead of
/// the phone-like bottom-nav layout.
const double kDesktopBreakpoint = 600;

/// True when the current screen is wide enough for the desktop layout.
bool isWideScreen(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;

/// Centres [child] with a maximum width on wide screens so content uses
/// the computer screen instead of stretching edge to edge, while phones
/// (<600px) get the full width unchanged.
class ResponsiveCenter extends StatelessWidget {
  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = 1080,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!isWideScreen(context)) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

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
      builder: (context, animated, _) =>
          Text('${animated.round()}$suffix', style: style),
    );
  }
}

/// Level + XP header strip: the level badge, current XP and progress to
/// the next level, shown at the top of Home, Dashboard and Profile.
///
/// Deliberately a light, quiet strip — not a big gradient banner. The
/// old full-width violet card read like a popup stuck to the top of the
/// screen (user feedback, 14 Nov 2026), so the level now lives in the
/// header itself: a gradient level badge, the XP count and a slim
/// progress bar, on a white card that blends with the rest of the UI.
class XpBar extends StatelessWidget {
  const XpBar({super.key, required this.xp});

  final int xp;

  @override
  Widget build(BuildContext context) {
    final level = levelForXp(xp);
    final progress = progressToNextLevel(xp);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFEDEAF5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // The level badge is the most prominent element here.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  gradient: AppTheme.heroGradient,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.violet.withValues(alpha: 0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star, color: Colors.white, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      'LEVEL $level',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              const Icon(Icons.bolt, color: AppTheme.violet, size: 20),
              const SizedBox(width: 4),
              CountUp(
                value: xp,
                suffix: ' XP',
                style: const TextStyle(
                  color: AppTheme.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: progress),
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 8,
                backgroundColor: const Color(0xFFEDEAF5),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppTheme.violet,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // "X / 100 XP to Level N": how much of this level is done and
          // how much is left — the user could not tell from the old
          // "N XP to Level" caption alone (feedback, 14 Nov 2026).
          Text(
            '${xp % xpPerLevel} / $xpPerLevel XP to Level ${level + 1}',
            style: const TextStyle(
              color: AppTheme.inkSoft,
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
  const GoogleButton({
    super.key,
    required this.onPressed,
    this.loading = false,
  });

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
