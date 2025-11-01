import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

void main() {
  runApp(CarControllerApp());
}

class CarControllerApp extends StatefulWidget {
  @override
  _CarControllerAppState createState() => _CarControllerAppState();
}

class _CarControllerAppState extends State<CarControllerApp> {
  final client = MqttServerClient('mqttgo.io', 'flutter_car_android');
  String status = '🔌 尚未連線';
  bool isConnected = false;

  @override
  void initState() {
    super.initState();
    _connectToBroker();
  }

  Future<void> _connectToBroker() async {
    setState(() => status = '⏳ 嘗試連線中...');
    client.port = 1883;
    client.keepAlivePeriod = 20;
    client.logging(on: false);
    client.onDisconnected = _onDisconnected;

    try {
      await client.connect();
      setState(() {
        isConnected = true;
        status = '✅ 已連線至 MQTTGO.io';
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

  void _sendCommand(String cmd) {
    if (!isConnected) return;
    final builder = MqttClientPayloadBuilder()..addString(cmd);
    client.publishMessage('Car/Control', MqttQos.atMostOnce, builder.payload!);
    setState(() => status = '📡 已發送指令：$cmd');
  }

  Widget _controlButton(String text, Color color) {
    return ElevatedButton(
      onPressed: isConnected ? () => _sendCommand(text) : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        fixedSize: const Size(90, 90),
        shape: const CircleBorder(),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Raspberry Pi Car Panel',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.grey[900],
        appBar: AppBar(
          backgroundColor: Colors.blueGrey[800],
          title: const Text('🚗 Raspberry Pi Car Panel'),
          centerTitle: true,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                status,
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _controlButton('A', Colors.orange),
                  const SizedBox(width: 20),
                  _controlButton('W', Colors.green),
                  const SizedBox(width: 20),
                  _controlButton('D', Colors.orange),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _controlButton('S', Colors.teal),
                  const SizedBox(width: 20),
                  _controlButton('R', Colors.red),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
