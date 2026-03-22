import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:local_auth/local_auth.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const PhonePadApp());
}

// ══════════════════════════════════════════════════════════════════════
// THEME
// ══════════════════════════════════════════════════════════════════════
class _C {
  static const bg      = Color(0xFF080B14);
  static const surface = Color(0xFF0F1420);
  static const card    = Color(0xFF141928);
  static const border  = Color(0xFF1E2740);
  static const accentA = Color(0xFF3B7BF5);
  static const accentB = Color(0xFF7B5CF5);
  static const accentC = Color(0xFF3BF5C0);
  static const textHi  = Color(0xFFE8EEFF);
  static const textMid = Color(0xFF8A95B8);
  static const textLo  = Color(0xFF404868);
  static const danger  = Color(0xFFFF4D6A);
  static const success = Color(0xFF3BF5C0);
  static const amber   = Color(0xFFFFB830);
  static const media   = Color(0xFF3BF5C0);
  static const LinearGradient accent = LinearGradient(
      colors: [accentA, accentB],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight);
  static const LinearGradient bgGrad = LinearGradient(
      colors: [Color(0xFF080B14), Color(0xFF0C1020), Color(0xFF080B14)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight);
}

// ══════════════════════════════════════════════════════════════════════
// HAPTIC PROFILE
// ══════════════════════════════════════════════════════════════════════
enum HapticProfile { none, light, medium, strong }

class _Haptics {
  static HapticProfile profile = HapticProfile.medium;

  static void click() =>
      _fire(HapticFeedback.lightImpact, HapticFeedback.selectionClick,
          HapticFeedback.mediumImpact);
  static void rightClick() =>
      _fire(HapticFeedback.selectionClick, HapticFeedback.mediumImpact,
          HapticFeedback.heavyImpact);
  static void drag() =>
      _fire(HapticFeedback.mediumImpact, HapticFeedback.heavyImpact,
          HapticFeedback.heavyImpact);
  static void key() =>
      _fire(null, HapticFeedback.selectionClick, HapticFeedback.selectionClick);

  static void _fire(
    Future<void> Function()? light,
    Future<void> Function() medium,
    Future<void> Function() strong,
  ) {
    switch (profile) {
      case HapticProfile.none:   break;
      case HapticProfile.light:  light?.call(); break;
      case HapticProfile.medium: medium(); break;
      case HapticProfile.strong: strong(); break;
    }
  }
}

// ══════════════════════════════════════════════════════════════════════
// CUSTOM SHORTCUT MODEL
// ══════════════════════════════════════════════════════════════════════
class CustomSlot {
  String label;
  String combo;
  CustomSlot({required this.label, required this.combo});
  Map<String, String> toJson() => {'label': label, 'combo': combo};
  factory CustomSlot.fromJson(Map<String, dynamic> j) =>
      CustomSlot(label: j['label'] ?? '', combo: j['combo'] ?? '');
}

// ══════════════════════════════════════════════════════════════════════
// PANEL MODEL
// ══════════════════════════════════════════════════════════════════════
enum PanelType { shortcuts, altTab, arrows, media, keyboard, system, customSlots }

class PanelConfig {
  PanelType type;
  bool visible;
  bool pinned;

  PanelConfig({required this.type, this.visible = false, this.pinned = false});
  String get key => type.name;
  String get label {
    switch (type) {
      case PanelType.shortcuts:   return 'Shortcuts';
      case PanelType.altTab:      return 'Alt+Tab';
      case PanelType.arrows:      return 'Arrows';
      case PanelType.media:       return 'Media';
      case PanelType.keyboard:    return 'Keyboard';
      case PanelType.system:      return 'System';
      case PanelType.customSlots: return 'Custom';
    }
  }
  IconData get icon {
    switch (type) {
      case PanelType.shortcuts:   return Icons.flash_on_rounded;
      case PanelType.altTab:      return Icons.tab_rounded;
      case PanelType.arrows:      return Icons.gamepad_rounded;
      case PanelType.media:       return Icons.music_note_rounded;
      case PanelType.keyboard:    return Icons.keyboard_rounded;
      case PanelType.system:      return Icons.computer_rounded;
      case PanelType.customSlots: return Icons.add_box_rounded;
    }
  }
  Map<String, dynamic> toJson() => {
    'type': type.name,
    'visible': visible,
    'pinned': pinned,
  };
  factory PanelConfig.fromJson(Map<String, dynamic> j) => PanelConfig(
        type: PanelType.values.firstWhere((t) => t.name == j['type'],
            orElse: () => PanelType.shortcuts),
        visible: j['visible'] as bool? ?? false,
        pinned: j['pinned'] as bool? ?? false,
      );
}

// ══════════════════════════════════════════════════════════════════════
// APP ROOT
// ══════════════════════════════════════════════════════════════════════
final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

class PhonePadApp extends StatelessWidget {
  const PhonePadApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PhonePad',
        navigatorKey: _navKey,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _C.bg,
          fontFamily: 'Helvetica Neue',
          colorScheme:
              const ColorScheme.dark(primary: _C.accentA, surface: _C.surface),
        ),
        home: const ConnectionScreen(),
      );
}

// ══════════════════════════════════════════════════════════════════════
// SHARED WIDGETS
// ══════════════════════════════════════════════════════════════════════
class _GradText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const _GradText(this.text, {required this.style});
  @override
  Widget build(BuildContext context) => ShaderMask(
      shaderCallback: (r) => _C.accent.createShader(r),
      child: Text(text, style: style.copyWith(color: Colors.white)));
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _GlassCard(
      {required this.child,
      this.padding = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
            color: _C.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _C.border),
            boxShadow: [
              BoxShadow(
                  color: _C.accentA.withOpacity(0.03),
                  blurRadius: 20,
                  spreadRadius: -4)
            ]),
        child: child);
}

class _GradButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  final IconData? icon;
  const _GradButton(
      {required this.label,
      this.onTap,
      this.loading = false,
      this.icon});
  @override
  State<_GradButton> createState() => _GradButtonState();
}

class _GradButtonState extends State<_GradButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 100));
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.96)
      .animate(CurvedAnimation(parent: _ac, curve: Curves.easeOut));
  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTapDown: (_) => _ac.forward(),
        onTapUp: (_) {
          _ac.reverse();
          widget.onTap?.call();
        },
        onTapCancel: () => _ac.reverse(),
        child: ScaleTransition(
            scale: _scale,
            child: Container(
                height: 52,
                decoration: BoxDecoration(
                    gradient: widget.onTap != null
                        ? const LinearGradient(
                            colors: [_C.accentA, _C.accentB],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight)
                        : null,
                    color: widget.onTap == null ? _C.border : null,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: widget.onTap != null
                        ? [
                            BoxShadow(
                                color: _C.accentA.withOpacity(0.3),
                                blurRadius: 16,
                                offset: const Offset(0, 5))
                          ]
                        : null),
                child: Center(
                    child: widget.loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2.5))
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.icon != null) ...[
                                Icon(widget.icon,
                                    color: Colors.white, size: 16),
                                const SizedBox(width: 8)
                              ],
                              Text(widget.label,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                      letterSpacing: 0.2))
                            ])))));
}

// ══════════════════════════════════════════════════════════════════════
// PREFS KEYS
// ══════════════════════════════════════════════════════════════════════
const _kLastIp        = 'last_ip';
const _kLastPort      = 'last_port';
const _kHaptic        = 'haptic_profile';
const _kNatScroll     = 'natural_scroll';
const _kCustomSlots   = 'custom_slots';
const _kPanelOrder    = 'panel_order_v3';
const _kPeerId        = 'peer_id';
const _kSessionPrefix = 'session_token_';
const _kUnlockEnabled = 'unlock_enabled_';

// Overlay (floating window) method channel
const _overlayChannel = MethodChannel('com.pranav.phonepad_app/overlay');

// ══════════════════════════════════════════════════════════════════════
// PEER ID
// ══════════════════════════════════════════════════════════════════════
String _generateUuid() {
  final rng = math.Random.secure();
  String hex(int bytes) => List.generate(bytes,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final a = hex(4);
  final b = hex(2);
  final c = '4${hex(1).substring(1)}';
  final d = ((rng.nextInt(4) + 8)).toRadixString(16) + hex(1).substring(1);
  final e = hex(6);
  return '$a-$b-$c-$d-$e';
}

Future<String> _getPeerId() async {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString(_kPeerId);
  if (id == null || id.isEmpty) {
    id = _generateUuid();
    await prefs.setString(_kPeerId, id);
  }
  return id;
}

// ══════════════════════════════════════════════════════════════════════
// SESSION TOKEN STORAGE
// ══════════════════════════════════════════════════════════════════════
Future<String?> _loadSessionToken(String serverKey) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('$_kSessionPrefix$serverKey');
}

Future<void> _saveSessionToken(String serverKey, String token) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('$_kSessionPrefix$serverKey', token);
}

Future<void> _clearSessionToken(String serverKey) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('$_kSessionPrefix$serverKey');
}

// ══════════════════════════════════════════════════════════════════════
// WEBSOCKET HELPERS
// ══════════════════════════════════════════════════════════════════════
Future<WebSocket> _openRawSocket(Uri uri) async {
  final httpClient = HttpClient()
    ..badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
  return WebSocket.connect(uri.toString(), customClient: httpClient)
      .timeout(const Duration(seconds: 8));
}

WebSocketChannel _wrapSocket(WebSocket socket) => IOWebSocketChannel(socket);

Future<bool> _loadUnlockEnabled(String serverKey) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('$_kUnlockEnabled$serverKey') ?? false;
}

Future<void> _saveUnlockEnabled(String serverKey, bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('$_kUnlockEnabled$serverKey', enabled);
}

// ══════════════════════════════════════════════════════════════════════
// AUTH RESULT
// ══════════════════════════════════════════════════════════════════════
class _AuthResult {
  final bool success;
  final String message;
  const _AuthResult._(this.success, this.message);
  static const ok = _AuthResult._(true, '');
  static const invalidToken = _AuthResult._(false, 'Session expired.');
  factory _AuthResult.error(String msg) => _AuthResult._(false, msg);
}

// ══════════════════════════════════════════════════════════════════════
// CONNECTION SCREEN
// ══════════════════════════════════════════════════════════════════════
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen>
    with SingleTickerProviderStateMixin {
  final _ipCtrl = TextEditingController(text: '192.168.1.100');
  final _portCtrl = TextEditingController(text: '8765');
  bool _connecting = false;
  String _status = '';
  late final AnimationController _fadeAc =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 500));

  @override
  void initState() {
    super.initState();
    _fadeAc.forward();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString(_kLastIp);
    final port = prefs.getString(_kLastPort);
    if (mounted) {
      if (ip != null && ip.isNotEmpty) _ipCtrl.text = ip;
      if (port != null && port.isNotEmpty) _portCtrl.text = port;
    }
    final hIdx = prefs.getInt(_kHaptic) ?? HapticProfile.medium.index;
    _Haptics.profile =
        HapticProfile.values[hIdx.clamp(0, HapticProfile.values.length - 1)];
  }

  @override
  void dispose() {
    _fadeAc.dispose();
    _ipCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _connectTo(String url) async {
    if (!mounted) return;

    final originalUri = Uri.parse(url);
    final String primaryUrl = originalUri.scheme == 'ws'
        ? url.replaceFirst('ws://', 'wss://')
        : url;
    final String fallbackUrl = originalUri.scheme == 'ws'
        ? url
        : url.replaceFirst('wss://', 'ws://');

    setState(() { _connecting = true; _status = ''; });

    WebSocket? rawSocket;
    Uri? usedUri;

    for (final tryUrl in [primaryUrl, fallbackUrl]) {
      try {
        final uri = Uri.parse(tryUrl);
        rawSocket = await _openRawSocket(uri);
        usedUri = uri;
        break;
      } catch (_) {}
    }

    if (rawSocket == null || usedUri == null) {
      if (mounted) setState(() {
        _connecting = false;
        _status = 'Could not connect to ${originalUri.host}:${originalUri.port}\n'
            'Make sure the server is running and your phone is on the same WiFi.';
      });
      return;
    }

    if (!mounted) { rawSocket.close(); return; }

    final serverKey = '${usedUri.host}:${usedUri.port}';
    final peerId    = await _getPeerId();
    final token     = await _loadSessionToken(serverKey);

    if (!mounted) { rawSocket.close(); return; }

    if (token != null) {
      final result = await _rawAuth(rawSocket, peerId, token);
      if (result == _AuthResult.ok) {
        if (!mounted) { rawSocket.close(); return; }
        try { rawSocket.close(); } catch (_) {}
        final sessionSocket = await _openRawSocket(usedUri);
        sessionSocket.add(json.encode({'type': 'auth', 'peer_id': peerId, 'token': token}));
        if (!mounted) { sessionSocket.close(); return; }
        await _navigateToTouchpad(_wrapSocket(sessionSocket), usedUri, serverKey);
        return;
      } else if (result == _AuthResult.invalidToken) {
        await _clearSessionToken(serverKey);
        try { rawSocket.close(); } catch (_) {}
        if (!mounted) return;
        // Token invalid — open fresh socket and go straight to PIN pairing
        try {
          rawSocket = await _openRawSocket(usedUri);
        } catch (e) {
          if (mounted) setState(() {
            _connecting = false;
            _status = 'Could not reconnect: $e';
          });
          return;
        }
        // Fall through to PIN dialog below with fresh socket
      } else {
        if (mounted) { setState(() { _connecting = false; _status = result.message; }); }
        try { rawSocket.close(); } catch (_) {}
        return;
      }
    } else {
      // No token at all — close current socket, will reopen after PIN dialog
      try { rawSocket.close(); } catch (_) {}
      rawSocket = null;
    }

    if (!mounted) { rawSocket?.close(); return; }

    try { rawSocket?.close(); } catch (_) {}

    if (!mounted) return;
    setState(() => _connecting = false);

    final dialogCompleter = Completer<String?>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = _navKey.currentContext;
      if (ctx == null || !ctx.mounted) { dialogCompleter.complete(null); return; }
      dialogCompleter.complete(await _showPinDialog(ctx));
    });
    final pin = await dialogCompleter.future;

    if (pin == null) {
      if (mounted) setState(() => _connecting = false);
      return;
    }
    if (!mounted) return;

    WebSocket? pairSocket;
    try {
      pairSocket = await _openRawSocket(usedUri);
    } catch (e) {
      if (mounted) setState(() { _connecting = false; _status = 'Reconnect failed: $e'; });
      return;
    }
    if (!mounted) { pairSocket.close(); return; }

    final pairResult = await _rawPair(pairSocket, peerId, pin, serverKey);
    if (pairResult == _AuthResult.ok) {
      try { pairSocket.close(); } catch (_) {}
      if (!mounted) return;

      final newToken = await _loadSessionToken(serverKey);
      if (newToken == null) {
        if (mounted) setState(() { _connecting = false; _status = 'Token missing after pairing. Try again.'; });
        return;
      }

      try {
        final verifySocket = await _openRawSocket(usedUri);
        final verifyResult = await _rawAuth(verifySocket, peerId, newToken);
        try { verifySocket.close(); } catch (_) {}
        if (verifyResult != _AuthResult.ok) {
          if (mounted) setState(() { _connecting = false; _status = 'Token invalid after pairing: ${verifyResult.message}'; });
          return;
        }
      } catch (e) {
        if (mounted) setState(() { _connecting = false; _status = 'Verify failed: $e'; });
        return;
      }
      if (!mounted) return;

      WebSocket? sessionSocket;
      try {
        sessionSocket = await _openRawSocket(usedUri);
      } catch (e) {
        if (mounted) setState(() { _connecting = false; _status = 'Session connect failed: $e'; });
        return;
      }
      if (!mounted) { sessionSocket.close(); return; }

      sessionSocket.add(json.encode({'type': 'auth', 'peer_id': peerId, 'token': newToken}));
      await _navigateToTouchpad(_wrapSocket(sessionSocket), usedUri, serverKey);
    } else {
      if (mounted) { setState(() { _connecting = false; _status = pairResult.message; }); }
      try { pairSocket.close(); } catch (_) {}
    }
  }

  Future<_AuthResult> _rawPair(WebSocket ws, String peerId, String pin, String serverKey) async {
    ws.add(json.encode({'type': 'pair', 'peer_id': peerId, 'pin': pin}));
    try {
      final raw = await ws.first.timeout(const Duration(seconds: 8));
      final msg = json.decode(raw as String) as Map<String, dynamic>;
      if (msg['type'] == 'pair_ok') {
        await _saveSessionToken(serverKey, msg['token'] as String);
        return _AuthResult.ok;
      }
      return _AuthResult.error(msg['message']?.toString() ?? 'Pairing failed — check PIN');
    } on TimeoutException {
      return _AuthResult.error('Server did not respond during pairing.');
    } catch (e) {
      return _AuthResult.error('Connection error: $e');
    }
  }

  Future<void> _navigateToTouchpad(
      WebSocketChannel channel, Uri uri, String serverKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastIp, uri.host);
    await prefs.setString(_kLastPort, uri.port.toString());
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => TouchpadScreen(
              initialChannel: channel,
              serverAddress: uri.authority,
              serverKey: serverKey,
              wsUrl: uri.toString(),
            )));
  }

  Future<String?> _showPinDialog(BuildContext ctx) async {
    final controllers = List.generate(6, (_) => TextEditingController());
    final focusNodes = List.generate(6, (_) => FocusNode());
    String? error;

    return showDialog<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, ss) {
          String getPin() => controllers.map((c) => c.text).join();

          return AlertDialog(
            backgroundColor: _C.card,
            insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            title: const Column(children: [
              Icon(Icons.lock_outline_rounded,
                  color: _C.accentA, size: 32),
              SizedBox(height: 10),
              Text('Enter Pairing PIN',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _C.textHi,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
            ]),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                'Check the PhonePad server window\nfor the 6-digit PIN.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _C.textMid, fontSize: 13, height: 1.5)),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: List.generate(6, (i) {
                  return Container(
                    width: 34,
                    height: 44,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: _C.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: focusNodes[i].hasFocus ? _C.accentA : _C.border,
                        width: focusNodes[i].hasFocus ? 1.5 : 1,
                      ),
                    ),
                    child: TextField(
                      controller: controllers[i],
                      focusNode: focusNodes[i],
                      keyboardType: TextInputType.number,
                      maxLength: 1,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _C.textHi,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: const InputDecoration(
                        counterText: '',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (v) {
                        if (v.length == 1 && i < 5) {
                          focusNodes[i + 1].requestFocus();
                        } else if (v.isEmpty && i > 0) {
                          focusNodes[i - 1].requestFocus();
                        }
                        ss(() => error = null);
                      },
                    ),
                  );
                }),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                        color: _C.danger.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: _C.danger.withOpacity(0.3))),
                    child: Text(error!,
                        style: const TextStyle(
                            color: _C.danger, fontSize: 12))),
              ],
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogCtx, null),
                  child: const Text('Cancel',
                      style: TextStyle(color: _C.textMid))),
              TextButton(
                  onPressed: () {
                    final pin = getPin();
                    if (pin.length < 6) {
                      ss(() => error = 'Enter all 6 digits.');
                      return;
                    }
                    Navigator.pop(dialogCtx, pin);
                  },
                  child: const Text('Pair',
                      style: TextStyle(
                          color: _C.accentA,
                          fontWeight: FontWeight.w700))),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openQr() async {
    final r = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const _QrScannerScreen()));
    if (r == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _connectTo(r);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: _C.bg,
      body: Container(
          decoration: const BoxDecoration(gradient: _C.bgGrad),
          child: SafeArea(
              child: FadeTransition(
                  opacity: _fadeAc,
                  child: Center(
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 32, vertical: 40),
                          child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                    width: 64,
                                    height: 64,
                                    decoration: BoxDecoration(
                                        gradient: const LinearGradient(
                                            colors: [_C.accentA, _C.accentB],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight),
                                        borderRadius:
                                            BorderRadius.circular(18)),
                                    child: const Icon(
                                        Icons.touch_app_rounded,
                                        color: Colors.white,
                                        size: 32)),
                                const SizedBox(height: 20),
                                const _GradText('PhonePad',
                                    style: TextStyle(
                                        fontSize: 32,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -0.5)),
                                const SizedBox(height: 6),
                                const Text('Wireless precision trackpad',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: _C.textMid)),
                                const SizedBox(height: 48),
                                _GradButton(
                                    label: 'Scan QR Code',
                                    loading: _connecting,
                                    onTap: _connecting ? null : _openQr,
                                    icon: Icons.qr_code_scanner_rounded),
                                if (_status.isNotEmpty) ...[
                                  const SizedBox(height: 16),
                                  Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                          color: _C.danger.withOpacity(0.1),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                              color: _C.danger
                                                  .withOpacity(0.3))),
                                      child: Text(_status,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                              color: _C.danger,
                                              fontSize: 13))),
                                ],
                                const SizedBox(height: 48),
                                _GlassCard(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text('GESTURES',
                                              style: TextStyle(
                                                  color: _C.textLo,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: 1.4)),
                                          const SizedBox(height: 12),
                                          ...[
                                            ('1 finger move', 'Move cursor'),
                                            ('Tap', 'Left click'),
                                            ('2-finger tap', 'Right click'),
                                            ('Long press', 'Drag'),
                                            ('Double tap+drag', 'Select text'),
                                            ('2 fingers', 'Scroll'),
                                            ('Pinch (zoom mode)', 'Magnify')
                                          ].map((e) => Padding(
                                              padding:
                                                  const EdgeInsets.only(
                                                      bottom: 7),
                                              child: Row(children: [
                                                Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                            horizontal: 7,
                                                            vertical: 2),
                                                    decoration: BoxDecoration(
                                                        color: _C.accentA
                                                            .withOpacity(0.1),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                                5),
                                                        border: Border.all(
                                                            color: _C.accentA
                                                                .withOpacity(
                                                                    0.2))),
                                                    child: Text(e.$1,
                                                        style: const TextStyle(
                                                            color: _C.accentA,
                                                            fontSize: 10,
                                                            fontWeight:
                                                                FontWeight.w600))),
                                                const SizedBox(width: 8),
                                                Text(e.$2,
                                                    style: const TextStyle(
                                                        color: _C.textMid,
                                                        fontSize: 11))
                                              ]))),
                                        ])),
                              ])))))));
}

// ══════════════════════════════════════════════════════════════════════
// QR SCANNER
// ══════════════════════════════════════════════════════════════════════
class _QrScannerScreen extends StatefulWidget {
  const _QrScannerScreen();
  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  final MobileScannerController _ctrl = MobileScannerController();
  bool _handled = false;
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture c) {
    if (_handled) return;
    final raw = c.barcodes.firstOrNull?.rawValue;
    if (raw == null ||
        (!raw.startsWith('ws://') && !raw.startsWith('wss://'))) {
      return;
    }
    _handled = true;
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        MobileScanner(controller: _ctrl, onDetect: _onDetect),
        Positioned.fill(
            child: CustomPaint(painter: _ScanOverlayPainter())),
        Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
                child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: Row(children: [
                      GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                  color: Colors.black45,
                                  borderRadius:
                                      BorderRadius.circular(10)),
                              child: const Icon(Icons.close_rounded,
                                  color: Colors.white, size: 20))),
                      const SizedBox(width: 14),
                      const Text('Scan QR Code',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      GestureDetector(
                          onTap: () => _ctrl.toggleTorch(),
                          child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                  color: Colors.black45,
                                  borderRadius:
                                      BorderRadius.circular(10)),
                              child: const Icon(
                                  Icons.flashlight_on_rounded,
                                  color: Colors.white,
                                  size: 20))),
                    ])))),
        Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
                child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                        gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                          Colors.black.withOpacity(0.7),
                          Colors.transparent
                        ])),
                    child: const Text(
                        'Point at the QR code in the PhonePad terminal window.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13))))),
      ]));
}

class _ScanOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final dim = math.min(size.width, size.height) * 0.62;
    final left = (size.width - dim) / 2;
    final top = (size.height - dim) / 2;
    final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, dim, dim),
        const Radius.circular(16));
    canvas.drawPath(
        Path()
          ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
          ..addRRect(rrect)
          ..fillType = PathFillType.evenOdd,
        Paint()..color = Colors.black.withOpacity(0.55));
    final p = Paint()
      ..color = _C.accentA
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const len = 22.0;
    const r = 16.0;
    for (final corner in [
      [Offset(left + r, top), Offset(left + r + len, top)],
      [Offset(left, top + r), Offset(left, top + r + len)],
      [Offset(left + dim - r, top), Offset(left + dim - r - len, top)],
      [Offset(left + dim, top + r), Offset(left + dim, top + r + len)],
      [Offset(left + r, top + dim), Offset(left + r + len, top + dim)],
      [Offset(left, top + dim - r), Offset(left, top + dim - r - len)],
      [
        Offset(left + dim - r, top + dim),
        Offset(left + dim - r - len, top + dim)
      ],
      [
        Offset(left + dim, top + dim - r),
        Offset(left + dim, top + dim - r - len)
      ],
    ]) {
      canvas.drawLine(corner[0], corner[1], p);
    }
  }

  @override
  bool shouldRepaint(_ScanOverlayPainter _) => false;
}

// ══════════════════════════════════════════════════════════════════════
// EMA SMOOTHER
// ══════════════════════════════════════════════════════════════════════
class EmaSmoother {
  final double alpha;
  double? _prev;
  EmaSmoother({this.alpha = 0.35});
  double smooth(double v) {
    if (_prev == null) {
      _prev = v;
      return v;
    }
    _prev = alpha * v + (1 - alpha) * _prev!;
    return _prev!;
  }
  void reset() => _prev = null;
}

enum ScrollAxis { none, vertical, horizontal }

// ══════════════════════════════════════════════════════════════════════
// DEFAULT PANEL ORDER
// ══════════════════════════════════════════════════════════════════════
List<PanelConfig> _defaultPanels() => [
      PanelConfig(type: PanelType.shortcuts, visible: true, pinned: false),
      PanelConfig(type: PanelType.altTab, visible: true, pinned: false),
      PanelConfig(type: PanelType.arrows, visible: true, pinned: false),
      PanelConfig(type: PanelType.media, visible: true, pinned: false),
      PanelConfig(type: PanelType.keyboard, visible: true, pinned: false),
      PanelConfig(type: PanelType.system, visible: true, pinned: false),
      PanelConfig(type: PanelType.customSlots, visible: false, pinned: false),
    ];

// ══════════════════════════════════════════════════════════════════════
// CONNECTION STATUS
// ══════════════════════════════════════════════════════════════════════
enum _ConnStatus { connected, reconnecting, failed }

Future<_AuthResult> _rawAuth(WebSocket ws, String peerId, String token) async {
  ws.add(json.encode({'type': 'auth', 'peer_id': peerId, 'token': token}));
  try {
    final raw = await ws.first.timeout(const Duration(seconds: 8));
    final msg = json.decode(raw as String) as Map<String, dynamic>;
    if (msg['type'] == 'auth_ok') return _AuthResult.ok;
    if (msg['type'] == 'auth_error' && msg['reason'] == 'invalid_token') {
      return _AuthResult.invalidToken;
    }
    return _AuthResult.error(msg['message']?.toString() ?? 'Auth failed');
  } on TimeoutException {
    return _AuthResult.error('Server did not respond. Is it running?');
  } catch (e) {
    return _AuthResult.error('Connection error: $e');
  }
}

// ══════════════════════════════════════════════════════════════════════
// RECONNECT MANAGER
// ══════════════════════════════════════════════════════════════════════
class _ReconnectManager {
  final String wsUrl;
  final String serverKey;
  final String serverAddress;
  final void Function(_ConnStatus, {String? detail}) onStatusChange;
  final void Function(Map<String, dynamic>) onEvent;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _disposed = false;
  bool _manualStop = false;
  int _attempt = 0;

  static const _baseSecs = 1;
  static const _capSecs = 5;
  static const _jitter = 0.10;

  _ReconnectManager({
    required this.wsUrl,
    required this.serverKey,
    required this.serverAddress,
    required this.onStatusChange,
    required this.onEvent,
  });

  void attach(WebSocketChannel channel) {
    _channel = channel;
    _attempt = 0;
    _listenTo(channel);
    onStatusChange(_ConnStatus.connected);
  }

  void send(String jsonStr) {
    try {
      _channel?.sink.add(jsonStr);
    } catch (_) {}
  }

  void disconnect() {
    _manualStop = true;
    _close();
  }

  void dispose() {
    _disposed = true;
    _close();
  }

  void _listenTo(WebSocketChannel ch) {
    _sub?.cancel();
    _sub = ch.stream.listen(
      (raw) {
        try {
          final data = json.decode(raw as String) as Map<String, dynamic>;
          onEvent(data);
        } catch (_) {}
      },
      onDone: () {
        if (!_disposed && !_manualStop) _scheduleReconnect();
      },
      onError: (_) {
        if (!_disposed && !_manualStop) _scheduleReconnect();
      },
      cancelOnError: true,
    );
  }

  void _close() {
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _scheduleReconnect() {
    if (_disposed || _manualStop) return;
    _close();
    _attempt++;
    final delaySecs =
        math.min(_baseSecs * math.pow(2, _attempt - 1).toInt(), _capSecs);
    final jitter = (math.Random().nextDouble() * 2 - 1) * _jitter;
    final waitMs = (delaySecs * (1 + jitter) * 1000).round();
    onStatusChange(_ConnStatus.reconnecting,
        detail:
            'Reconnecting in ${(waitMs / 1000).toStringAsFixed(1)}s\u2026');
    Future.delayed(Duration(milliseconds: waitMs), () {
      if (!_disposed && !_manualStop) _tryReconnect();
    });
  }

  Future<void> _tryReconnect() async {
    if (_disposed || _manualStop) return;
    onStatusChange(_ConnStatus.reconnecting, detail: 'Connecting…');
    try {
      final uri = Uri.parse(wsUrl);
      final rawSocket = await _openRawSocket(uri);
      final peerId = await _getPeerId();
      final token = await _loadSessionToken(serverKey);
      if (token == null) {
        onStatusChange(_ConnStatus.failed,
            detail: 'Session lost — reconnect manually to re-pair.');
        _manualStop = true;
        try { rawSocket.close(); } catch (_) {}
        return;
      }
      final authResult = await _rawAuth(rawSocket, peerId, token);
      if (authResult == _AuthResult.ok) {
        final channel = _wrapSocket(rawSocket);
        _channel = channel;
        _attempt = 0;
        _listenTo(channel);
        onStatusChange(_ConnStatus.connected);
      } else if (authResult == _AuthResult.invalidToken) {
        await _clearSessionToken(serverKey);
        try { rawSocket.close(); } catch (_) {}
        onStatusChange(_ConnStatus.failed,
            detail: 'Session expired — reconnect to pair again.');
        _manualStop = true;
      } else {
        try { rawSocket.close(); } catch (_) {}
        _scheduleReconnect();
      }
    } catch (_) {
      if (!_disposed && !_manualStop) _scheduleReconnect();
    }
  }
}

// ══════════════════════════════════════════════════════════════════════
// TOUCHPAD SCREEN
// ══════════════════════════════════════════════════════════════════════
class TouchpadScreen extends StatefulWidget {
  final WebSocketChannel initialChannel;
  final String serverAddress;
  final String serverKey;
  final String wsUrl;
  const TouchpadScreen({
    super.key,
    required this.initialChannel,
    required this.serverAddress,
    required this.serverKey,
    required this.wsUrl,
  });
  @override
  State<TouchpadScreen> createState() => _TouchpadScreenState();
}

class _TouchpadScreenState extends State<TouchpadScreen>
    with SingleTickerProviderStateMixin {
  double _sensitivity = 2.5;
  double _scrollSpeed = 5.0;
  bool _portraitLocked = true;
  bool _zoomMode = false;
  bool _fullscreen = false;
  bool _altHeld = false;
  bool _naturalScroll = false;
  double _momFeel = 0.80;
  bool _editMode = false;
  bool _drawerOpen = false;
  final DraggableScrollableController _drawerCtrl =
      DraggableScrollableController();

  List<PanelConfig> _panels = _defaultPanels();
  List<CustomSlot> _customSlots = [];

  late _ReconnectManager _conn;
  _ConnStatus _connStatus = _ConnStatus.connected;
  String _connDetail = '';

  bool _unlockEnabled = false;
  bool _unlockInFlight = false;

  int? _rttMs;
  Timer? _pingTimer;
  int _missedPongs = 0;
  static const _pingIntervalMs = 2000;
  static const _pingTimeoutMs = 5000;
  static const _maxMissedPongs = 3;

  bool _clipInFlight = false;
  int _brightnessLevel = 50;
  int _volumeLevel = 50;
  bool _volumeMuted = false;
  bool _volumeOsdVisible = false;
  Timer? _volumeOsdTimer;
  int _batteryLevel = -1;
  bool _batteryCharging = false;
  bool _batteryAvailable = false;
  Timer? _batteryTimer;
  bool _overlayActive = false;
  // When settings sheet or keyboard overlay is open, pause the touchpad
  // so its Listener doesn't swallow touches meant for those UIs.
  bool _touchpadEnabled = true;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _loadPrefs();
    _conn = _ReconnectManager(
      wsUrl: widget.wsUrl,
      serverKey: widget.serverKey,
      serverAddress: widget.serverAddress,
      onStatusChange: (status, {detail}) {
        if (!mounted) return;
        setState(() {
          _connStatus = status;
          _connDetail = detail ?? '';
          if (status != _ConnStatus.connected) {
            if (_altHeld) _altHeld = false;
            _rttMs = null;
            _missedPongs = 0;
          }
        });
        if (status == _ConnStatus.connected) _startPingTimer();
      },
      onEvent: _handleServerEvent,
    );
    _conn.attach(widget.initialChannel);
    _startPingTimer();
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _send('brightness_get');
        _send('volume_get');
        _send('battery_get');
      }
    });
    // Poll battery every 60 seconds
    _batteryTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && _connStatus == _ConnStatus.connected) {
        _send('battery_get');
      }
    });
  }

  void _handleServerEvent(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    switch (type) {
      case 'pong':
        final clientTs = data['client_ts'] as int? ?? 0;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (mounted) {
          setState(() {
            _rttMs = nowMs - clientTs;
            _missedPongs = 0;
          });
        }
      case 'unlock_result':
        final success = data['success'] as bool? ?? false;
        final msg = data['message'] as String? ?? '';
        if (mounted) {
          setState(() => _unlockInFlight = false);
          _showUnlockFeedback(success, msg);
        }
      case 'brightness_value':
        final level = data['level'] as int? ?? 50;
        if (mounted) setState(() => _brightnessLevel = level);
      case 'volume_value':
        final vol = data['level'] as int? ?? 50;
        final muted = data['muted'] as bool? ?? false;
        if (mounted) {
          setState(() {
            _volumeLevel = vol;
            _volumeMuted = muted;
            _volumeOsdVisible = true;
          });
          _volumeOsdTimer?.cancel();
          _batteryTimer?.cancel();
          _volumeOsdTimer = Timer(const Duration(seconds: 3), () {
            if (mounted) setState(() => _volumeOsdVisible = false);
          });
        }
      case 'battery_value':
        if (mounted) {
          setState(() {
            _batteryLevel = data['level'] as int? ?? -1;
            _batteryCharging = data['charging'] as bool? ?? false;
            _batteryAvailable = data['available'] as bool? ?? false;
          });
        }
      case 'clipboard_content':
        final text = data['text'] as String? ?? '';
        final error = data['error'] as String?;
        if (mounted) setState(() => _clipInFlight = false);
        if (error != null && error.isNotEmpty) {
          _showToast('Clipboard error: $error', error: true);
        } else if (text.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: text)).then((_) {
            _showToast('PC clipboard copied to phone ✓');
          });
        } else {
          _showToast('PC clipboard is empty.', error: false);
        }
    }
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _volumeOsdTimer?.cancel();
    _pingTimer = Timer.periodic(
        const Duration(milliseconds: _pingIntervalMs), (_) => _sendPing());
  }

  void _sendPing() {
    if (_connStatus != _ConnStatus.connected) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _conn.send(json.encode({'type': 'ping', 'ts': ts}));
    Future.delayed(const Duration(milliseconds: _pingTimeoutMs), () {
      if (!mounted) return;
      final elapsed = DateTime.now().millisecondsSinceEpoch - ts;
      if ((_rttMs == null || elapsed > _pingTimeoutMs) &&
          _connStatus == _ConnStatus.connected) {
        setState(() {
          _missedPongs++;
          if (_missedPongs >= _maxMissedPongs) _rttMs = null;
        });
      }
    });
  }

  Future<void> _pushClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) {
      _showToast('Phone clipboard is empty.');
      return;
    }
    _conn.send(json.encode({'type': 'clipboard_push', 'text': text}));
    _showToast('Sent to PC clipboard ✓');
  }

  void _pullClipboard() {
    if (_clipInFlight) return;
    setState(() => _clipInFlight = true);
    _conn.send(json.encode({'type': 'clipboard_pull'}));
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted && _clipInFlight) setState(() => _clipInFlight = false);
    });
  }

  void _showToast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg,
          style: const TextStyle(
              fontWeight: FontWeight.w600, fontSize: 13)),
      backgroundColor: error
          ? _C.danger.withOpacity(0.92)
          : _C.success.withOpacity(0.92),
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 80),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  Future<void> _triggerUnlock() async {
    if (_unlockInFlight) return;
    final auth = LocalAuthentication();
    bool canAuth = false;
    try {
      canAuth =
          await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } catch (_) {}
    if (!canAuth) {
      _showUnlockFeedback(
          false, 'No biometric or device auth available.');
      return;
    }
    bool authenticated = false;
    try {
      authenticated = await auth.authenticate(
        localizedReason: 'Authenticate to unlock your laptop',
        options: const AuthenticationOptions(
            biometricOnly: false,
            stickyAuth: true,
            sensitiveTransaction: false),
      );
    } catch (e) {
      // try again without any options
      try {
        authenticated = await auth.authenticate(
          localizedReason: 'Authenticate to unlock your laptop',
        );
      } catch (e2) {
        _showUnlockFeedback(false, 'Auth error: $e2');
        return;
      }
    }
    if (!authenticated) return;
    _Haptics.drag();
    setState(() => _unlockInFlight = true);
    _send('quick_unlock');
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted && _unlockInFlight) {
        setState(() => _unlockInFlight = false);
        _showUnlockFeedback(false, 'No response from server.');
      }
    });
  }

  void _showUnlockFeedback(bool success, String msg) {
    if (!mounted) return;
    final alreadyUnlocked = msg == 'already_unlocked';
    final text = alreadyUnlocked
        ? 'Screen was already unlocked'
        : success
            ? 'Laptop unlocked ✓'
            : 'Unlock failed: $msg';
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text,
          style: const TextStyle(
              fontWeight: FontWeight.w600, fontSize: 13)),
      backgroundColor: (success || alreadyUnlocked)
          ? _C.success.withOpacity(0.92)
          : _C.danger.withOpacity(0.92),
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 80),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // ── FLOATING OVERLAY ─────────────────────────────────────────────
  Future<void> _startOverlay() async {
    try {
      final granted = await _overlayChannel.invokeMethod<bool>('requestPermission') ?? false;
      if (!granted) {
        _showToast('Draw over apps permission required.', error: true);
        return;
      }
      await _overlayChannel.invokeMethod('start', {
        'wsUrl': widget.wsUrl,
        'serverKey': widget.serverKey,
        'sensitivity': _sensitivity,
        'scrollSpeed': _scrollSpeed,
        'naturalScroll': _naturalScroll,
      });
      if (mounted) setState(() => _overlayActive = true);
      _overlayChannel.setMethodCallHandler(_handleOverlayEvent);
    } catch (e) {
      _showToast('Overlay failed: $e', error: true);
    }
  }

  Future<void> _stopOverlay() async {
    try {
      await _overlayChannel.invokeMethod('stop');
    } catch (_) {}
    _overlayChannel.setMethodCallHandler(null);
    if (mounted) setState(() => _overlayActive = false);
  }

  Future<dynamic> _handleOverlayEvent(MethodCall call) async {
    switch (call.method) {
      case 'send':
        final payload = call.arguments as String?;
        if (payload != null) {
          try {
            final decoded = json.decode(payload) as Map<String, dynamic>;
            final t = decoded['type'] as String? ?? '';
            if (t == '_overlay_close') {
              if (mounted) setState(() => _overlayActive = false);
              return;
            }
            // Drawer removed from overlay — no _overlay_drawer handling
          } catch (_) {}
          _conn.send(payload);
        }
        break;
      case 'dismiss':
        if (mounted) setState(() => _overlayActive = false);
        break;
    }
  }

  Widget _unlockButton() {
    return GestureDetector(
        onTap: _unlockInFlight ? null : _triggerUnlock,
        child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 48,
            decoration: BoxDecoration(
                color: _unlockInFlight
                    ? _C.accentB.withOpacity(0.15)
                    : _C.accentC.withOpacity(0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: _unlockInFlight
                        ? _C.accentB.withOpacity(0.5)
                        : _C.accentC.withOpacity(0.4),
                    width: 1.0)),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_unlockInFlight)
                    const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                            color: _C.accentC, strokeWidth: 2))
                  else
                    const Icon(Icons.fingerprint_rounded,
                        color: _C.accentC, size: 20),
                  const SizedBox(width: 8),
                  Text(
                      _unlockInFlight
                          ? 'Unlocking…'
                          : 'Unlock laptop',
                      style: TextStyle(
                          color: _unlockInFlight
                              ? _C.accentB
                              : _C.accentC,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ])));
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _naturalScroll = prefs.getBool(_kNatScroll) ?? false;
      _momFeel = prefs.getDouble('mom_feel') ?? 0.80;
      final hIdx = prefs.getInt(_kHaptic) ?? HapticProfile.medium.index;
      _Haptics.profile = HapticProfile.values[
          hIdx.clamp(0, HapticProfile.values.length - 1)];
      final rawSlots = prefs.getStringList(_kCustomSlots) ?? [];
      _customSlots = rawSlots.map((s) {
        try {
          return CustomSlot.fromJson(
              json.decode(s) as Map<String, dynamic>);
        } catch (_) {
          return null;
        }
      }).whereType<CustomSlot>().toList();

      final rawPanels = prefs.getStringList(_kPanelOrder);
      if (rawPanels != null && rawPanels.isNotEmpty) {
        try {
          final loaded = rawPanels
              .map((s) => PanelConfig.fromJson(
                  json.decode(s) as Map<String, dynamic>))
              .toList();
          final existing = loaded.map((p) => p.type).toSet();
          for (final def in _defaultPanels()) {
            if (!existing.contains(def.type)) loaded.add(def);
          }
          _panels = loaded;
        } catch (_) {
          _panels = _defaultPanels();
        }
      }
    });
    _loadUnlockEnabled(widget.serverKey).then((v) {
      if (mounted) setState(() => _unlockEnabled = v);
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNatScroll, _naturalScroll);
    await prefs.setDouble('mom_feel', _momFeel);
    await prefs.setInt(_kHaptic, _Haptics.profile.index);
    await prefs.setStringList(_kCustomSlots,
        _customSlots.map((s) => json.encode(s.toJson())).toList());
    await prefs.setStringList(_kPanelOrder,
        _panels.map((p) => json.encode(p.toJson())).toList());
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _volumeOsdTimer?.cancel();
    _batteryTimer?.cancel();
    _drawerCtrl.dispose();
    if (_overlayActive) _stopOverlay();
    WakelockPlus.disable();
    if (_altHeld) _conn.send(json.encode({'type': 'alt_up'}));
    _conn.dispose();
    super.dispose();
  }

  void _send(String type) => _conn.send(json.encode({'type': type}));
  void _sendMap(Map<String, dynamic> m) => _conn.send(json.encode(m));

  Future<void> _unpairDevice() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              backgroundColor: _C.card,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Text('Unpair Device?',
                  style: TextStyle(
                      color: _C.textHi,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              content: const Text(
                  'This device will need to pair with a PIN again on the next connection.',
                  style:
                      TextStyle(color: _C.textMid, fontSize: 13)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel',
                        style: TextStyle(color: _C.textMid))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Unpair',
                        style: TextStyle(
                            color: _C.danger,
                            fontWeight: FontWeight.w700))),
              ],
            ));
    if (confirmed != true) return;
    _send('unpair');
    await _clearSessionToken(widget.serverKey);
    if (mounted) {
      _conn.disconnect();
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ConnectionScreen()));
    }
  }

  void _onSwitchLongPress() {
    if (_altHeld) return;
    _Haptics.drag();
    setState(() => _altHeld = true);
    _send('alt_down');
  }

  void _onSwitchTap() {
    if (_altHeld) {
      _Haptics.click();
      setState(() => _altHeld = false);
      _send('alt_up');
    } else {
      _Haptics.rightClick();
      _send('alt_tab');
    }
  }

  void _onNextTap() {
    if (!_altHeld) return;
    _Haptics.key();
    _send('alt_tab_next');
  }

  void _showSettings() {
    // Disable the touchpad Listener before opening settings so the
    // sheet's sliders / switches / buttons receive touches normally.
    setState(() => _touchpadEnabled = false);
    showModalBottomSheet(
        context: context,
        backgroundColor: _C.card,
        isScrollControlled: true,
        useRootNavigator: true,
        shape: const RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(24))),
        builder: (ctx) => _SettingsSheet(
              sensitivity: _sensitivity,
              scrollSpeed: _scrollSpeed,
              naturalScroll: _naturalScroll,
              momFeel: _momFeel,
              hapticProfile: _Haptics.profile,
              unlockEnabled: _unlockEnabled,
              serverKey: widget.serverKey,
              onChanged: (sens, scroll, nat, mom, haptic, unlock) {
                setState(() {
                  _sensitivity = sens;
                  _scrollSpeed = scroll;
                  _naturalScroll = nat;
                  _momFeel = mom;
                  _Haptics.profile = haptic;
                  _unlockEnabled = unlock;
                });
                _savePrefs();
                _saveUnlockEnabled(widget.serverKey, unlock);
              },
              onUnpair: () {
                Navigator.pop(ctx);
                _unpairDevice();
              },
            )).then((_) {
      // Re-enable touchpad when the sheet is dismissed
      if (mounted) setState(() => _touchpadEnabled = true);
    });
  }

  Widget _statusBar() {
    final dotColor = switch (_connStatus) {
      _ConnStatus.connected => _C.accentC,
      _ConnStatus.reconnecting => _C.amber,
      _ConnStatus.failed => _C.danger,
    };

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(children: [
            AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                    color: dotColor, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Icon(Icons.lock_rounded, color: dotColor, size: 11),
            const SizedBox(width: 4),
            Text(widget.serverAddress,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(
                    color: _C.textMid,
                    fontSize: 10,
                    letterSpacing: 0.3)),
            if (_batteryAvailable) ...[
              const SizedBox(width: 4),
              Icon(
                _batteryCharging
                    ? Icons.battery_charging_full_rounded
                    : _batteryLevel > 80
                        ? Icons.battery_full_rounded
                        : _batteryLevel > 50
                            ? Icons.battery_5_bar_rounded
                            : _batteryLevel > 20
                                ? Icons.battery_3_bar_rounded
                                : Icons.battery_1_bar_rounded,
                color: _batteryLevel <= 20
                    ? _C.danger
                    : _batteryCharging
                        ? _C.accentC
                        : _C.textMid,
                size: 12,
              ),
              const SizedBox(width: 1),
              Text('$_batteryLevel%',
                  style: TextStyle(
                      color: _batteryLevel <= 20
                          ? _C.danger
                          : _batteryCharging
                              ? _C.accentC
                              : _C.textMid,
                      fontSize: 9,
                      fontWeight: FontWeight.w600)),
            ],
            if (_volumeOsdVisible) ...[
              const SizedBox(width: 6),
              Icon(
                _volumeMuted
                    ? Icons.volume_off_rounded
                    : _volumeLevel == 0
                        ? Icons.volume_mute_rounded
                        : _volumeLevel < 50
                            ? Icons.volume_down_rounded
                            : Icons.volume_up_rounded,
                color: _volumeMuted ? _C.danger : _C.accentA,
                size: 12,
              ),
              const SizedBox(width: 2),
              Text(
                _volumeMuted ? 'Muted' : '$_volumeLevel%',
                style: TextStyle(
                    color: _volumeMuted ? _C.danger : _C.accentA,
                    fontSize: 9,
                    fontWeight: FontWeight.w600),
              ),
            ],
            const Spacer(),
            // Scrollable toolbar buttons
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                if (_portraitLocked) ...[
                  _tb(Icons.rotate_left_rounded, false, 'Landscape Left', () {
                    setState(() => _portraitLocked = false);
                    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
                  }),
                  _tb(Icons.rotate_right_rounded, false, 'Landscape Right', () {
                    setState(() => _portraitLocked = false);
                    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeRight]);
                  }),
                ] else
                  _tb(Icons.screen_lock_portrait_rounded, false, 'Lock to Portrait', () {
                    setState(() => _portraitLocked = true);
                    SystemChrome.setPreferredOrientations([
                      DeviceOrientation.portraitUp,
                      DeviceOrientation.portraitDown,
                    ]);
                  }),
                _tb(Icons.search_rounded, _zoomMode,
                    _zoomMode ? 'Zoom ON' : 'Zoom OFF',
                    () => setState(() => _zoomMode = !_zoomMode)),
                _tb(Icons.fullscreen_rounded, _fullscreen,
                    _fullscreen ? 'Exit Fullscreen' : 'Fullscreen',
                    () => setState(() => _fullscreen = !_fullscreen)),
                _tb(Icons.tune_rounded, false, 'Settings', _showSettings),
                _tb(Icons.picture_in_picture_rounded, _overlayActive, 'Float',
                    () => _overlayActive ? _stopOverlay() : _startOverlay(),
                    activeColor: _C.accentC),
                _tb(Icons.power_settings_new_rounded, false, 'Disconnect', () {
                  _conn.disconnect();
                  Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const ConnectionScreen()));
                }, danger: true),
              ]),
            ),
          ])),
      if (_connStatus != _ConnStatus.connected)
        AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 6),
            color: (_connStatus == _ConnStatus.failed
                    ? _C.danger
                    : _C.amber)
                .withOpacity(0.12),
            child: Row(children: [
              if (_connStatus == _ConnStatus.reconnecting)
                const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                        color: _C.amber, strokeWidth: 1.5))
              else
                const Icon(Icons.wifi_off_rounded,
                    color: _C.danger, size: 12),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                _connDetail.isNotEmpty
                    ? _connDetail
                    : (_connStatus == _ConnStatus.reconnecting
                        ? 'Reconnecting\u2026'
                        : 'Connection lost'),
                style: TextStyle(
                    color: _connStatus == _ConnStatus.failed
                        ? _C.danger
                        : _C.amber,
                    fontSize: 11),
              )),
              if (_connStatus == _ConnStatus.failed)
                GestureDetector(
                    onTap: () {
                      _conn.disconnect();
                      Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                              builder: (_) =>
                                  const ConnectionScreen()));
                    },
                    child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                            color: _C.danger.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: _C.danger.withOpacity(0.3))),
                        child: const Text('Go back',
                            style: TextStyle(
                                color: _C.danger,
                                fontSize: 10,
                                fontWeight: FontWeight.w600)))),
            ])),
    ]);
  }

  Widget _tb(IconData icon, bool active, String tip, VoidCallback onTap,
      {bool danger = false, Color? activeColor}) {
    final color = danger
        ? _C.danger
        : active
            ? (activeColor ?? _C.accentA)
            : _C.textMid;
    return Tooltip(
        message: tip,
        child: GestureDetector(
            onTap: onTap,
            child: Container(
                width: 34,
                height: 34,
                margin: const EdgeInsets.only(left: 2),
                decoration: active
                    ? BoxDecoration(
                        color: (activeColor ?? _C.accentA)
                            .withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: (activeColor ?? _C.accentA)
                                .withOpacity(0.3)))
                    : null,
                child: Icon(icon, color: color, size: 18))));
  }

  Widget _buildPanelContent(PanelConfig panel) {
    switch (panel.type) {
      case PanelType.shortcuts:
        return _shortcutsPanel();
      case PanelType.altTab:
        return _altTabPanel();
      case PanelType.arrows:
        return _arrowsPanel();
      case PanelType.media:
        return _mediaPanel();
      case PanelType.keyboard:
        return _keyboardPanel();
      case PanelType.system:
        return _systemPanel();
      case PanelType.customSlots:
        return _customSlotsPanel();
    }
  }

  String _panelTitle(PanelConfig panel) => panel.label.toUpperCase();

  Widget _shortcutsPanel() {
    Widget btn(String label, IconData icon, String type) =>
        Expanded(
            child: _MiniPressButton(
                label: label,
                icon: icon,
                iconSize: 15,
                fontSize: 9,
                onTap: () {
                  _Haptics.key();
                  _send(type);
                }));
    return Column(children: [
      SizedBox(
          height: 40,
          child: Row(children: [
            btn('Copy', Icons.copy_rounded, 'shortcut_copy'),
            const SizedBox(width: 5),
            btn('Paste', Icons.paste_rounded, 'shortcut_paste'),
            const SizedBox(width: 5),
            btn('Undo', Icons.undo_rounded, 'shortcut_undo'),
            const SizedBox(width: 5),
            btn('Cls Tab', Icons.tab_unselected_rounded,
                'shortcut_close_tab'),
            const SizedBox(width: 5),
            btn('Desktop', Icons.desktop_windows_rounded,
                'shortcut_show_desktop'),
          ])),
      const SizedBox(height: 5),
      SizedBox(
          height: 36,
          child: Row(children: [
            Expanded(
                child: _MiniPressButton(
                    label: '↗ Send clip',
                    icon: Icons.upload_rounded,
                    iconSize: 13,
                    fontSize: 8,
                    onTap: () {
                      _Haptics.key();
                      _pushClipboard();
                    })),
            const SizedBox(width: 5),
            Expanded(
                child: _MiniPressButton(
                    label: _clipInFlight ? 'Fetching…' : '↘ Get clip',
                    icon: _clipInFlight
                        ? Icons.hourglass_empty_rounded
                        : Icons.download_rounded,
                    iconSize: 13,
                    fontSize: 8,
                    active: _clipInFlight,
                    activeColor: _C.accentB,
                    onTap: _clipInFlight
                        ? () {}
                        : () {
                            _Haptics.key();
                            _pullClipboard();
                          })),
          ])),
    ]);
  }

  Widget _systemPanel() {
    return Column(children: [
      SizedBox(
        height: 44,
        child: Row(children: [
          Expanded(
            child: _MiniPressButton(
              label: 'Lock',
              icon: Icons.lock_rounded,
              iconSize: 15,
              fontSize: 9,
              onTap: () {
                _Haptics.key();
                _send('system_lock');
                _showToast('Laptop locked');
              },
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: _MiniPressButton(
              label: 'Shutdown',
              icon: Icons.power_settings_new_rounded,
              iconSize: 15,
              fontSize: 9,
              activeColor: _C.danger,
              onTap: () {
                _Haptics.key();
                _showSystemConfirm(
                  'Shutdown in 10 seconds?',
                  'system_shutdown',
                  'Shutting down…',
                );
              },
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: _MiniPressButton(
              label: 'Restart',
              icon: Icons.restart_alt_rounded,
              iconSize: 15,
              fontSize: 9,
              activeColor: _C.amber,
              onTap: () {
                _Haptics.key();
                _showSystemConfirm(
                  'Restart in 10 seconds?',
                  'system_restart',
                  'Restarting…',
                );
              },
            ),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        const Icon(Icons.brightness_6_rounded, color: _C.textLo, size: 14),
        const SizedBox(width: 8),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: _C.accentA,
              inactiveTrackColor: _C.border,
              thumbColor: _C.accentA,
              overlayColor: _C.accentA.withOpacity(0.15),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: _brightnessLevel.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              onChanged: (v) {
                setState(() => _brightnessLevel = v.round());
              },
              onChangeEnd: (v) {
                _sendMap({'type': 'brightness_set', 'level': v.round()});
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 32,
          child: Text(
            '$_brightnessLevel%',
            style: const TextStyle(color: _C.textMid, fontSize: 11),
            textAlign: TextAlign.right,
          ),
        ),
      ]),
    ]);
  }

  void _showSystemConfirm(String message, String eventType, String toast) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(message,
            style: const TextStyle(
                color: _C.textHi,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
        content: const Text('You can cancel within 10 seconds.',
            style: TextStyle(color: _C.textMid, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: _C.textMid)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _send(eventType);
              _showToast(toast);
              // Show cancel option
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: const Text('Tap UNDO to cancel',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                backgroundColor: _C.amber.withOpacity(0.92),
                duration: const Duration(seconds: 9),
                behavior: SnackBarBehavior.floating,
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 80),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                action: SnackBarAction(
                  label: 'UNDO',
                  textColor: Colors.white,
                  onPressed: () => _send('system_cancel_shutdown'),
                ),
              ));
            },
            child: Text(
              eventType == 'system_shutdown' ? 'Shutdown' : 'Restart',
              style: const TextStyle(
                  color: _C.danger, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _altTabPanel() => SizedBox(
      height: 44,
      child: Row(children: [
        Expanded(
            child: _AltSwitchButton(
                altHeld: _altHeld,
                onTap: _onSwitchTap,
                onLongPress: _onSwitchLongPress)),
        const SizedBox(width: 8),
        Expanded(
            child: _MiniPressButton(
                label: _altHeld ? 'Next ›' : 'Next',
                icon: Icons.skip_next_rounded,
                onTap: _onNextTap,
                active: _altHeld,
                activeColor: _C.amber,
                iconSize: 15,
                fontSize: 9)),
      ]));

  Widget _arrowsPanel() {
    Widget arr(IconData icon, String downType, String upType) =>
        _ArrowBtn(
          icon: icon,
          height: 28,
          onDown: () {
            _Haptics.key();
            _send(downType);
          },
          onUp: () {
            _send(upType);
          },
        );
    return SizedBox(
        height: 64,
        child: Row(children: [
          Expanded(
              child:
                  arr(Icons.arrow_back_rounded, 'arrow_left_down', 'arrow_left_up')),
          const SizedBox(width: 4),
          Expanded(
              child: Column(children: [
            Expanded(
                child: arr(Icons.arrow_upward_rounded, 'arrow_up_down',
                    'arrow_up_up')),
            const SizedBox(height: 4),
            Expanded(
                child: arr(Icons.arrow_downward_rounded, 'arrow_down_down',
                    'arrow_down_up')),
          ])),
          const SizedBox(width: 4),
          Expanded(
              child: arr(Icons.arrow_forward_rounded, 'arrow_right_down',
                  'arrow_right_up')),
        ]));
  }

  Widget _mediaPanel() {
    Widget tapBtn(IconData icon, String type,
            {Color color = _C.textMid}) =>
        Expanded(
            child: _MiniPressButton(
                label: '',
                icon: icon,
                iconSize: 18,
                fontSize: 0,
                activeColor: color,
                onTap: () {
                  _Haptics.key();
                  _send(type);
                  if (type == 'media_mute') {
                    Future.delayed(const Duration(milliseconds: 300), () {
                      if (mounted) _send('volume_get');
                    });
                  }
                }));
    Widget holdBtn(IconData icon, String downType, String upType, {bool isVol = false, int volDelta = 0}) =>
        Expanded(
            child: _MediaHoldButton(
                icon: icon,
                iconSize: 18,
                onDown: () {
                  _Haptics.key();
                  _send(downType);
                  if (isVol && volDelta != 0) {
                    setState(() {
                      _volumeLevel = (_volumeLevel + volDelta).clamp(0, 100);
                      _volumeMuted = false;
                      _volumeOsdVisible = true;
                    });
                    _volumeOsdTimer?.cancel();
                    _volumeOsdTimer = Timer(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _volumeOsdVisible = false);
                    });
                  }
                },
                onUp: () => _send(upType)));
    return Column(children: [
      SizedBox(
          height: 48,
          child: Row(children: [
            holdBtn(Icons.skip_previous_rounded, 'media_prev_down', 'media_prev_up'),
            const SizedBox(width: 4),
            tapBtn(Icons.play_circle_filled_rounded, 'media_play_pause', color: _C.media),
            const SizedBox(width: 4),
            holdBtn(Icons.skip_next_rounded, 'media_next_down', 'media_next_up'),
            const SizedBox(width: 8),
            holdBtn(Icons.volume_down_rounded, 'media_vol_down_down', 'media_vol_down_up', isVol: true),
            const SizedBox(width: 4),
            tapBtn(Icons.volume_mute_rounded, 'media_mute'),
            const SizedBox(width: 4),
            holdBtn(Icons.volume_up_rounded, 'media_vol_up_down', 'media_vol_up_up', isVol: true),
          ])),
    ]);
  }

  Widget _mediaPanelLandscape() {
    Widget tapBtn(IconData icon, String type, {Color color = _C.textMid}) =>
        Expanded(
            child: _MiniPressButton(
                label: '',
                icon: icon,
                iconSize: 18,
                fontSize: 0,
                activeColor: color,
                onTap: () {
                  _Haptics.key();
                  _send(type);
                  if (type == 'media_mute') {
                    setState(() {
                      _volumeMuted = !_volumeMuted;
                      _volumeOsdVisible = true;
                    });
                    _volumeOsdTimer?.cancel();
                    _volumeOsdTimer = Timer(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _volumeOsdVisible = false);
                    });
                  }
                }));
    Widget holdBtn(IconData icon, String downType, String upType,
            {bool isVol = false, int volDelta = 0}) =>
        Expanded(
            child: _MediaHoldButton(
                icon: icon,
                iconSize: 18,
                onDown: () {
                  _Haptics.key();
                  _send(downType);
                  if (isVol && volDelta != 0) {
                    setState(() {
                      _volumeLevel = (_volumeLevel + volDelta).clamp(0, 100);
                      _volumeMuted = false;
                      _volumeOsdVisible = true;
                    });
                    _volumeOsdTimer?.cancel();
                    _volumeOsdTimer = Timer(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _volumeOsdVisible = false);
                    });
                  }
                },
                onUp: () => _send(upType)));
    return Column(children: [
      SizedBox(
          height: 40,
          child: Row(children: [
            holdBtn(Icons.skip_previous_rounded, 'media_prev_down', 'media_prev_up'),
            const SizedBox(width: 4),
            tapBtn(Icons.play_circle_filled_rounded, 'media_play_pause', color: _C.media),
            const SizedBox(width: 4),
            holdBtn(Icons.skip_next_rounded, 'media_next_down', 'media_next_up'),
          ])),
      const SizedBox(height: 5),
      SizedBox(
          height: 40,
          child: Row(children: [
            holdBtn(Icons.volume_down_rounded, 'media_vol_down_down', 'media_vol_down_up', isVol: true, volDelta: -2),
            const SizedBox(width: 4),
            tapBtn(Icons.volume_mute_rounded, 'media_mute'),
            const SizedBox(width: 4),
            holdBtn(Icons.volume_up_rounded, 'media_vol_up_down', 'media_vol_up_up', isVol: true, volDelta: 2),
          ])),
    ]);
  }

  Widget _keyboardPanel() => _KeyboardPanel(
        onTypeText: (t) => _sendMap({'type': 'type_text', 'text': t}),
        onBackspace: () => _send('key_backspace'),
        onEnter: () => _send('key_enter'),
        onNewline: () => _send('key_newline'),
        onTab: () => _send('key_tab'),
        onEscape: () => _send('key_escape'),
      );

  Widget _customSlotsPanel() {
    const h = 40.0;
    final allItems = <Widget>[
      ..._customSlots.asMap().entries.map((e) {
        final slot = e.value;
        final idx = e.key;
        return SizedBox(
            height: h,
            child: GestureDetector(
                onLongPress: () {
                  _Haptics.key();
                  _confirmDeleteSlot(idx);
                },
                child: _MiniPressButton(
                    label: slot.label,
                    icon: Icons.keyboard_rounded,
                    iconSize: 13,
                    fontSize: 8,
                    onTap: () {
                      _Haptics.key();
                      _sendMap({
                        'type': 'custom_shortcut',
                        'combo': slot.combo
                      });
                    })));
      }),
      SizedBox(
          height: h,
          width: h,
          child: GestureDetector(
              onTap: _showAddSlotDialog,
              child: Container(
                  decoration: BoxDecoration(
                      color: _C.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _C.border)),
                  child: const Icon(Icons.add_rounded,
                      color: _C.textMid, size: 16)))),
    ];
    if (allItems.length == 1) return Row(children: [allItems.first]);
    final rows = <Widget>[];
    for (int i = 0; i < allItems.length; i += 4) {
      final chunk =
          allItems.sublist(i, (i + 4).clamp(0, allItems.length));
      rows.add(Padding(
          padding: EdgeInsets.only(
              bottom: i + 4 < allItems.length ? 6 : 0),
          child: Row(
              children: chunk
                  .expand(
                      (w) => [Expanded(child: w), const SizedBox(width: 5)])
                  .toList()
                ..removeLast())));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  void _confirmDeleteSlot(int idx) {
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              backgroundColor: _C.card,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Text('Delete "${_customSlots[idx].label}"?',
                  style: const TextStyle(
                      color: _C.textHi,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              content: Text(_customSlots[idx].combo,
                  style: const TextStyle(
                      color: _C.textMid, fontSize: 12)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel',
                        style: TextStyle(color: _C.textMid))),
                TextButton(
                    onPressed: () {
                      setState(() => _customSlots.removeAt(idx));
                      _savePrefs();
                      Navigator.pop(ctx);
                    },
                    child: const Text('Delete',
                        style: TextStyle(
                            color: _C.danger,
                            fontWeight: FontWeight.w700))),
              ],
            ));
  }

  void _showAddSlotDialog() {
    final labelCtrl = TextEditingController();
    final comboCtrl = TextEditingController();
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              backgroundColor: _C.card,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18)),
              title: const Text('Add Shortcut Slot',
                  style: TextStyle(
                      color: _C.textHi,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: labelCtrl,
                    style: const TextStyle(color: _C.textHi),
                    decoration:
                        _inputDeco('Label (e.g. Reopen Tab)')),
                const SizedBox(height: 12),
                TextField(
                    controller: comboCtrl,
                    style: const TextStyle(color: _C.textHi),
                    decoration:
                        _inputDeco('Combo (e.g. ctrl+shift+t)'),
                    autocorrect: false),
                const SizedBox(height: 8),
                const Text(
                    'Modifiers: ctrl, shift, alt, win\nKeys: a-z, 0-9, f1-f12, enter, esc, tab…',
                    style: TextStyle(color: _C.textLo, fontSize: 10)),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel',
                        style: TextStyle(color: _C.textMid))),
                TextButton(
                    onPressed: () {
                      final label = labelCtrl.text.trim();
                      final combo =
                          comboCtrl.text.trim().toLowerCase();
                      if (label.isNotEmpty && combo.isNotEmpty) {
                        setState(() => _customSlots.add(
                            CustomSlot(label: label, combo: combo)));
                        _savePrefs();
                      }
                      Navigator.pop(ctx);
                    },
                    child: const Text('Add',
                        style: TextStyle(
                            color: _C.accentA,
                            fontWeight: FontWeight.w700))),
              ],
            ));
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: _C.textLo, fontSize: 13),
      filled: true,
      fillColor: _C.surface,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _C.border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _C.border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide:
              const BorderSide(color: _C.accentA, width: 1.5)));

  Widget _clickButtons() => Row(children: [
        Expanded(
            child: _PressButton(
                label: 'Left',
                icon: Icons.mouse_outlined,
                onTap: () {
                  _Haptics.click();
                  _send('left_click');
                })),
        const SizedBox(width: 6),
        Expanded(
            child: _PressButton(
                label: 'Middle',
                icon: Icons.circle_outlined,
                onTap: () {
                  _Haptics.key();
                  _send('middle_click');
                })),
        const SizedBox(width: 6),
        Expanded(
            child: _PressButton(
                label: 'Right',
                icon: Icons.ads_click_outlined,
                onTap: () {
                  _Haptics.rightClick();
                  _send('right_click');
                })),
      ]);

  Widget _canvas() => TouchpadCanvas(
      onSend: _conn.send,
      sensitivity: _sensitivity,
      scrollSpeed: _scrollSpeed,
      zoomModeEnabled: _zoomMode,
      naturalScroll: _naturalScroll,
      momFeel: _momFeel,
      enabled: _touchpadEnabled);

  Widget _pinnedArea() {
    final pinnedPanels = _panels.where((p) => p.pinned).toList();
    if (pinnedPanels.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: pinnedPanels.map((panel) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(panel.icon, color: _C.textLo, size: 10),
                  const SizedBox(width: 5),
                  Text(_panelTitle(panel),
                      style: const TextStyle(
                          color: _C.textLo,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2)),
                  const SizedBox(width: 8),
                  Expanded(child: Container(height: 0.5, color: _C.border)),
                  const SizedBox(width: 6),
                  GestureDetector(
                      onTap: () {
                        setState(() => panel.pinned = false);
                        _savePrefs();
                      },
                      child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                              color: _C.accentA.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: _C.accentA.withOpacity(0.3))),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.push_pin_rounded,
                                size: 9, color: _C.accentA),
                            const SizedBox(width: 4),
                            const Text('Unpin',
                                style: TextStyle(
                                    color: _C.accentA,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600)),
                          ]))),
                ]),
                const SizedBox(height: 6),
                _buildPanelContent(panel),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _drawerEditTile(int index) {
    final panel = _panels[index];
    return Container(
      key: ValueKey('edit_${panel.key}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
          color: _C.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _C.border)),
      child: Row(children: [
        const Icon(Icons.drag_indicator_rounded,
            color: _C.textLo, size: 18),
        const SizedBox(width: 8),
        Icon(panel.icon, color: _C.textMid, size: 15),
        const SizedBox(width: 8),
        Expanded(
            child: Text(panel.label,
                style: const TextStyle(
                    color: _C.textHi,
                    fontSize: 13,
                    fontWeight: FontWeight.w600))),
        GestureDetector(
            onTap: () {
              setState(() => panel.pinned = !panel.pinned);
              _savePrefs();
            },
            child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                    color: panel.pinned
                        ? _C.accentA.withOpacity(0.15)
                        : _C.card,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                        color: panel.pinned
                            ? _C.accentA.withOpacity(0.4)
                            : _C.border)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      panel.pinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      size: 11,
                      color: panel.pinned ? _C.accentA : _C.textLo),
                  const SizedBox(width: 4),
                  Text(panel.pinned ? 'Pinned' : 'Pin',
                      style: TextStyle(
                          color: panel.pinned ? _C.accentA : _C.textLo,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ]))),
        const SizedBox(width: 6),
        GestureDetector(
            onTap: () {
              setState(() => panel.visible = !panel.visible);
              _savePrefs();
            },
            child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                    color: panel.visible
                        ? _C.accentB.withOpacity(0.15)
                        : _C.card,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                        color: panel.visible
                            ? _C.accentB.withOpacity(0.4)
                            : _C.border)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      panel.visible
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      size: 11,
                      color: panel.visible ? _C.accentB : _C.textLo),
                  const SizedBox(width: 4),
                  Text(panel.visible ? 'In drawer' : 'Hidden',
                      style: TextStyle(
                          color: panel.visible ? _C.accentB : _C.textLo,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ]))),
      ]),
    );
  }

  Widget _portraitLayout() {
    final visiblePanels = _panels.where((p) => p.visible).toList();

    const double expandedFraction = 0.52;
    // FIX: Pull-tab height made larger so it's a proper tappable button
    const double tabH = 44.0;

    return LayoutBuilder(builder: (ctx, constraints) {
      final totalH = constraints.maxHeight;
      final statusBarH = 46.0;
      final clickH = 60.0;
      final unlockH = _unlockEnabled ? 56.0 : 0.0;

      final pinnedCount = _panels.where((p) => p.pinned).length;
      final pinnedH = pinnedCount > 0
          ? _panels.where((p) => p.pinned).fold<double>(0.0, (sum, p) {
              switch (p.type) {
                case PanelType.shortcuts: return sum + 95;
                case PanelType.altTab: return sum + 56;
                case PanelType.arrows: return sum + 76;
                case PanelType.media: return sum + 60;
                case PanelType.keyboard: return sum + 110;
                case PanelType.system: return sum + 100;
                case PanelType.customSlots: return sum + 56;
              }
            }) + pinnedCount * 24
          : 0.0;

      final canvasH = (totalH -
              statusBarH -
              clickH -
              unlockH -
              (pinnedCount > 0 ? (pinnedH + 8) : 0) -
              tabH)
          .clamp(80.0, double.infinity);

      return Stack(children: [
        // ── FIXED COLUMN (behind the drawer) ──────────────────────
        Column(children: [
          _statusBar(),
          SizedBox(
              height: canvasH,
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: _canvas())),
          if (_unlockEnabled)
            Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: _unlockButton()),
          SizedBox(
              height: clickH,
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: _clickButtons())),
          if (pinnedCount > 0) _pinnedArea(),
          const SizedBox(height: tabH),
        ]),

        // ── PULL-TAB STRIP (always visible at bottom) ─────────────
        // FIX: Made into a proper full-width button. Removed IgnorePointer
        // wrapping that was preventing touches in some states.
        Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: tabH,
            child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _drawerOpen ? 0.0 : 1.0,
                child: AbsorbPointer(
                    absorbing: _drawerOpen,
                    child: _pullTabStrip(visiblePanels)))),

        // ── DRAWER SHEET ──────────────────────────────────────────
        Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: totalH,
            child: NotificationListener<DraggableScrollableNotification>(
                onNotification: (n) {
                  final open = n.extent > 0.02;
                  if (open != _drawerOpen)
                    setState(() => _drawerOpen = open);
                  return false;
                },
                child: DraggableScrollableSheet(
                    controller: _drawerCtrl,
                    initialChildSize: 0.0,
                    minChildSize: 0.0,
                    maxChildSize: expandedFraction,
                    snap: true,
                    snapSizes: const [0.0, expandedFraction],
                    builder: (ctx, scrollCtrl) => Container(
                        decoration: BoxDecoration(
                            color: _C.surface,
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(20)),
                            border: Border(
                                top: BorderSide(
                                    color: _C.border, width: 0.5)),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withOpacity(0.4),
                                  blurRadius: 20,
                                  offset: const Offset(0, -4))
                            ]),
                        child: SingleChildScrollView(
                            controller: scrollCtrl,
                            physics: const ClampingScrollPhysics(),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _drawerHandle(visiblePanels),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (_editMode)
                                        _drawerEditMode()
                                      else
                                        ...visiblePanels
                                            .where((p) => !p.pinned)
                                            .map((panel) => Padding(
                                                padding: const EdgeInsets.only(bottom: 12),
                                                child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Row(children: [
                                                        Icon(panel.icon, color: _C.textLo, size: 10),
                                                        const SizedBox(width: 5),
                                                        Text(_panelTitle(panel),
                                                            style: const TextStyle(
                                                                color: _C.textLo,
                                                                fontSize: 9,
                                                                fontWeight: FontWeight.w700,
                                                                letterSpacing: 1.2)),
                                                        const SizedBox(width: 8),
                                                        Expanded(child: Container(height: 0.5, color: _C.border)),
                                                      ]),
                                                      const SizedBox(height: 6),
                                                      _buildPanelContent(panel),
                                                    ]))),
                                    ],
                                  ),
                                ),
                              ],
                            )))))),
      ]);
    });
  }

  Widget _drawerEditMode() {
    return Column(children: [
      Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: _C.amber.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: _C.amber.withOpacity(0.25))),
          child: const Row(children: [
            Icon(Icons.info_outline_rounded,
                color: _C.amber, size: 13),
            SizedBox(width: 8),
            Expanded(
                child: Text(
                    'Drag to reorder  ·  Pin = shows above mouse buttons  ·  Drawer = shows in this panel',
                    style: TextStyle(
                        color: _C.amber, fontSize: 10))),
          ])),
      ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _panels.length,
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _panels.removeAt(oldIndex);
              _panels.insert(newIndex, item);
            });
            _savePrefs();
          },
          proxyDecorator: (child, index, animation) => Material(
              color: Colors.transparent,
              child: ScaleTransition(
                  scale: Tween<double>(begin: 1.0, end: 1.03).animate(
                      CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOut)),
                  child: Container(
                      decoration: BoxDecoration(
                          color: _C.accentA.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: _C.accentA.withOpacity(0.4))),
                      child: child))),
          itemBuilder: (ctx, index) => _drawerEditTile(index)),
    ]);
  }

  // FIX: Completely redesigned pull-tab strip.
  // The "open drawer" button is now a proper large tappable area.
  // The settings/drawer items are clearly separated.
  // No more tiny arrow overlapping content.
  Widget _pullTabStrip(List<PanelConfig> visiblePanels) {
    final drawerOnlyPanels = visiblePanels.where((p) => !p.pinned).toList();
    final pinnedPanels = _panels.where((p) => p.pinned).toList();

    return Material(
      color: _C.surface,
      child: Container(
        decoration: BoxDecoration(
            border: Border(top: BorderSide(color: _C.border, width: 0.5)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 8,
                  offset: const Offset(0, -2))
            ]),
        child: Row(children: [
          // FIX: Large dedicated "Open drawer" button on the left
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _drawerOpen
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: InkWell(
              onTap: () {
                _drawerCtrl.animateTo(0.52,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut);
                setState(() => _drawerOpen = true);
              },
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                bottomLeft: Radius.circular(8),
              ),
              child: Container(
                width: 56,
                height: 44,
                decoration: BoxDecoration(
                    color: _C.accentA.withOpacity(0.08),
                    border: Border(right: BorderSide(color: _C.border, width: 0.5))),
                child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.keyboard_arrow_up_rounded,
                          color: _C.accentA, size: 22),
                      Text('Open',
                          style: TextStyle(
                              color: _C.accentA,
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                    ]),
              ),
            ),
            secondChild: InkWell(
              onTap: () {
                _drawerCtrl.animateTo(0.0,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOut);
                setState(() => _drawerOpen = false);
              },
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                bottomLeft: Radius.circular(8),
              ),
              child: Container(
                width: 56,
                height: 44,
                decoration: BoxDecoration(
                    color: _C.accentA.withOpacity(0.08),
                    border: Border(right: BorderSide(color: _C.border, width: 0.5))),
                child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.keyboard_arrow_down_rounded,
                          color: _C.accentA, size: 22),
                      Text('Close',
                          style: TextStyle(
                              color: _C.accentA,
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                    ]),
              ),
            ),
          ),
          // Scrollable panel chips
          Expanded(
              child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(children: [
                    // Pinned chips
                    ...pinnedPanels.map((p) => Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: Center(
                          child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                  color: _C.accentA.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                      color: _C.accentA.withOpacity(0.3))),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.push_pin_rounded,
                                    size: 8, color: _C.accentA),
                                const SizedBox(width: 3),
                                Text(p.label,
                                    style: const TextStyle(
                                        color: _C.accentA,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600)),
                              ])),
                        ))),
                    // Drawer-only chips
                    ...drawerOnlyPanels.map((p) => Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: Center(
                          child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                  color: _C.card,
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(color: _C.border)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(p.icon, color: _C.textMid, size: 9),
                                const SizedBox(width: 3),
                                Text(p.label,
                                    style: const TextStyle(
                                        color: _C.textMid,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600)),
                              ])),
                        ))),
                  ]))),
          // Edit button on the right
          InkWell(
            onTap: () {
              // Open drawer first if closed, then enable edit mode
              if (!_drawerOpen) {
                _drawerCtrl.animateTo(0.52,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut);
                setState(() => _drawerOpen = true);
              }
              setState(() => _editMode = !_editMode);
            },
            child: Container(
              width: 52,
              height: double.infinity,
              decoration: BoxDecoration(
                  color: _editMode ? _C.amber.withOpacity(0.12) : Colors.transparent,
                  border: Border(left: BorderSide(color: _C.border, width: 0.5))),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.edit_rounded,
                        color: _editMode ? _C.amber : _C.textLo,
                        size: 16),
                    const SizedBox(height: 2),
                    Text(_editMode ? 'Done' : 'Edit',
                        style: TextStyle(
                            color: _editMode ? _C.amber : _C.textLo,
                            fontSize: 8,
                            fontWeight: FontWeight.w700)),
                  ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _drawerHandle(List<PanelConfig> visiblePanels) {
    final drawerOnlyPanels =
        visiblePanels.where((p) => !p.pinned).toList();
    final pinnedPanels = _panels.where((p) => p.pinned).toList();

    return GestureDetector(
        behavior: HitTestBehavior.opaque,
        child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Center(
                  child: Container(
                      width: 32,
                      height: 3,
                      decoration: BoxDecoration(
                          color: _C.textLo.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(2)))),
              const SizedBox(width: 12),
              Expanded(
                  child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        ...pinnedPanels.map((p) => Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: GestureDetector(
                                onTap: () {
                                  setState(() => p.pinned = false);
                                  _savePrefs();
                                },
                                child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                        color: _C.accentA.withOpacity(0.15),
                                        borderRadius:
                                            BorderRadius.circular(6),
                                        border: Border.all(
                                            color: _C.accentA
                                                .withOpacity(0.4))),
                                    child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                              Icons.push_pin_rounded,
                                              size: 9,
                                              color: _C.accentA),
                                          const SizedBox(width: 4),
                                          Text(p.label,
                                              style: const TextStyle(
                                                  color: _C.accentA,
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w600)),
                                        ]))))),
                        ...drawerOnlyPanels.map((p) => Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                    color: _drawerOpen
                                        ? _C.accentB.withOpacity(0.15)
                                        : _C.card,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                        color: _drawerOpen
                                            ? _C.accentB.withOpacity(0.35)
                                            : _C.border)),
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(p.icon,
                                          color: _drawerOpen
                                              ? _C.accentB
                                              : _C.textMid,
                                          size: 11),
                                      const SizedBox(width: 4),
                                      Text(p.label,
                                          style: TextStyle(
                                              color: _drawerOpen
                                                  ? _C.accentB
                                                  : _C.textMid,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w600)),
                                    ])))),
                        GestureDetector(
                            onTap: () =>
                                setState(() => _editMode = !_editMode),
                            child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                    color: _editMode
                                        ? _C.amber.withOpacity(0.15)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                        color: _editMode
                                            ? _C.amber.withOpacity(0.4)
                                            : _C.border
                                                .withOpacity(0.5))),
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.edit_rounded,
                                          color: _editMode
                                              ? _C.amber
                                              : _C.textLo,
                                          size: 10),
                                      const SizedBox(width: 4),
                                      Text(_editMode ? 'Done' : 'Edit',
                                          style: TextStyle(
                                              color: _editMode
                                                  ? _C.amber
                                                  : _C.textLo,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w600)),
                                    ]))),
                      ]))),
            ])));
  }

  Widget _landscapeSidebar() =>
      SizedBox(width: 148, child: LayoutBuilder(builder: (ctx, constraints) {
        const altTabH = 44.0;
        const arrowsH = 64.0;
        const clickTotalH = 120.0;
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
              height: clickTotalH.clamp(0.0, double.infinity),
              child: Column(children: [
                Expanded(
                    child: _PressButton(
                        label: 'Left',
                        icon: Icons.mouse_outlined,
                        onTap: () {
                          _Haptics.click();
                          _send('left_click');
                        })),
                const SizedBox(height: 6),
                Expanded(
                    child: _PressButton(
                        label: 'Middle',
                        icon: Icons.circle_outlined,
                        onTap: () {
                          _Haptics.key();
                          _send('middle_click');
                        })),
                const SizedBox(height: 6),
                Expanded(
                    child: _PressButton(
                        label: 'Right',
                        icon: Icons.ads_click_outlined,
                        onTap: () {
                          _Haptics.rightClick();
                          _send('right_click');
                        })),
              ])),
          const SizedBox(height: 8),
          SizedBox(height: altTabH, child: _altTabPanel()),
          const SizedBox(height: 8),
          SizedBox(height: arrowsH, child: _arrowsPanel()),
          const SizedBox(height: 8),
          _shortcutsLandscape(),
          const SizedBox(height: 8),
          _mediaPanelLandscape(),
          if (_unlockEnabled) ...[
            const SizedBox(height: 8),
            _unlockButton(),
          ],
        ]));
      }));

  Widget _shortcutsLandscape() => Column(children: [
        Row(children: [
          Expanded(
              child: _MiniPressButton(
                  label: 'Copy',
                  icon: Icons.copy_rounded,
                  onTap: () {
                    _Haptics.key();
                    _send('shortcut_copy');
                  })),
          const SizedBox(width: 5),
          Expanded(
              child: _MiniPressButton(
                  label: 'Paste',
                  icon: Icons.paste_rounded,
                  onTap: () {
                    _Haptics.key();
                    _send('shortcut_paste');
                  })),
          const SizedBox(width: 5),
          Expanded(
              child: _MiniPressButton(
                  label: 'Undo',
                  icon: Icons.undo_rounded,
                  onTap: () {
                    _Haptics.key();
                    _send('shortcut_undo');
                  })),
        ]),
        const SizedBox(height: 5),
        Row(children: [
          Expanded(
              child: _MiniPressButton(
                  label: 'Cls Tab',
                  icon: Icons.tab_unselected_rounded,
                  onTap: () {
                    _Haptics.key();
                    _send('shortcut_close_tab');
                  })),
          const SizedBox(width: 5),
          Expanded(
              child: _MiniPressButton(
                  label: 'Desktop',
                  icon: Icons.desktop_windows_rounded,
                  onTap: () {
                    _Haptics.key();
                    _send('shortcut_show_desktop');
                  })),
        ]),
        const SizedBox(height: 5),
        Row(children: [
          Expanded(
              child: _MiniPressButton(
                  label: '↗ Clip',
                  icon: Icons.upload_rounded,
                  iconSize: 13,
                  fontSize: 8,
                  onTap: () {
                    _Haptics.key();
                    _pushClipboard();
                  })),
          const SizedBox(width: 5),
          Expanded(
              child: _MiniPressButton(
                  label: '↘ Clip',
                  icon: Icons.download_rounded,
                  iconSize: 13,
                  fontSize: 8,
                  active: _clipInFlight,
                  activeColor: _C.accentB,
                  onTap: _clipInFlight
                      ? () {}
                      : () {
                          _Haptics.key();
                          _pullClipboard();
                        })),
        ]),
      ]);

  Widget _fullscreenExitBtn() => Positioned(
      top: 10,
      right: 10,
      child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _fullscreen = false),
          child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white10)),
              child: const Icon(Icons.fullscreen_exit_rounded,
                  color: Colors.white38, size: 16))));

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: _C.bg,
      resizeToAvoidBottomInset: true,
      body: Container(
          decoration: const BoxDecoration(gradient: _C.bgGrad),
          child: SafeArea(
              child: _fullscreen
                  ? Stack(children: [
                      Positioned.fill(child: _canvas()),
                      _fullscreenExitBtn()
                    ])
                  : OrientationBuilder(builder: (ctx, orientation) {
                      if (orientation == Orientation.portrait) {
                        return _portraitLayout();
                      }
                      return Column(children: [
                        _statusBar(),
                        Expanded(
                            child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    12, 4, 12, 12),
                                child: Row(children: [
                                  Expanded(flex: 3, child: _canvas()),
                                  const SizedBox(width: 10),
                                  _landscapeSidebar(),
                                ]))),
                      ]);
                    }))));
}

// ══════════════════════════════════════════════════════════════════════
// SETTINGS SHEET — extracted to its own StatefulWidget so controls
// are fully interactive without being blocked by the touchpad canvas.
// ══════════════════════════════════════════════════════════════════════
class _SettingsSheet extends StatefulWidget {
  final double sensitivity;
  final double scrollSpeed;
  final bool naturalScroll;
  final double momFeel;
  final HapticProfile hapticProfile;
  final bool unlockEnabled;
  final String serverKey;
  final void Function(double sens, double scroll, bool nat, double mom,
      HapticProfile haptic, bool unlock) onChanged;
  final VoidCallback onUnpair;

  const _SettingsSheet({
    required this.sensitivity,
    required this.scrollSpeed,
    required this.naturalScroll,
    required this.momFeel,
    required this.hapticProfile,
    required this.unlockEnabled,
    required this.serverKey,
    required this.onChanged,
    required this.onUnpair,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late double _sensitivity;
  late double _scrollSpeed;
  late bool _naturalScroll;
  late double _momFeel;
  late HapticProfile _hapticProfile;
  late bool _unlockEnabled;

  @override
  void initState() {
    super.initState();
    _sensitivity = widget.sensitivity;
    _scrollSpeed = widget.scrollSpeed;
    _naturalScroll = widget.naturalScroll;
    _momFeel = widget.momFeel;
    _hapticProfile = widget.hapticProfile;
    _unlockEnabled = widget.unlockEnabled;
  }

  void _notify() {
    widget.onChanged(_sensitivity, _scrollSpeed, _naturalScroll,
        _momFeel, _hapticProfile, _unlockEnabled);
  }

  Widget _slider(String label, double value, double min, double max,
      int div, ValueChanged<double> cb) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(label,
              style: const TextStyle(color: _C.textMid, fontSize: 13)),
          const Spacer(),
          Text(value.toStringAsFixed(1),
              style: const TextStyle(
                  color: _C.textHi,
                  fontSize: 13,
                  fontWeight: FontWeight.w600))
        ]),
        SliderTheme(
            data: SliderThemeData(
                activeTrackColor: _C.accentA,
                inactiveTrackColor: _C.border,
                thumbColor: _C.accentA,
                overlayColor: _C.accentA.withOpacity(0.15),
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7)),
            child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: div,
                onChanged: cb))
      ]);

  Widget _settingsRow(String title, String sub, Widget trailing) =>
      Row(children: [
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title,
                  style: const TextStyle(
                      color: _C.textHi,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              Text(sub,
                  style: const TextStyle(
                      color: _C.textMid, fontSize: 11)),
            ])),
        trailing,
      ]);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        expand: false,
        builder: (ctx, sc) => ListView(
            controller: sc,
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
            children: [
              Center(
                  child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                          color: _C.border,
                          borderRadius: BorderRadius.circular(2)))),
              const Text('Settings',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: _C.textHi)),
              const SizedBox(height: 24),
              _slider(
                  'Cursor Speed',
                  _sensitivity,
                  0.5,
                  6.0,
                  11,
                  (v) => setState(() { _sensitivity = v; _notify(); })),
              const SizedBox(height: 4),
              _slider(
                  'Scroll Speed',
                  _scrollSpeed,
                  1.0,
                  10.0,
                  18,
                  (v) => setState(() { _scrollSpeed = v; _notify(); })),
              const SizedBox(height: 20),
              _settingsRow(
                  'Natural Scroll',
                  'Flip scroll direction (macOS-style)',
                  Switch(
                    value: _naturalScroll,
                    onChanged: (v) {
                      setState(() { _naturalScroll = v; });
                      _notify();
                    },
                    activeColor: _C.accentA,
                  )),
              const SizedBox(height: 16),
              const Text('Scroll Momentum',
                  style: TextStyle(color: _C.textMid, fontSize: 13)),
              const SizedBox(height: 10),
              Row(children: [
                ...[
                  ('None', 0.0),
                  ('Light', 0.72),
                  ('Normal', 0.80),
                  ('Heavy', 0.92)
                ].map((e) {
                  final active = (_momFeel - e.$2).abs() < 0.01;
                  return Expanded(
                      child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                              onTap: () {
                                setState(() { _momFeel = e.$2; });
                                _notify();
                              },
                              child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  decoration: BoxDecoration(
                                      color: active
                                          ? _C.accentA.withOpacity(0.15)
                                          : _C.surface,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                          color: active
                                              ? _C.accentA.withOpacity(0.6)
                                              : _C.border)),
                                  child: Center(
                                      child: Text(e.$1,
                                          style: TextStyle(
                                              color: active ? _C.accentA : _C.textMid,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600)))))));
                }),
              ]),
              const SizedBox(height: 16),
              const Text('Haptic Feedback',
                  style: TextStyle(color: _C.textMid, fontSize: 13)),
              const SizedBox(height: 10),
              Row(
                  children: HapticProfile.values.map((p) {
                final labels = ['Off', 'Light', 'Medium', 'Strong'];
                final active = _hapticProfile == p;
                return Expanded(
                    child: GestureDetector(
                        onTap: () {
                          setState(() { _hapticProfile = p; });
                          _notify();
                        },
                        child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                                color: active
                                    ? _C.accentA.withOpacity(0.15)
                                    : _C.surface,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: active
                                        ? _C.accentA.withOpacity(0.6)
                                        : _C.border)),
                            child: Center(
                                child: Text(labels[p.index],
                                    style: TextStyle(
                                        color: active ? _C.accentA : _C.textMid,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600))))));
              }).toList()),
              const SizedBox(height: 24),
              const Divider(color: _C.border),
              const SizedBox(height: 16),
              _settingsRow(
                  'Biometric unlock',
                  'Show unlock button on trackpad screen',
                  Switch(
                    value: _unlockEnabled,
                    onChanged: (v) {
                      setState(() { _unlockEnabled = v; });
                      _notify();
                    },
                    activeColor: _C.accentC,
                  )),
              if (_unlockEnabled) ...[
                const SizedBox(height: 10),
                Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: _C.accentC.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _C.accentC.withOpacity(0.2))),
                    child: const Row(children: [
                      Icon(Icons.info_outline_rounded,
                          color: _C.accentC, size: 13),
                      SizedBox(width: 8),
                      Expanded(
                          child: Text(
                        "Make sure you've run --set-unlock-password on the server first.",
                        style: TextStyle(color: _C.accentC, fontSize: 11),
                      )),
                    ])),
              ],
              const SizedBox(height: 24),
              const Divider(color: _C.border),
              const SizedBox(height: 16),
              GestureDetector(
                  onTap: widget.onUnpair,
                  child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                          color: _C.danger.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: _C.danger.withOpacity(0.25))),
                      child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.link_off_rounded,
                                color: _C.danger, size: 16),
                            SizedBox(width: 8),
                            Text('Unpair this device',
                                style: TextStyle(
                                    color: _C.danger,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ])))
            ]));
  }
}

// ══════════════════════════════════════════════════════════════════════
// KEYBOARD PANEL — rebuilt
// ══════════════════════════════════════════════════════════════════════
class _KeyboardPanel extends StatefulWidget {
  final void Function(String) onTypeText;
  final VoidCallback onBackspace, onEnter, onNewline, onTab, onEscape;
  const _KeyboardPanel({
    required this.onTypeText,
    required this.onBackspace,
    required this.onEnter,
    required this.onNewline,
    required this.onTab,
    required this.onEscape,
  });
  @override
  State<_KeyboardPanel> createState() => _KeyboardPanelState();
}

class _KeyboardPanelState extends State<_KeyboardPanel> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _open = false;
  String _prev = '';

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_open) {
      _focus.unfocus();
      setState(() => _open = false);
    } else {
      setState(() => _open = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focus.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Toggle button
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: _C.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _open ? _C.accentA.withOpacity(0.6) : _C.border,
                width: _open ? 1.5 : 1,
              ),
            ),
            child: Row(children: [
              Expanded(
                child: Text(
                  _open ? 'Keyboard open — type below' : 'Tap to open keyboard',
                  style: TextStyle(
                    color: _open ? _C.accentA : _C.textLo,
                    fontSize: 13,
                  ),
                ),
              ),
              Icon(
                _open ? Icons.keyboard_hide_rounded : Icons.keyboard_rounded,
                color: _open ? _C.accentA : _C.textLo,
                size: 16,
              ),
            ]),
          ),
        ),

        // Expanded input area
        if (_open) ...[
          const SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        focusNode: _focus,
                        autofocus: true,
                        style: const TextStyle(color: _C.textHi, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Type here — live to PC',
                          hintStyle: const TextStyle(color: _C.textLo, fontSize: 13),
                          filled: true,
                          fillColor: _C.surface,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: _C.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: _C.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                                color: _C.accentA, width: 1.5),
                          ),
                        ),
                        onChanged: (val) {
                          if (val.length > _prev.length) {
                            final newChars = val.substring(_prev.length);
                            for (int i = 0; i < newChars.length; i++) {
                              final ch = newChars[i];
                              widget.onTypeText(ch);
                            }
                          } else if (val.length < _prev.length) {
                            final deleted = _prev.length - val.length;
                            for (int i = 0; i < deleted; i++) {
                              widget.onBackspace();
                            }
                          }
                          _prev = val;
                        },
                        onSubmitted: (_) {
                          _focus.requestFocus();
                        },
                        textInputAction: TextInputAction.none,
                        keyboardType: TextInputType.text,
                        maxLines: 1,
                        autocorrect: false,
                        enableSuggestions: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: widget.onNewline,
                      child: Container(
                        height: 44,
                        width: 52,
                        decoration: BoxDecoration(
                          color: _C.card,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _C.border),
                        ),
                        child: const Center(
                          child: Text('⏎',
                              style: TextStyle(
                                  color: _C.textMid,
                                  fontSize: 18)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        if (_ctrl.text.isEmpty) return;
                        final len = _ctrl.text.length;
                        _ctrl.clear();
                        _prev = '';
                        for (int i = 0; i < len; i++) {
                          widget.onBackspace();
                        }
                      },
                      child: Container(
                        height: 44,
                        width: 52,
                        decoration: BoxDecoration(
                          color: _C.danger.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _C.danger.withOpacity(0.3)),
                        ),
                        child: const Center(
                          child: Icon(Icons.clear_all_rounded,
                              color: _C.danger, size: 20),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(children: [
                  _qk('⌫', widget.onBackspace),
                  const SizedBox(width: 5),
                  _qk('⇥ Tab', widget.onTab),
                  const SizedBox(width: 5),
                  _qk('Esc', widget.onEscape),
                  const SizedBox(width: 5),
                  _qk('↵ Enter', widget.onEnter),
                ]),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _qk(String label, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: _C.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _C.border),
            ),
            child: Center(
              child: Text(label,
                  style: const TextStyle(
                      color: _C.textMid,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );
}

class _AltSwitchButton extends StatefulWidget {
  final bool altHeld;
  final VoidCallback onTap, onLongPress;
  const _AltSwitchButton(
      {required this.altHeld,
      required this.onTap,
      required this.onLongPress});
  @override
  State<_AltSwitchButton> createState() => _AltSwitchButtonState();
}

class _AltSwitchButtonState extends State<_AltSwitchButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 80));
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.93)
      .animate(CurvedAnimation(parent: _ac, curve: Curves.easeOut));
  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final held = widget.altHeld;
    return GestureDetector(
        onTapDown: (_) => _ac.forward(),
        onTapUp: (_) {
          _ac.reverse();
          widget.onTap();
        },
        onTapCancel: () => _ac.reverse(),
        onLongPress: widget.onLongPress,
        onLongPressEnd: (_) {
          _ac.reverse();
          widget.onTap();
        },
        child: ScaleTransition(
            scale: _scale,
            child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                    color: held
                        ? _C.amber.withOpacity(0.15)
                        : _C.card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: held
                            ? _C.amber.withOpacity(0.7)
                            : _C.border,
                        width: held ? 1.5 : 1),
                    boxShadow: held
                        ? [
                            BoxShadow(
                                color: _C.amber.withOpacity(0.25),
                                blurRadius: 12,
                                spreadRadius: -2)
                          ]
                        : []),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.tab_rounded,
                          color: held ? _C.amber : _C.textMid,
                          size: 17),
                      const SizedBox(height: 3),
                      Text(held ? 'Release' : 'Switch',
                          style: TextStyle(
                              color: held ? _C.amber : _C.textMid,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2))
                    ]))));
  }
}

class _MiniPressButton extends StatefulWidget {
  final VoidCallback onTap;
  final String label;
  final IconData icon;
  final bool active;
  final Color activeColor;
  final double iconSize, fontSize;
  const _MiniPressButton(
      {required this.onTap,
      required this.label,
      required this.icon,
      this.active = false,
      this.activeColor = _C.accentA,
      this.iconSize = 15,
      this.fontSize = 9});
  @override
  State<_MiniPressButton> createState() => _MiniPressButtonState();
}

class _MiniPressButtonState extends State<_MiniPressButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 80));
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.93)
      .animate(CurvedAnimation(parent: _ac, curve: Curves.easeOut));
  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? widget.activeColor : _C.textMid;
    return GestureDetector(
        onTapDown: (_) {
          _ac.forward();
          widget.onTap();
        },
        onTapUp: (_) => _ac.reverse(),
        onTapCancel: () => _ac.reverse(),
        child: ScaleTransition(
            scale: _scale,
            child: Container(
                decoration: BoxDecoration(
                    color: widget.active
                        ? widget.activeColor.withOpacity(0.12)
                        : _C.card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: widget.active
                            ? widget.activeColor.withOpacity(0.4)
                            : _C.border)),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(widget.icon,
                          color: color, size: widget.iconSize),
                      if (widget.fontSize > 0) ...[
                        const SizedBox(height: 2),
                        Text(widget.label,
                            style: TextStyle(
                                color: color,
                                fontSize: widget.fontSize,
                                fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)
                      ]
                    ]))));
  }
}

class _ArrowBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onDown, onUp;
  final double height;
  const _ArrowBtn(
      {required this.icon,
      required this.onDown,
      required this.onUp,
      this.height = 28});
  @override
  State<_ArrowBtn> createState() => _ArrowBtnState();
}

class _ArrowBtnState extends State<_ArrowBtn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 60));
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.88)
      .animate(CurvedAnimation(parent: _ac, curve: Curves.easeOut));
  bool _pressed = false;
  @override
  void dispose() {
    if (_pressed) widget.onUp();
    _ac.dispose();
    super.dispose();
  }

  void _down() {
    if (_pressed) return;
    _pressed = true;
    _ac.forward();
    setState(() {});
    widget.onDown();
  }

  void _up() {
    if (!_pressed) return;
    _pressed = false;
    _ac.reverse();
    setState(() {});
    widget.onUp();
  }

  @override
  Widget build(BuildContext context) => Listener(
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: ScaleTransition(
          scale: _scale,
          child: Container(
              height: widget.height,
              decoration: BoxDecoration(
                  color: _pressed
                      ? _C.accentA.withOpacity(0.18)
                      : _C.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: _pressed
                          ? _C.accentA.withOpacity(0.6)
                          : _C.border)),
              child: Center(
                  child: Icon(widget.icon,
                      color: _pressed ? _C.accentA : _C.textMid,
                      size: 16)))));
}

class _MediaHoldButton extends StatefulWidget {
  final IconData icon;
  final double iconSize;
  final VoidCallback onDown, onUp;
  const _MediaHoldButton(
      {required this.icon,
      required this.iconSize,
      required this.onDown,
      required this.onUp});
  @override
  State<_MediaHoldButton> createState() => _MediaHoldButtonState();
}

class _MediaHoldButtonState extends State<_MediaHoldButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 60));
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.88)
      .animate(CurvedAnimation(parent: _ac, curve: Curves.easeOut));
  bool _pressed = false;
  @override
  void dispose() {
    if (_pressed) widget.onUp();
    _ac.dispose();
    super.dispose();
  }

  void _down() {
    if (_pressed) return;
    _pressed = true;
    _ac.forward();
    setState(() {});
    widget.onDown();
  }

  void _up() {
    if (!_pressed) return;
    _pressed = false;
    _ac.reverse();
    setState(() {});
    widget.onUp();
  }

  @override
  Widget build(BuildContext context) => Listener(
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: ScaleTransition(
          scale: _scale,
          child: Container(
              decoration: BoxDecoration(
                  color: _pressed
                      ? _C.accentA.withOpacity(0.18)
                      : _C.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: _pressed
                          ? _C.accentA.withOpacity(0.6)
                          : _C.border)),
              child: Center(
                  child: Icon(widget.icon,
                      color: _pressed ? _C.accentA : _C.textMid,
                      size: widget.iconSize)))));
}

class _PressButton extends StatefulWidget {
  final VoidCallback onTap;
  final String label;
  final IconData icon;
  const _PressButton(
      {required this.onTap,
      required this.label,
      required this.icon});
  @override
  State<_PressButton> createState() => _PressButtonState();
}

class _PressButtonState extends State<_PressButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 80));
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.93)
      .animate(CurvedAnimation(parent: _ac, curve: Curves.easeOut));
  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
      onTapDown: (_) {
        _ac.forward();
        widget.onTap();
      },
      onTapUp: (_) => _ac.reverse(),
      onTapCancel: () => _ac.reverse(),
      child: ScaleTransition(
          scale: _scale,
          child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                  color: _C.card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _C.border)),
              child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(widget.icon,
                            color: _C.textMid, size: 20),
                        const SizedBox(height: 4),
                        Text(widget.label,
                            style: const TextStyle(
                                color: _C.textMid,
                                fontSize: 12,
                                fontWeight: FontWeight.w500))
                      ])))));
}

// ══════════════════════════════════════════════════════════════════════
// TOUCHPAD CANVAS
// ══════════════════════════════════════════════════════════════════════
class TouchpadCanvas extends StatefulWidget {
  final void Function(String jsonStr) onSend;
  final double sensitivity, scrollSpeed;
  final bool zoomModeEnabled, naturalScroll;
  final double momFeel;
  final bool enabled;
  const TouchpadCanvas(
      {super.key,
      required this.onSend,
      required this.sensitivity,
      required this.scrollSpeed,
      required this.zoomModeEnabled,
      this.naturalScroll = false,
      this.momFeel = 0.80,
      this.enabled = true});
  @override
  State<TouchpadCanvas> createState() => _TouchpadCanvasState();
}

class _TouchpadCanvasState extends State<TouchpadCanvas>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final Map<int, Offset> _ptrs = {}, _dnPos = {};
  final Map<int, DateTime> _dnTime = {};
  final Set<int> _ign = {};
  int _committed = 0;
  DateTime _lastChange = DateTime.now();
  static const _intentMs = 5;
  double _scY = 0, _scX = 0;
  DateTime _lastSc = DateTime.now();
  static const _scThrottle = 16;
  ScrollAxis _axis = ScrollAxis.none;
  static const _axisThresh = 1.5;
  double _momV = 0;
  bool _momH = false;
  Timer? _momT;
  static const _momMin = 0.08, _momFrameMs = 16;
  double _lastDelta = 0;

  void _startMom(double v, bool h) {
    _momT?.cancel();
    if (widget.momFeel < 0.01 || v.abs() < _momMin * 3) return;
    _momV = v;
    _momH = h;
    _momT =
        Timer.periodic(const Duration(milliseconds: _momFrameMs), (t) {
      _momV *= widget.momFeel;
      if (_momV.abs() < _momMin) {
        t.cancel();
        _momT = null;
        return;
      }
      if (_momH) {
        _send({'type': 'scroll_x', 'dx': _momV, 'natural': widget.naturalScroll});
      } else {
        _send({'type': 'scroll', 'dy': _momV, 'natural': widget.naturalScroll});
      }
    });
  }

  void _stopMom() {
    _momT?.cancel();
    _momT = null;
    _momV = 0;
  }

  double _pinchDist = 0;
  bool _pinchActive = false;
  double _pinchAccum = 0;
  static const _pinchStep = 30.0;
  DateTime? _lastTap;
  Timer? _lastClickTimer;
  bool _waitDblDrag = false;
  static const _dblWin = Duration(milliseconds: 300);
  static const _tapMove = 10.0;
  static const _tapDur = Duration(milliseconds: 200);
  bool _dragging = false;
  DateTime _lastMove = DateTime.now();
  static const _moveThrottle = 0;
  final EmaSmoother _sx = EmaSmoother(alpha: 0.18),
      _sy = EmaSmoother(alpha: 0.18);
  Orientation? _lastOri;
  late final AnimationController _ripAc = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 350));
  late final Animation<double> _ripScale = Tween(begin: 0.0, end: 1.0)
      .animate(
          CurvedAnimation(parent: _ripAc, curve: Curves.easeOut));
  late final Animation<double> _ripOp = Tween(begin: 0.4, end: 0.0)
      .animate(CurvedAnimation(parent: _ripAc, curve: Curves.easeIn));
  Offset _ripPos = Offset.zero;
  late final AnimationController _pulseAc = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0,
      upperBound: 1)
    ..repeat(reverse: true);
  late final Animation<double> _pulseBr =
      Tween(begin: 0.3, end: 0.75).animate(
          CurvedAnimation(parent: _pulseAc, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _momT?.cancel();
    _lastClickTimer?.cancel();
    _ripAc.dispose();
    _pulseAc.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final o = _ori();
    if (o != null && o != _lastOri) {
      _lastOri = o;
      _reset();
    }
  }

  Orientation? _ori() {
    final s = WidgetsBinding
        .instance.platformDispatcher.views.first.physicalSize;
    if (s.isEmpty) return null;
    return s.width >= s.height
        ? Orientation.landscape
        : Orientation.portrait;
  }

  void _reset() {
    if (_dragging) _send({'type': 'mouse_up'});
    if (_pinchActive) _send({'type': 'zoom_end'});
    _stopMom();
    _ptrs.clear();
    _dnPos.clear();
    _dnTime.clear();
    _ign.clear();
    _committed = 0;
    _lastChange = DateTime.now();
    _scY = 0;
    _scX = 0;
    _axis = ScrollAxis.none;
    _pinchDist = 0;
    _pinchAccum = 0;
    _pinchActive = false;
    _lastClickTimer?.cancel();
    _lastClickTimer = null;
    _dragging = false;
    _waitDblDrag = false;
    _sx.reset();
    _sy.reset();
    if (mounted) setState(() {});
  }

  void _send(Map<String, dynamic> e) {
    try {
      widget.onSend(json.encode(e));
    } catch (_) {}
  }

  void _ripple(Offset p) {
    setState(() => _ripPos = p);
    _ripAc.forward(from: 0);
  }

  void _onDown(PointerDownEvent e) {
    _stopMom();
    _ptrs[e.pointer] = e.position;
    _dnPos[e.pointer] = e.position;
    _dnTime[e.pointer] = DateTime.now();
    _ign.remove(e.pointer);
    _committed = 0;
    _lastChange = DateTime.now();
    _scY = 0;
    _scX = 0;
    if (_ptrs.length == 1) {
      _axis = ScrollAxis.none;
      _pinchDist = 0;
      _pinchAccum = 0;
      _pinchActive = false;
    }
    if (_ptrs.length >= 2 && _dragging) {
      _dragging = false;
      setState(() {});
      _send({'type': 'mouse_up'});
    }
    if (_ptrs.length == 1 &&
        _lastTap != null &&
        DateTime.now().difference(_lastTap!) < _dblWin) {
      _waitDblDrag = true;
      _lastTap = null;
    }
  }

  void _onMove(PointerMoveEvent e) {
    final prev = _ptrs[e.pointer];
    if (prev == null || _ign.contains(e.pointer)) return;
    final dx = e.position.dx - prev.dx;
    final dy = e.position.dy - prev.dy;
    _ptrs[e.pointer] = e.position;
    if (DateTime.now()
            .difference(_lastChange)
            .inMilliseconds <
        _intentMs) return;
    if (_committed != _ptrs.length) {
      _committed = _ptrs.length;
      _scY = 0;
      _scX = 0;
      _axis = ScrollAxis.none;
      _pinchDist = 0;
      _pinchAccum = 0;
      _pinchActive = false;
      _sx.reset();
      _sy.reset();
    }
    if (_committed == 1) {
      if (_waitDblDrag && !_dragging) {
        final dp = _dnPos[e.pointer];
        if (dp != null && (e.position - dp).distance > _tapMove) {
          _waitDblDrag = false;
          _dragging = true;
          setState(() {});
          _send({'type': 'double_click_drag_start'});
          return;
        }
        return;
      }
      final now = DateTime.now();
      if (now.difference(_lastMove).inMilliseconds < _moveThrottle)
        return;
      _lastMove = now;
      _send({
        'type': 'move',
        'dx': _sx.smooth(dx * widget.sensitivity),
        'dy': _sy.smooth(dy * widget.sensitivity)
      });
    } else if (_committed == 2) {
      if (widget.zoomModeEnabled) {
        if (_ptrs.length == 2) {
          final ids = _ptrs.keys.toList();
          final dist =
              (_ptrs[ids[0]]! - _ptrs[ids[1]]!).distance;
          if (_pinchDist == 0) {
            _pinchDist = dist;
            if (!_pinchActive) {
              _pinchActive = true;
              _send({'type': 'zoom_start'});
            }
            return;
          }
          final delta = dist - _pinchDist;
          _pinchDist = dist;
          _pinchAccum += delta;
          if (_pinchAccum.abs() >= _pinchStep) {
            _send({
              'type': _pinchAccum > 0 ? 'zoom_in' : 'zoom_out'
            });
            _pinchAccum = 0;
          }
        }
        return;
      }
      if (_ptrs.length < 2 && _axis != ScrollAxis.none) {
        _axis = ScrollAxis.none;
        _scY = 0;
        _scX = 0;
      }
      if (_axis == ScrollAxis.none) {
        _scY += dy;
        _scX += dx;
        if (_scY.abs() >= _axisThresh ||
            _scX.abs() >= _axisThresh) {
          _axis = _scX.abs() > _scY.abs() * 1.3
              ? ScrollAxis.horizontal
              : ScrollAxis.vertical;
          _scX = 0;
          _scY = 0;
        }
        return;
      }
      final now = DateTime.now();
      final ms = now.difference(_lastSc).inMilliseconds;
      if (_axis == ScrollAxis.vertical) {
        _scY += dy;
        if (ms >= _scThrottle) {
          final v = _scY * (widget.scrollSpeed / 50.0);
          if (v.abs() > 0.1) {
            _lastDelta = -v;
            _send({
              'type': 'scroll',
              'dy': -v,
              'natural': widget.naturalScroll
            });
          }
          _scY = 0;
          _lastSc = now;
        }
      } else {
        _scX += dx;
        if (ms >= _scThrottle) {
          final v = _scX * (widget.scrollSpeed / 50.0);
          if (v.abs() > 0.03) {
            _lastDelta = -v;
            _send({
              'type': 'scroll_x',
              'dx': -v,
              'natural': widget.naturalScroll
            });
          }
          _scX = 0;
          _lastSc = now;
        }
      }
    }
  }

  void _onUp(PointerUpEvent e) {
    final dp = _dnPos[e.pointer];
    final dt = _dnTime[e.pointer];
    final fc = _ptrs.length;
    if (_waitDblDrag && !_dragging) {
      _waitDblDrag = false;
      _Haptics.rightClick();
      _send({'type': 'double_click'});
      _ptrs.remove(e.pointer);
      _dnPos.remove(e.pointer);
      _dnTime.remove(e.pointer);
      _committed = 0;
      _lastChange = DateTime.now();
      return;
    }
    if (dp != null && dt != null) {
      final moved = (e.position - dp).distance;
      final dur = DateTime.now().difference(dt);
      final isTap = moved < _tapMove && dur < _tapDur;
      if (isTap && fc == 2) {
        _Haptics.rightClick();
        _send({'type': 'right_click'});
        for (final id in _ptrs.keys) {
          if (id != e.pointer) {
            _ign.add(id);
            Future.delayed(const Duration(milliseconds: 300),
                () => _ign.remove(id));
          }
        }
      } else if (isTap && fc == 1 && !_ign.contains(e.pointer)) {
        _ripple(e.position);
        final now = DateTime.now();
        if (_lastTap != null &&
            now.difference(_lastTap!) < _dblWin) {
          _lastClickTimer?.cancel();
          _lastClickTimer = null;
          _lastTap = null;
          _waitDblDrag = true;
          _Haptics.click();
          _send({'type': 'double_click'});
        } else {
          _lastTap = now;
          _waitDblDrag = false;
          _Haptics.click();
          _send({'type': 'left_click'});
          _lastClickTimer = Timer(_dblWin, () {
            _lastTap = null;
            _lastClickTimer = null;
          });
        }
      }
    }
    if (_dragging) {
      _dragging = false;
      _waitDblDrag = false;
      setState(() {});
      _send({'type': 'mouse_up'});
    }
    if (fc == 2 && _pinchActive && widget.zoomModeEnabled) {
      _send({'type': 'zoom_end'});
      _pinchActive = false;
      _pinchDist = 0;
      _pinchAccum = 0;
    }
    if (fc == 2 &&
        _axis != ScrollAxis.none &&
        !widget.zoomModeEnabled) {
      _startMom(_lastDelta * (widget.scrollSpeed / 50.0) * 0.8,
          _axis == ScrollAxis.horizontal);
    }
    if (fc == 2) {
      for (final id in _ptrs.keys) {
        if (id != e.pointer) {
          _ign.add(id);
          Future.delayed(
              Duration(milliseconds: _intentMs + 20),
              () => _ign.remove(id));
        }
      }
    }
    _ptrs.remove(e.pointer);
    _dnPos.remove(e.pointer);
    _dnTime.remove(e.pointer);
    if (_ptrs.isEmpty) {
      _committed = 0;
      _lastChange = DateTime.now();
      _scY = 0;
      _scX = 0;
      _axis = ScrollAxis.none;
      _pinchDist = 0;
      _pinchAccum = 0;
      _pinchActive = false;
      _sx.reset();
      _sy.reset();
    } else {
      _committed = 0;
      _lastChange = DateTime.now();
    }
  }

  void _onLong() {
    if (_ptrs.length == 1 && !_waitDblDrag) {
      _Haptics.drag();
      setState(() => _dragging = true);
      _send({'type': 'mouse_down'});
    }
  }

  @override
  Widget build(BuildContext context) {
    _lastOri ??= MediaQuery.of(context).orientation;
    // AbsorbPointer blocks all touch input when the touchpad is disabled
    // (e.g. settings sheet open, keyboard focused). This ensures sliders,
    // switches and keyboard keys receive touches instead of the touchpad.
    return AbsorbPointer(
      absorbing: !widget.enabled,
      child: GestureDetector(
      onLongPress: widget.enabled ? _onLong : null,
      supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus},
          child: Listener(
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              behavior: HitTestBehavior.opaque,
            child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: AnimatedBuilder(
                    animation:
                        Listenable.merge([_ripAc, _pulseAc]),
                    builder: (ctx, _) {
                      final bc = _dragging
                          ? Color.lerp(
                              _C.accentA.withOpacity(0.3),
                              _C.accentA,
                              _pulseBr.value)!
                          : _C.border;
                      return Container(
                          decoration: BoxDecoration(
                              gradient: RadialGradient(
                                  center: Alignment.center,
                                  radius: 1.1,
                                  colors: [
                                    const Color(0xFF161D2E),
                                    _C.card
                                  ]),
                              borderRadius:
                                  BorderRadius.circular(22),
                              border: Border.all(
                                  color: bc,
                                  width: _dragging ? 1.5 : 1.0)),
                          child: Stack(children: [
                            Positioned.fill(
                                child: CustomPaint(
                                    painter: _GridPainter())),
                            if (_ripAc.isAnimating ||
                                _ripAc.value > 0)
                              Positioned(
                                  left: _ripPos.dx - 60,
                                  top: _ripPos.dy - 60,
                                  child: Opacity(
                                      opacity: _ripOp.value,
                                      child: Transform.scale(
                                          scale: _ripScale.value,
                                          child: Container(
                                              width: 120,
                                              height: 120,
                                              decoration:
                                                  const BoxDecoration(
                                                      shape: BoxShape
                                                          .circle,
                                                      color: Color(
                                                          0x403B7BF5)))))),
                            Center(
                                child: _dragging
                                    ? Column(
                                        mainAxisSize:
                                            MainAxisSize.min,
                                        children: [
                                            Icon(
                                                Icons
                                                    .pan_tool_rounded,
                                                color: _C.accentA
                                                    .withOpacity(0.8),
                                                size: 32),
                                            const SizedBox(height: 8),
                                            Text('Dragging',
                                                style: TextStyle(
                                                    color: _C.accentA
                                                        .withOpacity(
                                                            0.7),
                                                    fontSize: 12,
                                                    fontWeight:
                                                        FontWeight
                                                            .w600,
                                                    letterSpacing:
                                                        0.5))
                                          ])
                                    : Column(
                                        mainAxisSize:
                                            MainAxisSize.min,
                                        children: [
                                            Row(
                                                mainAxisSize:
                                                    MainAxisSize.min,
                                                children: List.generate(
                                                    math.max(
                                                        1,
                                                        _ptrs
                                                            .length),
                                                    (i) => Container(
                                                        width: 5,
                                                        height: 5,
                                                        margin: const EdgeInsets.symmetric(
                                                            horizontal:
                                                                3),
                                                        decoration: BoxDecoration(
                                                            color: _ptrs.isNotEmpty
                                                                ? _C.accentA.withOpacity(0.6)
                                                                : _C.textLo,
                                                            shape: BoxShape.circle)))),
                                            const SizedBox(height: 10),
                                            const Icon(
                                                Icons.touch_app_rounded,
                                                color: _C.textLo,
                                                size: 36),
                                            const SizedBox(height: 6),
                                            Text(
                                                widget.zoomModeEnabled
                                                    ? 'Zoom mode'
                                                    : 'Touchpad',
                                                style: const TextStyle(
                                                    color: _C.textLo,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                    letterSpacing: 0.4))
                                          ])),
                          ]));
                    })))));
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF1E2740).withOpacity(0.5)
      ..style = PaintingStyle.fill;
    const sp = 22.0;
    for (double x = sp; x < size.width - sp / 2; x += sp) {
      for (double y = sp; y < size.height - sp / 2; y += sp) {
        canvas.drawCircle(Offset(x, y), 0.8, p);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter _) => false;
}