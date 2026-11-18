import 'dart:async';

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
    this.gradient = AppTheme.emberGradient,
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
          // On the gradient circle — always white (see onAccent).
          color: AppTheme.onAccent,
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

/// Level + XP rank card: the level badge, warrior rank name, current XP
/// and progress to the next level.
///
/// Shown on the Profile screen (own profile) and on other users'
/// profiles, and as a line on leaderboard rows — NOT on Home or
/// Dashboard (18 Nov 2026: the level bar was moved off the top of Home
/// so the home screen is about today's battles, not the score).
class XpBar extends StatelessWidget {
  const XpBar({super.key, required this.xp});

  final int xp;

  @override
  Widget build(BuildContext context) {
    final level = levelForXp(xp);
    final rank = rankNameForLevel(level);
    final progress = progressToNextLevel(xp);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
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
                      color: AppTheme.ember.withValues(alpha: 0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // On the violet badge gradient — always white.
                    Icon(Icons.shield, color: AppTheme.onAccent, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      'LEVEL $level',
                      style: TextStyle(
                        color: AppTheme.onAccent,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Warrior rank — the title for this level band.
              Text(
                rank.toUpperCase(),
                style: const TextStyle(
                  color: AppTheme.ember,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              const Icon(Icons.bolt, color: AppTheme.ember, size: 20),
              const SizedBox(width: 4),
              CountUp(
                value: xp,
                suffix: ' XP',
                style: TextStyle(
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
                backgroundColor: AppTheme.cardBorder,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppTheme.ember,
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
            style: TextStyle(
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
                    color: AppTheme.ember,
                    showTitle: false,
                    radius: size * 0.11,
                  ),
                  PieChartSectionData(
                    value: (100 - value * 100).clamp(0.0, 100.0),
                    color: AppTheme.cardBorder,
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
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              Text(
                centerLabel ?? 'this month',
                style: TextStyle(
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
              child: Icon(icon, color: AppTheme.ink, size: 44),
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
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 15),
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
                  ? const LoadingIcon(size: 22)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, color: AppTheme.onAccent, size: 20),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          label,
                          style: TextStyle(
                            color: AppTheme.onAccent,
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

/// The app's own icon (hourglass + rising sun) used for loading
/// states (v2.10.0): wherever the app shows a generic "loading"
/// spinner, it shows this icon instead, with a gentle pulse so
/// something is visibly happening. NOT used for determinate progress
/// bars (level / challenge / day progress keep their bars). If the
/// asset cannot load (e.g. a test without the bundle), it falls back
/// to the shield mark instead of an error box.
/// The app's own icon as a loading visual (v2.10.0): wherever the app
/// shows a loading state, the hourglass + rising-sun icon is the
/// visual — not a generic Flutter spinner. It pulses gently (scale
/// 1.00 → 1.06, 900 ms, ease in-out, reversing) so the user can see
/// something is happening. A plain [AnimationController] (not
/// flutter_animate): flutter_animate schedules a `Future.delayed`
/// timer on init that is not cancelled on dispose, which leaves a
/// pending timer in widget tests when the icon is shown only briefly
/// (e.g. the "Deleting your account…" dialog). If the icon asset is
/// missing, the shield mark on the violet gradient is the fallback.
class LoadingIcon extends StatefulWidget {
  const LoadingIcon({super.key, this.size = 64});

  /// The icon's side in logical pixels.
  final double size;

  @override
  State<LoadingIcon> createState() => _LoadingIconState();
}

class _LoadingIconState extends State<LoadingIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return ScaleTransition(
      scale: _scale,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.asset(
          'assets/app-icon-source.jpg',
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, _, _) => Container(
            width: size,
            height: size,
            decoration: BoxDecoration(gradient: AppTheme.heroGradient),
            child: Icon(
              Icons.shield,
              color: AppTheme.onAccent,
              size: size * 0.55,
            ),
          ),
        ),
      ),
    );
  }
}

/// Branded loading screen: the app icon, app name and the loading
/// message on the dark background. Used while the session/profile is
/// being checked so the user never sees a blank page or a bare
/// spinner (fast-load work, 18 Nov 2026). The web page
/// (web/index.html) shows the same screen instantly, before Flutter
/// even starts. v2.10.0: the shield mark is replaced by the app's
/// own icon (with its gentle pulse); the indeterminate bar is gone —
/// the pulsing icon is the loading visual.
class WarriorSplash extends StatelessWidget {
  const WarriorSplash({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.ember.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const LoadingIcon(size: 84),
            ),
            const SizedBox(height: 20),
            Text(
              'LIFE GAME',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: 4,
                color: AppTheme.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message ?? 'Loading…',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shimmer placeholder shown while a screen's data loads, so the
/// screen shell renders immediately instead of a blocking spinner
/// (fast-load work, 18 Nov 2026).
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 16,
    this.borderRadius = 10,
  });

  final double? width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: AppTheme.cardBorder),
      ),
    )
        .animate(onPlay: (c) => c.repeat())
        .shimmer(
          duration: 1400.ms,
          color: AppTheme.ink.withValues(alpha: 0.06),
        );
  }
}

/// The check button: the circular tick button on a habit/task tile.
///
/// - Tapping it toggles the item; when it turns done, the circle pops
///   with a glow and a floating "+2 XP" rises and fades.
/// - Unticking shows NO floating delta: there is no negative marking
///   (18 Nov 2026) — the item is simply worth 0 while blank, so the
///   tile just returns to its pending state and the XP total updates.
/// - The floating delta is driven by [done] flips, so it works with
///   optimistic updates too.
class BattleCheck extends StatefulWidget {
  const BattleCheck({super.key, required this.done, this.size = 34});

  final bool done;
  final double size;

  @override
  State<BattleCheck> createState() => _BattleCheckState();
}

class _BattleCheckState extends State<BattleCheck> {
  int? _delta;
  Timer? _timer;

  @override
  void didUpdateWidget(BattleCheck oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only completions show a floating delta (+2 XP). Unticking shows
    // nothing — no negative marking (18 Nov 2026).
    if (oldWidget.done != widget.done && widget.done) {
      _timer?.cancel();
      setState(() => _delta = xpPerTask);
      _timer = Timer(const Duration(milliseconds: 1100), () {
        if (mounted) setState(() => _delta = null);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: widget.done ? AppTheme.emberGradient : null,
            color: widget.done ? null : AppTheme.card,
            border: widget.done
                ? null
                : Border.all(color: AppTheme.cardBorder, width: 2),
            // The shadow list always has exactly one entry: when the
            // item is not done it is fully transparent. If the list
            // went from 1 entry to null, the AnimatedContainer's
            // easeOutBack overshoot (t > 1) would scale the shadow's
            // blurRadius by a negative factor and trip a framework
            // assertion in BoxShadow.lerpList (rapid tick/untick,
            // 18 Nov 2026).
            boxShadow: [
              BoxShadow(
                color: widget.done
                    ? AppTheme.ember.withValues(alpha: 0.55)
                    : Colors.transparent,
                blurRadius: 12,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: widget.done
              // On the violet gradient when done — always white.
              ? Icon(Icons.check, color: AppTheme.onAccent, size: widget.size * 0.6)
                  .animate(key: ValueKey('check-${widget.done}'))
                  .scale(
                    begin: const Offset(0.4, 0.4),
                    end: const Offset(1, 1),
                    duration: 250.ms,
                    curve: Curves.easeOutBack,
                  )
              : null,
        ),
        if (_delta != null)
          Positioned(
            top: -22,
            right: -6,
            child: Text(
              '+${_delta!} XP',
              style: const TextStyle(
                color: AppTheme.gold,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            )
                .animate()
                .slideY(begin: 0.5, end: -0.4, duration: 900.ms)
                .fadeOut(delay: 500.ms, duration: 400.ms),
          ),
      ],
    );
  }
}

/// A gold slash that sweeps across a habit/task tile when the item is
/// completed — the "strike" of the battle. The tile wraps its content
/// in a Stack and puts this last; the parent bumps [strikeKey] on every
/// completion so the sweep replays (flutter_animate restarts when the
/// key changes). [strikeKey] 0 means "never completed yet" — no slash.
class StrikeOverlay extends StatelessWidget {
  const StrikeOverlay({super.key, required this.strikeKey});

  final int strikeKey;

  @override
  Widget build(BuildContext context) {
    if (strikeKey <= 0) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Container(
                alignment: Alignment.centerLeft,
                child: Transform.rotate(
                  angle: -0.4,
                  child: Container(
                    width: 6,
                    height: constraints.maxHeight * 3,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppTheme.gold.withValues(alpha: 0),
                          AppTheme.gold,
                          AppTheme.gold.withValues(alpha: 0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ),
              )
                  .animate(key: ValueKey(strikeKey))
                  .slideX(
                    begin: -0.15,
                    end: 1.15,
                    duration: 480.ms,
                    curve: Curves.easeOutCubic,
                  );
            },
          ),
        ),
      ),
    );
  }
}

/// Screen transition for pushed screens: a quick fade + small slide,
/// so navigation feels like moving through the battlefield rather than
/// a hard cut (UI polish, 18 Nov 2026).
class WarriorPageRoute<T> extends PageRouteBuilder<T> {
  WarriorPageRoute({required WidgetBuilder builder})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final slide =
              Tween<Offset>(
                begin: const Offset(0.04, 0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              );
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: slide, child: child),
          );
        },
        transitionDuration: const Duration(milliseconds: 220),
      );
}
