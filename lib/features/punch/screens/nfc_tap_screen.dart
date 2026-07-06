import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../services/nfc_service.dart';
import '../../dashboard/providers/dashboard_providers.dart';

// ── State machine ─────────────────────────────────────────────────────────────

enum _NfcState { waiting, submitting, unavailable, error }

// ── Screen ────────────────────────────────────────────────────────────────────

class NfcTapScreen extends ConsumerStatefulWidget {
  final String direction;

  const NfcTapScreen({super.key, required this.direction});

  @override
  ConsumerState<NfcTapScreen> createState() => _NfcTapScreenState();
}

class _NfcTapScreenState extends ConsumerState<NfcTapScreen>
    with SingleTickerProviderStateMixin {
  late final NfcService _nfcService;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  _NfcState _state = _NfcState.waiting;
  String? _errorMessage;

  // Guard against double-submission if tag is held continuously.
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _nfcService = NfcService();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _startSession();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _nfcService.stopSession(); // fire-and-forget cleanup
    super.dispose();
  }

  Future<void> _startSession() async {
    if (!mounted) return;

    final available = await _nfcService.isAvailable();
    if (!mounted) return;

    if (!available) {
      setState(() => _state = _NfcState.unavailable);
      return;
    }

    _isProcessing = false;
    setState(() {
      _state = _NfcState.waiting;
      _errorMessage = null;
    });

    await _nfcService.startSession(
      onTagRead: (tagId) => _onTagDetected(tagId),
      onError: (msg) => _onTagError(msg),
    );
  }

  void _onTagDetected(String tagId) {
    if (_isProcessing || !mounted) return;
    HapticFeedback.mediumImpact();
    _isProcessing = true;
    _submitPunch(tagId);
  }

  void _onTagError(String msg) {
    if (!mounted) return;
    setState(() {
      _state = _NfcState.error;
      _errorMessage = msg;
    });
    _nfcService.stopSession();
  }

  Future<void> _submitPunch(String tagId) async {
    if (!mounted) return;
    setState(() => _state = _NfcState.submitting);

    // Stop session before API call so the NFC sheet dismisses (iOS).
    await _nfcService.stopSession(iosAlertMessage: 'Tag read — recording punch…');

    final result = await ref.read(punchProvider.notifier).punch(
      'NFC',
      extras: {
        'nfcTagId': tagId,
        'direction': widget.direction,
      },
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            result.message ?? (result.success ? 'Punch recorded!' : 'Punch failed')),
        backgroundColor:
            result.success ? AppColors.success : AppColors.error,
      ),
    );

    if (result.success) {
      Navigator.pop(context);
    } else {
      setState(() {
        _state = _NfcState.error;
        _errorMessage = result.message ?? 'Server rejected this NFC tag.';
      });
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWaiting = _state == _NfcState.waiting;

    return Scaffold(
      appBar: AppBar(
        title: Text('NFC ${_dirLabel(widget.direction)}'),
        leading: const CloseButton(),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),

              // Animated icon
              ScaleTransition(
                scale: isWaiting
                    ? _pulseAnim
                    : const AlwaysStoppedAnimation(1.0),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Outer ripple ring (visible only while waiting)
                    if (isWaiting)
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (_, _) => Container(
                          width: 160,
                          height: 160,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.colorScheme.primary
                                .withAlpha(
                                    (20 * (1 - _pulseController.value)).round()),
                          ),
                        ),
                      ),
                    // Inner circle + icon
                    Container(
                      width: 110,
                      height: 110,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _iconColor(theme).withAlpha(25),
                      ),
                      child: _state == _NfcState.submitting
                          ? Padding(
                              padding: const EdgeInsets.all(30),
                              child: CircularProgressIndicator(
                                color: theme.colorScheme.primary,
                                strokeWidth: 3,
                              ),
                            )
                          : Icon(_stateIcon, size: 58, color: _iconColor(theme)),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // Title
              Text(
                _stateTitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),

              // Subtitle / error
              Text(
                _errorMessage ?? _stateSubtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _state == _NfcState.error
                      ? theme.colorScheme.error
                      : AppColors.textSecondary,
                ),
              ),

              const Spacer(),

              // Action buttons
              ..._buildButtons(theme),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildButtons(ThemeData theme) {
    switch (_state) {
      case _NfcState.error:
        return [
          ElevatedButton.icon(
            onPressed: _startSession,
            icon: const Icon(Icons.refresh),
            label: const Text('Try Again'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ];

      case _NfcState.unavailable:
        return [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Go Back'),
          ),
        ];

      // waiting / submitting: no buttons — action happens via tap
      default:
        return [];
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  IconData get _stateIcon => switch (_state) {
        _NfcState.waiting => Icons.nfc,
        _NfcState.submitting => Icons.nfc,
        _NfcState.unavailable => Icons.nfc_outlined,
        _NfcState.error => Icons.warning_amber_rounded,
      };

  String get _stateTitle => switch (_state) {
        _NfcState.waiting => 'Ready to Tap',
        _NfcState.submitting => 'Recording Punch…',
        _NfcState.unavailable => 'NFC Not Available',
        _NfcState.error => 'Tap Failed',
      };

  String get _stateSubtitle => switch (_state) {
        _NfcState.waiting =>
          'Hold the back of your phone\nagainst the NFC tag',
        _NfcState.submitting =>
          'Tag read — verifying with server',
        _NfcState.unavailable =>
          'NFC is not available or is disabled on this device.',
        _NfcState.error => '',
      };

  Color _iconColor(ThemeData theme) => switch (_state) {
        _NfcState.unavailable => AppColors.textSecondary,
        _NfcState.error => theme.colorScheme.error,
        _NfcState.submitting => AppColors.success,
        _ => theme.colorScheme.primary,
      };

  String _dirLabel(String dir) => switch (dir) {
        'In' => 'Punch In',
        'Out' => 'Punch Out',
        'BreakStart' => 'Break Start',
        'BreakEnd' => 'Break End',
        _ => dir,
      };
}
