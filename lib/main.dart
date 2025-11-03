import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// --- Cole os mesmos 4 UUIDs da Fase 3 aqui ---
const String SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
const String CHARACTERISTIC_UUID_S1 = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const String CHARACTERISTIC_UUID_S2 = "1c95d5e5-0466-4aa8-b8d9-e31d0ebf8453";
const String CHARACTERISTIC_UUID_S3 = "aa2b5a6c-486a-4b68-b118-a61f5c6b6d3b";
// -----------------------------------------------------

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sensores ESP32',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: SensorScreen(),
    );
  }
}

class SensorScreen extends StatefulWidget {
  @override
  _SensorScreenState createState() => _SensorScreenState();
}

class _SensorScreenState extends State<SensorScreen> {
  BluetoothDevice? _esp32Device;
  bool _isConnected = false;
  String _statusMessage = "Procurando por 'ESP32_Sensores'...";

  // Ponteiros para as características
  BluetoothCharacteristic? _sensor1Char;
  BluetoothCharacteristic? _sensor2Char;
  BluetoothCharacteristic? _sensor3Char;

  // Variáveis para guardar as leituras
  String _distancia1 = "---";
  String _distancia2 = "---";
  String _distancia3 = "---";

  // Streams para "ouvir" as notificações
  StreamSubscription<List<int>>? _s1Subscription;
  StreamSubscription<List<int>>? _s2Subscription;
  StreamSubscription<List<int>>? _s3Subscription;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    // Limpa tudo ao sair da tela
    _s1Subscription?.cancel();
    _s2Subscription?.cancel();
    _s3Subscription?.cancel();
    _esp32Device?.disconnect();
    super.dispose();
  }

  // 1. Inicia o Scan por dispositivos
  void _startScan() {
    setState(() {
      _statusMessage = "Procurando 'ESP32_Sensores'...";
      _distancia1 = _distancia2 = _distancia3 = "---";
      _isConnected = false;
    });

    FlutterBluePlus.startScan(timeout: Duration(seconds: 5));

    // Ouve os resultados do scan
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        // Compara o nome do dispositivo com o nome definido no ESP32
        if (r.device.platformName == "ESP32_Sensores") {
          FlutterBluePlus.stopScan(); // Para o scan
          _connectToDevice(r.device); // Conecta ao dispositivo
          break;
        }
      }
    });
  }

  // 2. Conecta ao dispositivo encontrado
  void _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _statusMessage = "Conectando...";
    });

    try {
      await device.connect(license:License.free);

      setState(() {
        _esp32Device = device;
        _isConnected = true;
        _statusMessage = "Conectado! Buscando serviços...";
      });

      _discoverServices(); // Busca os serviços/características
    } catch (e) {
      setState(() {
        _statusMessage = "Falha ao conectar: $e";
      });
    }
  }

  // 3. Descobre os Serviços e Características
  void _discoverServices() async {
    if (_esp32Device == null) return;

    List<BluetoothService> services = await _esp32Device!.discoverServices();
    for (BluetoothService service in services) {
      // Compara o UUID do Serviço
      if (service.uuid.toString() == SERVICE_UUID) {
        // Encontramos o serviço, agora procuramos as 3 características
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == CHARACTERISTIC_UUID_S1) {
            _sensor1Char = characteristic;
          } else if (characteristic.uuid.toString() == CHARACTERISTIC_UUID_S2) {
            _sensor2Char = characteristic;
          } else if (characteristic.uuid.toString() == CHARACTERISTIC_UUID_S3) {
            _sensor3Char = characteristic;
          }
        }
        
        // Se encontramos todas, vamos nos inscrever nelas
        if (_sensor1Char != null && _sensor2Char != null && _sensor3Char != null) {
          setState(() {
            _statusMessage = "Sensores encontrados! Inscrevendo...";
          });
          _subscribeToNotifications(); // O passo final
        }
        return; 
      }
    }
    setState(() {
      _statusMessage = "Serviço de sensores não encontrado.";
    });
  }

  // 4. Se inscreve para receber as Notificações
  void _subscribeToNotifications() async {
    if (_sensor1Char == null || _sensor2Char == null || _sensor3Char == null) return;

    // Limpa assinaturas antigas
    await _s1Subscription?.cancel();
    await _s2Subscription?.cancel();
    await _s3Subscription?.cancel();

    // Ativa o "Notify" para cada característica
    await _sensor1Char!.setNotifyValue(true);
    await _sensor2Char!.setNotifyValue(true);
    await _sensor3Char!.setNotifyValue(true);

    // Ouve o stream de dados do Sensor 1
    _s1Subscription = _sensor1Char!.lastValueStream.listen((value) {
      // 'value' é uma List<int> (bytes). Convertemos para String.
      String distancia = String.fromCharCodes(value);
      setState(() {
        _distancia1 = distancia;
      });
    });

    // Ouve o stream de dados do Sensor 2
    _s2Subscription = _sensor2Char!.lastValueStream.listen((value) {
      String distancia = String.fromCharCodes(value);
      setState(() {
        _distancia2 = distancia;
      });
    });

    // Ouve o stream de dados do Sensor 3
    _s3Subscription = _sensor3Char!.lastValueStream.listen((value) {
      String distancia = String.fromCharCodes(value);
      setState(() {
        _distancia3 = distancia;
      });
    });

    setState(() {
      _statusMessage = "Recebendo dados dos sensores!";
    });
  }

  // ----- Interface Gráfica (UI) -----
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Beyond Horizon - Sensores ESP32"),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              _statusMessage,
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            SizedBox(height: 30),
            _buildSensorDisplay("Sensor 1", _distancia1),
            SizedBox(height: 20),
            _buildSensorDisplay("Sensor 2", _distancia2),
            SizedBox(height: 20),
            _buildSensorDisplay("Sensor 3", _distancia3),
            SizedBox(height: 40),
            ElevatedButton(
              child: Text(_isConnected ? "Reconectar" : "Conectar"),
              onPressed: () {
                if(_esp32Device != null) {
                  _esp32Device!.disconnect();
                }
                _startScan();
              },
            )
          ],
        ),
      ),
    );
  }

  // Widget para mostrar a distância
  Widget _buildSensorDisplay(String nomeSensor, String distancia) {
    return Column(
      children: [
        Text(nomeSensor, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text(
          "$distancia cm",
          style: TextStyle(fontSize: 48, color: Colors.blue),
        ),
      ],
    );
  }
}