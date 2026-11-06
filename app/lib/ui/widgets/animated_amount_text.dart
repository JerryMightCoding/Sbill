import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/ledger_models.dart';
import '../theme/app_theme.dart';

/// Smoothly interpolates between previous and current integer minor-unit amounts
/// using `TweenAnimationBuilder` and tabular figures so digits never jitter horizontally.
class AnimatedAmountText extends StatefulWidget {
  const AnimatedAmountText({
    super.key,
    required this.amountMinor,
    required this.currency,
    this.decimals = 2,
    this.showPlus = false,
    this.style,
  });

  final int amountMinor;
  final String currency;
  final int decimals;
  final bool showPlus;
  final TextStyle? style;

  @override
  State<AnimatedAmountText> createState() => _AnimatedAmountTextState();
}

class _AnimatedAmountTextState extends State<AnimatedAmountText> {
  late int _oldValue;

  @override
  void initState() {
    super.initState();
    _oldValue = widget.amountMinor;
  }

  @override
  void didUpdateWidget(covariant AnimatedAmountText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.amountMinor != widget.amountMinor) {
      _oldValue = oldWidget.amountMinor;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(
        begin: _oldValue.toDouble(),
        end: widget.amountMinor.toDouble(),
      ),
      duration: AppTheme.mediumAnim,
      curve: AppTheme.smoothCurve,
      builder: (context, value, _) {
        final interpolatedMinor = value == widget.amountMinor.toDouble()
            ? widget.amountMinor
            : value.round();
        final formatted = MoneyFormatter.formatMinor(
          interpolatedMinor,
          widget.currency,
          decimals: widget.decimals,
          showPlus: widget.showPlus,
        );
        final baseStyle = widget.style ?? DefaultTextStyle.of(context).style;
        return Text(
          formatted,
          style: baseStyle.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}

/// Tactile press-scale card wrapper that gently scales down to 0.985 on press
/// and springs back with `Curves.easeOutCubic`, giving lists a fluid, physical feel.
class PressableScaleCard extends StatefulWidget {
  const PressableScaleCard({
    super.key,
    required this.child,
    this.onTap,
    this.margin = const EdgeInsets.only(bottom: 12),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  @override
  State<PressableScaleCard> createState() => _PressableScaleCardState();
}

class _PressableScaleCardState extends State<PressableScaleCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.margin,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap != null
            ? (_) => setState(() => _pressed = true)
            : null,
        onTapUp: widget.onTap != null
            ? (_) => setState(() => _pressed = false)
            : null,
        onTapCancel: widget.onTap != null
            ? () => setState(() => _pressed = false)
            : null,
        onTap: widget.onTap != null
            ? () {
                HapticFeedback.selectionClick();
                widget.onTap!();
              }
            : null,
        child: AnimatedScale(
          scale: _pressed ? 0.984 : 1.0,
          duration: AppTheme.microAnim,
          curve: AppTheme.smoothCurve,
          child: Card(child: widget.child),
        ),
      ),
    );
  }
}

/// Smoothly transitions between child views with a subtle horizontal slide + fade.
class SmoothTabTransition extends StatelessWidget {
  const SmoothTabTransition({
    super.key,
    required this.currentIndex,
    required this.child,
  });

  final int currentIndex;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppTheme.fastAnim,
      switchInCurve: AppTheme.smoothCurve,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (widget, animation) {
        final offsetAnim = Tween<Offset>(
          begin: const Offset(0.025, 0),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offsetAnim, child: widget),
        );
      },
      child: KeyedSubtree(
        key: ValueKey<int>(currentIndex),
        child: child,
      ),
    );
  }
}
