import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/theme/app_colors.dart';

/// Shows the punch success/error confirmation bottom sheet.
/// Auto-dismisses after [autoDismiss] if provided.
void showConfirmSheet(
  BuildContext context, {
  required bool success,
  required String title,
  String? subtitle,
  String? detail,
  Duration? autoDismiss = const Duration(seconds: 3),
  VoidCallback? onRetry,
}) {
  success ? HapticFeedback.heavyImpact() : HapticFeedback.vibrate();
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _ConfirmSheet(
      success: success,
      title: title,
      subtitle: subtitle,
      detail: detail,
      autoDismiss: autoDismiss,
      onRetry: onRetry,
    ),
  );
}

class _ConfirmSheet extends StatefulWidget {
  const _ConfirmSheet({
    required this.success,
    required this.title,
    this.subtitle,
    this.detail,
    this.autoDismiss,
    this.onRetry,
  });

  final bool success;
  final String title;
  final String? subtitle;
  final String? detail;
  final Duration? autoDismiss;
  final VoidCallback? onRetry;

  @override
  State<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<_ConfirmSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _fade  = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();

    if (widget.autoDismiss != null) {
      Future.delayed(widget.autoDismiss!, () {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.success ? AppColors.success : AppColors.error;
    final bg    = widget.success ? AppColors.successSubtle : AppColors.errorSubtle;
    final icon  = widget.success ? Icons.check_rounded : Icons.close_rounded;

    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
        child: FadeTransition(
          opacity: _fade,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: _scale,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                  child: Icon(icon, size: 40, color: color),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                widget.title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              if (widget.subtitle != null) ...[
                const SizedBox(height: 8),
                Text(
                  widget.subtitle!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
              if (widget.detail != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.detail!,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              if (!widget.success && widget.onRetry != null)
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onRetry!();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
                  child: const Text('Try Again'),
                )
              else
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
