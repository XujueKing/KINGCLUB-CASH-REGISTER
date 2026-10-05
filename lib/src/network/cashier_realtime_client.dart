import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../auth/staff_session.dart';
import 'cashier_socket.dart';
import 'ccsop_crypto.dart';
import 'ccsop_realtime_codec.dart';

enum CashierRealtimeState { offline, connecting, connected }

/// One immutable employee session. A new session requires a new owner/codec.
class CashierRealtimeClient extends ChangeNotifier {
  CashierRealtimeClient(
    this.session, {
    Future<CashierSocket> Function(Uri)? connect,
    DateTime Function()? now,
  }) : _connectSocket = connect ?? IoCashierSocket.connect,
       _now = now ?? DateTime.now;
  final StaffSession session;
  final Future<CashierSocket> Function(Uri) _connectSocket;
  final DateTime Function() _now;
  CashierSocket? _socket;
  CcsopRealtimeCodec? _codec;
  StreamSubscription<Object?>? _subscription;
  Timer? _retry, _heartbeat, _deadline;
  bool _active = false, _disposed = false, _dialing = false, _pingBusy = false;
  int _epoch = 0, _attempt = 0, _pending = 0, _sequence = 0, _revision = 0;
  Future<void> _inbound = Future.value();
  DateTime? _lastPong;
  CashierRealtimeState _state = CashierRealtimeState.offline;
  CashierRealtimeState get state => _state;
  int get revision => _revision;
  String? lastTopic;
  bool _current(int epoch) => !_disposed && _active && epoch == _epoch;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_disposed || _active) return;
    _active = true;
    unawaited(_open());
  }

  Future<void> _open() async {
    if (!_active || _disposed || _dialing || _socket != null) return;
    if (!session.expiresAt.isAfter(_now())) {
      stop();
      return;
    }
    _dialing = true;
    final epoch = ++_epoch;
    _state = CashierRealtimeState.connecting;
    _changed();
    final codec = CcsopRealtimeCodec(
      session.credentials,
      'store:${session.storeRef}',
      endpoint: '/cashier/ws',
    );
    _codec = codec;
    try {
      final uri = await codec.connectionUri(session.base.toString());
      if (!_current(epoch)) return;
      final socket = await _connectSocket(uri);
      if (!_current(epoch)) {
        unawaited(_close(socket));
        return;
      }
      _socket = socket;
      _sequence = 0;
      _pending = 0;
      _inbound = Future.value();
      _deadline = Timer(const Duration(seconds: 8), () => _lost(epoch));
      _subscription = socket.messages.listen(
        (raw) {
          if (!_current(epoch)) return;
          if (++_pending > 16 ||
              raw is! String ||
              utf8.encode(raw).length > 16384) {
            _lost(epoch);
            return;
          }
          _inbound = _inbound.then((_) async {
            if (!_current(epoch)) return;
            try {
              await _receive(codec, raw, epoch);
            } catch (_) {
              _lost(epoch);
            } finally {
              if (_current(epoch)) --_pending;
            }
          });
        },
        onError: (Object _) => _lost(epoch),
        onDone: () => _lost(epoch),
      );
    } catch (_) {
      _lost(epoch);
    } finally {
      _dialing = false;
      if (!_current(epoch)) codec.close();
      // A stop/resume during an in-flight dial must not create overlapping dials.
      if (_active && !_disposed && _socket == null && _retry == null) {
        unawaited(_open());
      }
    }
  }

  Future<void> _receive(CcsopRealtimeCodec codec, String raw, int epoch) async {
    final frame = await codec.decode(raw);
    if (!_current(epoch)) return;
    final timestamp = frame['timestamp'] as int;
    if (frame['seq'] != _sequence + 1 ||
        (_now().millisecondsSinceEpoch - timestamp).abs() > 60000) {
      throw const FormatException('Invalid realtime sequence');
    }
    final payload = jsonObject(frame['data']);
    final event = frame['eventType'];
    if (_state != CashierRealtimeState.connected) {
      if (event != 'connection.ready' ||
          payload.length != 1 ||
          payload['storeRef'] != session.storeRef) {
        throw const FormatException('Invalid store handshake');
      }
      _deadline?.cancel();
      _state = CashierRealtimeState.connected;
      _attempt = 0;
      _lastPong = _now();
      ++_revision;
      lastTopic = null;
      _heartbeat = Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(_ping(epoch)),
      );
      _changed();
    } else if (event == 'commerce.changed') {
      if (payload.length != 2 ||
          payload['storeRef'] != session.storeRef ||
          !{
            'tables',
            'orders',
            'inventory',
            'members',
          }.contains(payload['topic'])) {
        throw const FormatException('Invalid store event');
      }
      ++_revision;
      lastTopic = payload['topic'] as String;
      _changed();
    } else if (event == 'pong') {
      if (payload.length != 1 || payload['serverTime'] is! int) {
        throw const FormatException('Invalid heartbeat');
      }
      _lastPong = _now();
    } else {
      throw const FormatException('Unexpected realtime event');
    }
    _sequence = frame['seq'] as int;
  }

  Future<void> _ping(int epoch) async {
    if (!_current(epoch) || _pingBusy) return;
    if (!session.expiresAt.isAfter(_now()) ||
        _now().difference(_lastPong!) > const Duration(seconds: 45)) {
      _lost(epoch);
      return;
    }
    _pingBusy = true;
    try {
      final frame = await _codec!.encode('ping', {});
      if (_current(epoch)) _socket!.send(frame);
    } catch (_) {
      _lost(epoch);
    } finally {
      _pingBusy = false;
    }
  }

  Future<void> _close(CashierSocket socket) async {
    try {
      await socket.close();
    } catch (_) {
      /* no signed URI logging */
    }
  }

  void _clear() {
    _retry?.cancel();
    _retry = null;
    _deadline?.cancel();
    _deadline = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    _codec?.close();
    _codec = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(_close(socket));
    _state = CashierRealtimeState.offline;
  }

  void _lost(int epoch) {
    if (!_current(epoch)) return;
    ++_epoch;
    _clear();
    _changed();
    if (!_active || _disposed) return;
    if (!session.expiresAt.isAfter(_now())) {
      _active = false;
      return;
    }
    final seconds = min(30, 1 << min(_attempt++, 5));
    _retry = Timer(
      Duration(milliseconds: seconds * 1000 + Random().nextInt(500)),
      () {
        _retry = null;
        unawaited(_open());
      },
    );
  }

  void stop() {
    _active = false;
    ++_epoch;
    _clear();
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
