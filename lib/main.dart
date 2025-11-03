import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 鎖定橫向顯示 + 沉浸式
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const CarControllerApp());
}

class CarControllerApp extends StatefulWidget {
  const CarControllerApp({super.key});
  @override
  State<CarControllerApp> createState() => _CarControllerAppState();
}

class _CarControllerAppState extends State<CarControllerApp> {
  // ===== MQTT =====
  final client = MqttServerClient('mqttgo.io', 'flutter_car_android');
  final String topic = 'Car/Control';

  String status = '🔌 尚未連線';
  bool isConnected = false;

  // 節流：避免 onPanUpdate 狂發訊息（每 120 ms 最多發一次）
  Timer? _throttleTimer;
  String? _lastCmd; // 記錄最後一次送出的指令（相同就不重發）
  Duration throttleGap = const Duration(milliseconds: 120);

  // ===== Joystick 狀態 =====
  // 這裡僅視覺上顯示目前方向與強度，實際指令仍送 A/W/S/D/R/STOP
  String currentDirText = '—';
  double currentPower = 0.0; // 0~1

  @override
  void initState() {
    super.initState();
    _setupMqtt();
  }

  Future<void> _setupMqtt() async {
    setState(() => status = '⏳ 嘗試連線中...');
    client.port = 1883;
    client.keepAlivePeriod = 20;
    client.logging(on: false);
    client.onDisconnected = _onDisconnected;

    try {
      await client.connect();
      setState(() {
        isConnected = true;
        status = '✅ 已連線至 mqttgo.io';
      });
    } catch (e) {
      setState(() {
        isConnected = false;
        status = '❌ 無法連線：$e';
      });
      client.disconnect();
    }
  }

  void _onDisconnected() {
    setState(() {
      isConnected = false;
      status = '🔴 已斷線';
    });
  }

  void _publish(String cmd) {
    if (!isConnected) return;
    if (_lastCmd == cmd) return; // 相同指令不重送

    final builder = MqttClientPayloadBuilder()..addString(cmd);
    client.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
    _lastCmd = cmd;
    setState(() => status = '📡 已發送指令：$cmd');
  }

  void _throttledSend(String cmd) {
    if (_throttleTimer?.isActive ?? false) return;
    _publish(cmd);
    _throttleTimer = Timer(throttleGap, () {});
  }

  // 當搖桿移動：offset 為 (-1~1, -1~1)，y 向上為負（螢幕座標）
  void _onStickChanged(Offset offset) {
    // 轉成人類可讀
    final power = offset.distance.clamp(0.0, 1.0);
    currentPower = power;
    final angle = math.atan2(-offset.dy, offset.dx); // 0度在+X，逆時針
    currentDirText = _angleToText(angle, power);

    // 轉成你的既有指令（W/A/S/D），含「停止」
    final cmd = _offsetToCommand(offset);
    _throttledSend(cmd);

    setState(() {});
  }

  // 滑開（放手）時停車
  void _onStickReleased() {
    currentPower = 0.0;
    currentDirText = '—';
    _throttledSend('STOP');
    setState(() {});
  }

  // 將角度 + 強度轉成顯示文字
  String _angleToText(double angle, double power) {
    if (power < 0.15) return '—';
    final deg = angle * 180 / math.pi;
    String dir;
    if (deg >= -45 && deg < 45) {
      dir = '右';
    } else if (deg >= 45 && deg < 135) {
      dir = '上';
    } else if (deg >= -135 && deg < -45) {
      dir = '下';
    } else {
      dir = '左';
    }
    return '$dir  ${(power * 100).round()}%';
  }

  // 將 offset 決策為 A/W/S/D/STOP
  String _offsetToCommand(Offset o) {
    final dead = 0.15; // 死區
    if (o.distance < dead) return 'STOP';

    // 誰的絕對值大，就判定哪個方向
    if (o.dx.abs() > o.dy.abs()) {
      // 水平：右為 D，左為 A
      return o.dx > 0 ? 'D' : 'A';
    } else {
      // 垂直：上為 W（因畫面座標上是 dy<0），下為 S
      return o.dy < 0 ? 'W' : 'S';
    }
  }

  // 功能按鈕：R（倒車）、STOP、重新連線、斷線
  Widget _actionButtons() {
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        _pillButton('⛔ STOP', Colors.red, () => _publish('STOP')),
        _pillButton('🔄 倒車 R', Colors.orange, () => _publish('R')),
        _pillButton(
          isConnected ? '🔌 斷線' : '🔗 重新連線',
          isConnected ? Colors.blueGrey : Colors.green,
              () async {
            if (isConnected) {
              client.disconnect();
              _onDisconnected();
            } else {
              await _setupMqtt();
            }
          },
        ),
      ],
    );
  }

  Widget _pillButton(String text, Color color, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: isConnected ? onTap : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        elevation: 4,
      ),
      child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Raspberry Pi Car Panel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFF0F1115),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              // ===== 左側：大搖桿 =====
              Expanded(
                flex: 5,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: AspectRatio(
                      aspectRatio: 1, // 正方形
                      child: Joystick(
                        onChanged: _onStickChanged,
                        onReleased: _onStickReleased,
                        baseColor: const Color(0xFF1C2430),
                        knobColor: const Color(0xFF2EE6A6),
                        ringColor: const Color(0x332EE6A6),
                        labelBuilder: () => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              currentDirText,
                              style: const TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isConnected ? 'ONLINE' : 'OFFLINE',
                              style: TextStyle(
                                fontSize: 12,
                                letterSpacing: 2,
                                color: isConnected ? Colors.greenAccent : Colors.redAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ===== 右側：資訊面板 + 功能鍵 =====
              Expanded(
                flex: 6,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _statusCard(),
                      const SizedBox(height: 16),
                      _telemetryRow(),
                      const SizedBox(height: 16),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: _glass(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('⚙️ 控制',
                                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 12),
                              _actionButtons(),
                              const Spacer(),
                              const Divider(height: 24),
                              const Text(
                                '提示：拖曳左側搖桿即可前進/後退/左轉/右轉。放手自動 STOP。',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 狀態卡片
  Widget _statusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _glass(),
      child: Row(
        children: [
          Icon(
            isConnected ? Icons.podcasts_rounded : Icons.podcasts_outlined,
            color: isConnected ? Colors.greenAccent : Colors.redAccent,
            size: 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          _tag('Topic', topic),
          const SizedBox(width: 8),
          _tag('Client', client.clientIdentifier ?? '—'),
        ],
      ),
    );
  }

  // 簡易遙測列（顯示搖桿力度與方向）
  Widget _telemetryRow() {
    return Row(
      children: [
        Expanded(
          child: _miniStat('方向', currentDirText),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _miniStat('推力', '${(currentPower * 100).round()} %'),
        ),
      ],
    );
  }

  BoxDecoration _glass() => BoxDecoration(
    color: const Color(0x331A2030),
    borderRadius: BorderRadius.circular(18),
    border: Border.all(color: const Color(0x225C6A82)),
    boxShadow: const [
      BoxShadow(blurRadius: 18, spreadRadius: -6, color: Colors.black45),
    ],
  );

  Widget _tag(String k, String v) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x335C6A82)),
      ),
      child: Row(
        children: [
          Text('$k: ', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _miniStat(String title, String value) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _glass(),
      child: Row(
        children: [
          Text('$title  ', style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

/// ======================= Joystick Widget（無套件）=======================
/// - onChanged: 拖曳時提供 Offset(-1~1, -1~1)
/// - onReleased: 放手回呼
class Joystick extends StatefulWidget {
  const Joystick({
    super.key,
    required this.onChanged,
    required this.onReleased,
    this.baseColor = const Color(0xFF1E1E1E),
    this.knobColor = Colors.white,
    this.ringColor = const Color(0x22FFFFFF),
    this.labelBuilder,
  });

  final void Function(Offset normalized) onChanged;
  final VoidCallback onReleased;
  final Color baseColor;
  final Color knobColor;
  final Color ringColor;
  final Widget Function()? labelBuilder;

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset _knobPos = Offset.zero; // 相對中心，-1~1
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = math.min(c.maxWidth, c.maxHeight);
      final knobRadius = size * 0.12;
      final baseRadius = size * 0.42; // 限制最大拖曳半徑

      return GestureDetector(
        onPanStart: (d) => _onPan(d.localPosition, size, baseRadius),
        onPanUpdate: (d) => _onPan(d.localPosition, size, baseRadius),
        onPanEnd: (_) => _endDrag(),
        onPanCancel: () => _endDrag(),
        child: CustomPaint(
          painter: _JoystickPainter(
            knobPos: _knobPos,
            baseColor: widget.baseColor,
            knobColor: widget.knobColor,
            ringColor: widget.ringColor,
            knobRadius: knobRadius,
            baseRadius: baseRadius,
          ),
          child: Center(
            child: IgnorePointer(
              ignoring: true,
              child: widget.labelBuilder?.call(),
            ),
          ),
        ),
      );
    });
  }

  void _onPan(Offset p, double size, double baseRadius) {
    final center = Offset(size / 2, size / 2);
    Offset delta = p - center;

    // 轉換成 -1~1 的座標
    if (delta.distance > baseRadius) {
      delta = Offset.fromDirection(delta.direction, baseRadius);
    }
    final normalized = Offset(delta.dx / baseRadius, delta.dy / baseRadius);

    setState(() {
      _dragging = true;
      _knobPos = normalized;
    });
    widget.onChanged(_knobPos);
  }

  void _endDrag() {
    setState(() {
      _dragging = false;
      _knobPos = Offset.zero;
    });
    widget.onReleased();
  }
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter({
    required this.knobPos,
    required this.baseColor,
    required this.knobColor,
    required this.ringColor,
    required this.knobRadius,
    required this.baseRadius,
  });

  final Offset knobPos;
  final Color baseColor;
  final Color knobColor;
  final Color ringColor;
  final double knobRadius;
  final double baseRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final base = Paint()..color = baseColor;
    final ring = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6;

    // 底盤
    canvas.drawCircle(center, baseRadius + 10, Paint()..color = baseColor.withOpacity(0.6));
    canvas.drawCircle(center, baseRadius, base);
    canvas.drawCircle(center, baseRadius * 0.66, ring);
    canvas.drawCircle(center, baseRadius * 0.33, ring);

    // 十字輔助線
    final guide = Paint()
      ..color = Colors.white10
      ..strokeWidth = 2;
    canvas.drawLine(Offset(center.dx - baseRadius, center.dy),
        Offset(center.dx + baseRadius, center.dy), guide);
    canvas.drawLine(Offset(center.dx, center.dy - baseRadius),
        Offset(center.dx, center.dy + baseRadius), guide);

    // 旋光效果的 knob（略帶外光暈）
    final knobCenter =
    Offset(center.dx + knobPos.dx * baseRadius, center.dy + knobPos.dy * baseRadius);
    canvas.drawCircle(knobCenter, knobRadius + 6, Paint()..color = Colors.black26);
    canvas.drawCircle(knobCenter, knobRadius, Paint()..color = knobColor);
    final glare = Paint()
      ..shader = RadialGradient(
        colors: [Colors.white.withOpacity(0.45), Colors.transparent],
      ).createShader(Rect.fromCircle(center: knobCenter, radius: knobRadius * 1.2));
    canvas.drawCircle(knobCenter, knobRadius * 1.2, glare);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return oldDelegate.knobPos != knobPos;
  }
}
