import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../../../core/config/dev_flags.dart';
import '../../../core/utils/log_buffer.dart';
import '../../../models/shift.dart';
import '../../punch/services/geofence_scheduler.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  final _scrollCtrl = ScrollController();
  final _filterCtrl = TextEditingController();
  StreamSubscription? _sub;
  List<String> _lines = [];
  String _filter = '';
  bool _shouldAutoScroll = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _scrollCtrl.addListener(_onScroll);
    _sub = Stream.periodic(const Duration(milliseconds: 500)).listen((_) {
      if (mounted) _refresh();
    });
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final maxScroll = _scrollCtrl.position.maxScrollExtent;
    final currentScroll = _scrollCtrl.position.pixels;
    // User is near bottom (within 150px) → keep auto-scrolling
    _shouldAutoScroll = (maxScroll - currentScroll) <= 150;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    final all = LogBuffer.lines;
    final filtered = _filter.isEmpty
        ? all
        : all.where((l) => l.toLowerCase().contains(_filter.toLowerCase())).toList();
    if (mounted) {
      setState(() => _lines = filtered);
      if (_shouldAutoScroll) _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copyAll() {
    Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs copied to clipboard'), duration: Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!DevFlags.kDevMode) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.red),
            tooltip: 'Simulate Exit',
            onPressed: () {
              FlutterBackgroundService().invoke('simulate_exit');
              debugPrint('[GF_BG_UI] Simulate Exit triggered');
            },
          ),
          IconButton(
            icon: const Icon(Icons.timer, color: Colors.orange),
            tooltip: 'Schedule Test Alarm (+5m)',
            onPressed: () {
              final in5 = DateTime.now().add(const Duration(minutes: 5));
              final h = in5.hour.toString().padLeft(2, '0');
              final m = in5.minute.toString().padLeft(2, '0');
              final shift = Shift(
                id: 999,
                orgId: 1,
                name: 'TestAlarm',
                startTime: '$h:$m',
                endTime: '23:59',
                isOvernight: false,
                bufferMinutes: 0,
                minBreakMinutes: 30,
                isActive: true,
              );
              GeofenceScheduler.scheduleNextShift(shift);
              debugPrint('[GF_BG_UI] Test alarm scheduled for +5m ($h:$m)');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Test alarm: +5m ($h:$m) — kill app now')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all',
            onPressed: _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Clear',
            onPressed: () {
              LogBuffer.clear();
              setState(() => _lines = []);
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _filterCtrl,
              decoration: InputDecoration(
                hintText: 'Filter logs…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _filter.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _filterCtrl.clear();
                          setState(() => _filter = '');
                          _refresh();
                        },
                      )
                    : null,
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) {
                setState(() => _filter = v);
                _refresh();
              },
            ),
          ),
        ),
      ),
      body: _lines.isEmpty
          ? const Center(child: Text('No logs yet'))
          : ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemCount: _lines.length,
              itemBuilder: (ctx, i) {
                final line = _lines[i];
                Color? color;
                if (line.contains('SUCCESS') || line.contains('Punching') || line.contains('punched in')) {
                  color = Colors.green.shade300;
                } else if (line.contains('GATE FAIL') || line.contains('FAIL') || line.contains('error') || line.contains('Error')) {
                  color = Colors.red.shade300;
                } else if (line.contains('_isEnabled')) {
                  color = Colors.orange.shade200;
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      height: 1.3,
                      color: color ?? (theme.brightness == Brightness.dark ? Colors.grey.shade300 : Colors.grey.shade800),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
