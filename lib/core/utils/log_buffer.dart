import 'dart:collection';
import 'package:flutter/foundation.dart';

class LogBuffer {
  LogBuffer._();

  static const int _maxLines = 2000;
  static final Queue<String> _lines = Queue();
  static final List<void Function(String)> _listeners = [];

  static void log(String message) {
    final ts = DateTime.now().toString().substring(11, 23);
    final line = '[$ts] $message';
    _lines.add(line);
    if (_lines.length > _maxLines) _lines.removeFirst();
    for (final cb in _listeners) cb(line);
  }

  static List<String> get lines => _lines.toList();

  static void clear() => _lines.clear();

  static void addListener(void Function(String) cb) {
    _listeners.add(cb);
  }

  static void removeListener(void Function(String) cb) {
    _listeners.remove(cb);
  }
}

void debugPrintWithBuffer(String? message, {int? wrapWidth}) {
  if (message != null) LogBuffer.log(message);
  debugPrintThrottled(message, wrapWidth: wrapWidth);
}
