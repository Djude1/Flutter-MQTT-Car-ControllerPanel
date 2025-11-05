import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 鎖定橫向顯示 + 沉浸式（正式版多用沉浸式避免誤觸）
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

  // ===== Analog 連續控制（-1~+1）=====
  double throttle = 0.0; // 只用於 UI 顯示，實際傳輸走平滑/量化/門檻後的值
  double steer = 0.0;

  // ===== 低頻化/降精度/穩定性參數 =====
  final Duration txInterval = const Duration(milliseconds: 80); // 固定頻率傳輸，避免 onPan 高頻 spam
  final double deadzone = 0.10;       // 小幅度忽略，避免車身抖動
  final double smoothAlpha = 0.35;    // EMA 平滑係數（越大越靈敏，越小越穩）
  final double step = 0.10;           // 量化步進（0.10 → 共 21 檔）
  final double minDeltaToSend = 0.05; // 與上次「已送值」差異門檻，小於不送

  // 平滑/門檻狀態
  double _rawThr = 0.0, _rawSt = 0.0; // 原始搖桿值
  double _smThr = 0.0, _smSt = 0.0;   // EMA 平滑後
  double _lastSentThr = 0.0, _lastSentSt = 0.0; // 最近一次「實際已送」的值

  // 互動/傳送控制
  Timer? _txTimer;
  bool _dragging = false;

  // 顯示用
  String currentDirText = '—';
  double currentPower = 0.0; // 0~1

  @override
  void initState() {
    super.initState();
    _setupMqtt();
    _startTxTimer();
  }

  @override
  void dispose() {
    _txTimer?.cancel();
    client.disconnect();
    super.dispose();
  }

  // ========== MQTT 連線 ==========

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

  /// 發送 JSON 指令（預設 QoS0 低延遲）
  void _publishJson(Map<String, dynamic> obj, {MqttQos qos = MqttQos.atMostOnce}) {
    if (!isConnected) return;
    final builder = MqttClientPayloadBuilder()..addString(jsonEncode(obj));
    client.publishMessage(topic, qos, builder.payload!);
    setState(() => status = '📡 已發送：${jsonEncode(obj)}');
  }

  /// **安全停車保險**：連續發送 STOP（QoS1）
  /// 目的：覆蓋可能在網路上延遲的舊封包，避免「鬆手車還在跑」
  Future<void> _sendStopBurst() async {
    if (!isConnected) return;
    for (int i = 0; i < 3; i++) {
      _publishJson({"throttle": 0, "steer": 0}, qos: MqttQos.atLeastOnce);
      await Future.delayed(txInterval);
    }
  }

  // ========== 降精度/平滑/門檻流水線 ==========

  /// 量化數值（讓控制呈現「檔位感」，更穩也更省頻寬）
  double _quantize(double x) {
    final q = (x / step).round() * step;
    return q.clamp(-1.0, 1.0);
  }

  /// 以固定頻率傳輸，並在此做：EMA 平滑 → Deadzone → 量化 → 變化門檻
  void _startTxTimer() {
    _txTimer?.cancel();
    _txTimer = Timer.periodic(txInterval, (_) {
      if (!isConnected) return;

      // 1) EMA 平滑（用 _raw* 追 _sm*）
      _smThr += (_rawThr - _smThr) * smoothAlpha;
      _smSt  += (_rawSt  - _smSt ) * smoothAlpha;

      // 2) 不在拖曳狀態：立即且只送一次 0，避免殘留
      if (!_dragging) {
        if (_lastSentThr != 0.0 || _lastSentSt != 0.0) {
          _lastSentThr = 0.0;
          _lastSentSt = 0.0;
          _publishJson({"throttle": 0, "steer": 0}, qos: MqttQos.atLeastOnce);
        }
        return;
      }

      // 3) Deadzone 過濾
      final dzThr = (_smThr.abs() < deadzone) ? 0.0 : _smThr;
      final dzSt  = (_smSt.abs()  < deadzone) ? 0.0 : _smSt;

      // 4) 量化
      final thr = _quantize(dzThr);
      final st  = _quantize(dzSt);

      // 5) 變化門檻（相對於「上次已送」）
      final needSend = (thr - _lastSentThr).abs() >= minDeltaToSend ||
          (st  - _lastSentSt ).abs() >= minDeltaToSend;

      if (!needSend) return;

      _lastSentThr = thr;
      _lastSentSt  = st;

      _publishJson({
        "throttle": double.parse(thr.toStringAsFixed(2)),
        "steer": double.parse(st.toStringAsFixed(2)),
      });
    });
  }

  // ========== Joystick 事件 ==========

  /// 搖桿變動：更新原始輸入（由計時器負責平滑/量化/門檻與傳輸）
  /// offset: (-1~1, -1~1)；螢幕座標 y 向上為負
  void _onStickChanged(Offset offset) {
    _dragging = true;

    // 顯示用
    final power = offset.distance.clamp(0.0, 1.0);
    currentPower = power;
    final angle = math.atan2(-offset.dy, offset.dx);
    currentDirText = _angleToText(angle, power);

    // 原始輸入（交給計時器去處理）
    _rawThr = (-offset.dy).clamp(-1.0, 1.0); // 上推前進
    _rawSt  = ( offset.dx).clamp(-1.0, 1.0); // 右推右轉

    // 同步 UI（不代表實際送出的量）
    throttle = _rawThr;
    steer    = _rawSt;

    setState(() {});
  }

  /// 放手：立即歸零並觸發安全停車保險
  void _onStickReleased() {
    _dragging = false;

    // UI 立刻歸零
    currentPower = 0.0;
    currentDirText = '—';
    throttle = 0.0;
    steer = 0.0;

    // 內部狀態歸零，避免慢慢回
    _rawThr = 0.0; _rawSt = 0.0;
    _smThr  = 0.0; _smSt  = 0.0;

    // 立即送一次 0 + Stop Burst
    _publishJson({"throttle": 0, "steer": 0}, qos: MqttQos.atLeastOnce);
    _sendStopBurst();

    // 標記「已送 0」
    _lastSentThr = 0.0; _lastSentSt = 0.0;

    setState(() {});
  }

  // 角度 + 強度 → 顯示文字
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

  // ========== UI 元件 ==========

  /// 正式版的主題與背景
  ThemeData get _theme => ThemeData(
    brightness: Brightness.dark,
    colorSchemeSeed: const Color(0xFF2EE6A6),
    scaffoldBackgroundColor: Colors.transparent, // 用漸層容器
    useMaterial3: true,
  );

  BoxDecoration get _bgGradient => const BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF0F1115), Color(0xFF101826), Color(0xFF0C131C)],
    ),
  );

  BoxDecoration _glass() => BoxDecoration(
    color: const Color(0x331A2030),
    borderRadius: BorderRadius.circular(18),
    border: Border.all(color: const Color(0x225C6A82)),
    boxShadow: const [BoxShadow(blurRadius: 18, spreadRadius: -6, color: Colors.black45)],
  );

  Widget _pillButton(String text, Color color, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 6,
      ),
      child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    );
  }

  Widget _actionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _pillButton('⛔ STOP', Colors.redAccent, () => _onStickReleased()),
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

  /// ✅ 防溢位版本的狀態卡片
  /// 上行：圖示 + 狀態文字（Expanded）
  /// 下行：Wrap 方式排列 Tag，自動換行 → 杜絕 RenderFlex overflow
  Widget _statusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _glass(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isConnected ? Icons.podcasts_rounded : Icons.podcasts_outlined,
                color: isConnected ? Colors.greenAccent : Colors.redAccent,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _tag('Topic', topic),
              _tag('Client', client.clientIdentifier ?? '—'),
            ],
          ),
        ],
      ),
    );
  }

  // 右側小統計卡（標題在左、值在右）
  Widget _miniStat(String title, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: _glass(),
      child: Row(
        children: [
          Text(title, style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  // Tag 膠囊
  Widget _tag(String k, String v) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x1A2EE6A6),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x335C6A82)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$k: ', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        ],
      ),
    );
  }

  // 遙測列（顯示「實際已送出」的百分比）
  Widget _telemetryRow() {
    final thrPct = (_lastSentThr * 100).toStringAsFixed(0);
    final stPct  = (_lastSentSt  * 100).toStringAsFixed(0);
    return Row(
      children: [
        Expanded(child: _miniStat('方向', currentDirText)),
        const SizedBox(width: 12),
        Expanded(child: _miniStat('油門', '$thrPct %')),
        const SizedBox(width: 12),
        Expanded(child: _miniStat('轉向', '$stPct %')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 控制字級膨脹，避免可及性字級把 Row 撐爆
    final media = MediaQuery.of(context);
    final clampedTextScale = media.textScaleFactor.clamp(1.0, 1.15);
    return MediaQuery(
      data: media.copyWith(textScaleFactor: clampedTextScale),
      child: MaterialApp(
        title: 'Raspberry Pi Car Panel',
        debugShowCheckedModeBanner: false,
        theme: _theme,
        home: Scaffold(
          body: Container(
            decoration: _bgGradient,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    // ===== 左側：大搖桿 =====
                    Expanded(
                      flex: 5,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 460),
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
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
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

                    // ===== 右側：資訊面板 + 控制 =====
                    Expanded(
                      flex: 6,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 14),
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
                                    Row(
                                      children: const [
                                        Icon(Icons.tune, size: 18, color: Colors.white70),
                                        SizedBox(width: 6),
                                        Text('控制面板',
                                            style: TextStyle(
                                                fontSize: 16, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    _actionButtons(),
                                    const Spacer(),
                                    const Divider(height: 24),
                                    const Text(
                                      '提示：拖曳左側搖桿同時控制前進/後退與左/右轉。放手停車。',
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
          ),
        ),
      ),
    );
  }
}

/// ======================= Joystick Widget（無第三方套件）=======================
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = math.min(c.maxWidth, c.maxHeight);
      final knobRadius = size * 0.12;
      final baseRadius = size * 0.42; // 最大拖曳半徑（定義搖桿力道）

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

    // 轉換成 -1~1 的座標，並限制在 baseRadius 內
    if (delta.distance > baseRadius) {
      delta = Offset.fromDirection(delta.direction, baseRadius);
    }
    final normalized = Offset(delta.dx / baseRadius, delta.dy / baseRadius);

    setState(() => _knobPos = normalized);
    widget.onChanged(_knobPos);
  }

  void _endDrag() {
    setState(() => _knobPos = Offset.zero);
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

    // knob（帶外光暈）
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
