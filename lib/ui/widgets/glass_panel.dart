import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

class BubbleBackground extends StatelessWidget {
  final String imagePath;
  final Widget child;

  const BubbleBackground({
    super.key,
    required this.imagePath,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = imagePath.isNotEmpty && File(imagePath).existsSync();

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasImage)
          Image.file(
            File(imagePath),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const _BubbleGradient(),
          )
        else
          const _BubbleGradient(),
        child,
      ],
    );
  }
}

class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadiusGeometry borderRadius;
  final double blur;
  final Color? color;
  final double opacity;

  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.blur = 18,
    this.color,
    this.opacity = 0.62,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalizedOpacity = opacity.clamp(0.0, 0.95).toDouble();
    final blurSigma = blur.clamp(0.0, 40.0).toDouble();
    final panelColor = color ??
        theme.colorScheme.surface.withValues(
          alpha: theme.brightness == Brightness.dark
              ? (normalizedOpacity * 0.68).clamp(0.0, 0.95).toDouble()
              : normalizedOpacity,
        );

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: panelColor,
            borderRadius: borderRadius,
            border: Border.all(
              color: Colors.white.withValues(
                alpha: (0.18 + normalizedOpacity * 0.38)
                    .clamp(0.12, 0.56)
                    .toDouble(),
              ),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: (0.04 + normalizedOpacity * 0.10)
                      .clamp(0.02, 0.14)
                      .toDouble(),
                ),
                blurRadius: 26,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class GlassAppBar extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final Widget? leading;
  final Widget? titleSuffix;
  final double opacity;
  final double blur;

  const GlassAppBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.leading,
    this.titleSuffix,
    this.opacity = 0.62,
    this.blur = 18,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: GlassPanel(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          opacity: opacity,
          blur: blur,
          child: MediaQuery.withNoTextScaling(
            child: Row(
              children: [
                if (leading != null) leading!,
                if (leading != null) const SizedBox(width: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (titleSuffix != null) const SizedBox(width: 4),
                        if (titleSuffix != null) titleSuffix!,
                      ],
                    ),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleGradient extends StatelessWidget {
  const _BubbleGradient();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFBFE8FF),
            Color(0xFFF7D8E8),
            Color(0xFFD9F2DD),
          ],
        ),
      ),
    );
  }
}
