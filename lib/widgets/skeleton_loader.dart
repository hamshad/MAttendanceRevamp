import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Shimmer skeleton wrappers for each screen's loading state.
class SkeletonLoader extends StatelessWidget {
  const SkeletonLoader({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor:      isDark ? const Color(0xFF2D3748) : const Color(0xFFE2E8F0),
      highlightColor: isDark ? const Color(0xFF4A5568) : const Color(0xFFF8FAFC),
      child: child,
    );
  }
}

/// Rounded rectangle placeholder block.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height = 16, this.radius = 8});
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width:  width,
        height: height,
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}

/// Skeleton for a generic card (used on home, payslip, leave list).
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key, this.height = 100});
  final double height;

  @override
  Widget build(BuildContext context) => SkeletonLoader(
        child: Container(
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color:        Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
}

/// Skeleton for the home screen content.
class HomeScreenSkeleton extends StatelessWidget {
  const HomeScreenSkeleton({super.key});

  @override
  Widget build(BuildContext context) => SkeletonLoader(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SkeletonBox(width: 160, height: 20),
              const SizedBox(height: 4),
              const SkeletonBox(width: 120, height: 14),
              const SizedBox(height: 16),
              // Status card
              Container(
                height: 120,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              ),
              const SizedBox(height: 12),
              // Punch card
              Container(
                height: 80,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              ),
              const SizedBox(height: 16),
              const SkeletonBox(width: 100, height: 14),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Container(height: 72, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)))),
                  const SizedBox(width: 8),
                  Expanded(child: Container(height: 72, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)))),
                  const SizedBox(width: 8),
                  Expanded(child: Container(height: 72, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)))),
                ],
              ),
            ],
          ),
        ),
      );
}

/// Skeleton for a list of 3 cards (leave, regularization, payslip, notifications).
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.itemCount = 3, this.itemHeight = 88});
  final int itemCount;
  final double itemHeight;

  @override
  Widget build(BuildContext context) => Column(
        children: List.generate(
          itemCount,
          (_) => SkeletonCard(height: itemHeight),
        ),
      );
}

/// Skeleton for the 7×6 attendance calendar.
class CalendarSkeleton extends StatelessWidget {
  const CalendarSkeleton({super.key});

  @override
  Widget build(BuildContext context) => SkeletonLoader(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: List.generate(
              6,
              (_) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: List.generate(
                    7,
                    (_) => Expanded(
                      child: Container(
                        height: 52,
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
