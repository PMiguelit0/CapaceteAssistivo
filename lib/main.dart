import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Assistente Visual',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF000000), // Preto absoluto para contraste
        primaryColor: Colors.blueAccent,
        textTheme: GoogleFonts.robotoTextTheme(ThemeData.dark().textTheme),
      ),
      home: const SensorDashboard(),
    );
  }
}

class SensorDashboard extends StatefulWidget {
  const SensorDashboard({super.key});

  @override
  State<SensorDashboard> createState() => _SensorDashboardState();
}

class _SensorDashboardState extends State<SensorDashboard> {
  // --- CONFIGURAÇÃO DO BLE ---
  final String targetDeviceName = "ESP32_Capacete";
  final String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";

  final String charUuidS1 = "beb5483e-36e1-4688-b7f5-ea07361b26a8"; // Frente
  final String charUuidS2 = "1c95d5e5-0466-4aa8-b8d9-e31d0ebf8453"; // Esquerda
  final String charUuidS3 = "aa2b5a6c-486a-4b68-b118-a61f5c6b6d3b"; // Direita

  // --- VARIÁVEIS DE CONTROLE ---
  BluetoothDevice? _device;
  StreamSubscription? _scanSub;
  StreamSubscription? _subS1, _subS2, _subS3;

  bool _isConnected = false;
  bool _isScanning = false;
  String _status = "Toque em CONECTAR";

  // Valores para Exibição na Tela (UI)
  String txtFrente = "--";
  String txtEsq = "--";
  String txtDir = "--";

  // --- MEMÓRIA (BUFFER) PARA ANÁLISE INTELIGENTE ---
  // Guardamos as últimas 10 leituras para analisar tendências
  final int tamanhoBuffer = 10;
  List<double> histFrente = [];
  List<double> histEsq = [];
  List<double> histDir = [];

  // --- CONFIGURAÇÃO DE FALA (TTS) ---
  final FlutterTts flutterTts = FlutterTts();
  DateTime lastSpoken = DateTime.now(); // Timer para não falar demais

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _initTTS();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _subS1?.cancel(); _subS2?.cancel(); _subS3?.cancel();
    _device?.disconnect();
    flutterTts.stop();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  Future<void> _initTTS() async {
    await flutterTts.setLanguage("pt-BR");
    await flutterTts.setSpeechRate(0.6); // Velocidade um pouco mais lenta para clareza
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);
  }

  // =================================================================
  // --- LÓGICA DE INTELIGÊNCIA ARTIFICIAL (ANÁLISE DE AMBIENTE) ---
  // =================================================================

  // Auxiliar: Calcula média de uma lista
  double _calcularMedia(List<double> lista) {
    if (lista.isEmpty) return 400.0;
    double soma = lista.reduce((a, b) => a + b);
    return soma / lista.length;
  }

  // Gerencia o Buffer: Adiciona novo, remove antigo
  void _adicionarAoHistorico(List<double> lista, double valor) {
    // Ignora leituras < 2cm (ruído do sensor)
    if (valor <= 2.0) return;

    lista.add(valor);
    if (lista.length > tamanhoBuffer) {
      lista.removeAt(0); // Remove o mais antigo
    }
  }

  // O CÉREBRO: Analisa os dados e decide o que falar
  void _analisarPadroes() {
    // 1. Verifica se temos dados suficientes (mínimo 5 leituras)
    if (histFrente.length < 5 || histEsq.length < 5 || histDir.length < 5) return;

    // 2. Verifica timer: Só fala a cada 3 segundos (exceto emergência)
    if (DateTime.now().difference(lastSpoken).inMilliseconds < 3000) {
      // Exceção: Se for emergência (muito perto), fala agora mesmo!
      if (histFrente.last < 50) { /* deixa passar */ } else { return; }
    }

    // Calcula as médias atuais
    double mediaFrente = _calcularMedia(histFrente);
    double mediaEsq = _calcularMedia(histEsq);
    double mediaDir = _calcularMedia(histDir);

    String mensagem = "";

    // --- ANÁLISE DE SEGURANÇA (CRÍTICO) ---
    if (histFrente.last < 60) {
      mensagem = "Pare. Obstáculo à frente.";
    }
    else if (histEsq.last < 40) {
      mensagem = "Muito perto da esquerda.";
    }
    else if (histDir.last < 40) {
      mensagem = "Muito perto da direita.";
    }

    // --- ANÁLISE DE TENDÊNCIA (APROXIMAÇÃO) ---
    // Se estava longe (início da lista) e agora está perto (fim da lista)
    // Ex: 200 -> 180 -> 160 -> 140
    else if ((histFrente.first - histFrente.last > 60) && mediaFrente < 150) {
      mensagem = "Aproximando de obstáculo.";
    }

    // --- ANÁLISE DE DETECÇÃO DE ABERTURA (PORTA) ---
    // Média antiga era BAIXA (<80), Média recente é ALTA (>150)
    else {
      double esqAntiga = _calcularMedia(histEsq.sublist(0, 5));
      double esqRecente = _calcularMedia(histEsq.sublist(histEsq.length - 3));

      double dirAntiga = _calcularMedia(histDir.sublist(0, 5));
      double dirRecente = _calcularMedia(histDir.sublist(histDir.length - 3));

      if (esqAntiga < 80 && esqRecente > 150) {
        mensagem = "Abertura à esquerda.";
      }
      else if (dirAntiga < 80 && dirRecente > 150) {
        mensagem = "Abertura à direita.";
      }

      // --- ANÁLISE DE CORREDOR ---
      // Esquerda e Direita apertadas, Frente livre
      else if (mediaEsq < 100 && mediaDir < 100 && mediaFrente > 150) {
        mensagem = "Corredor detectado. Siga em frente.";
      }
    }

    // --- EXECUTAR FALA ---
    if (mensagem.isNotEmpty) {
      flutterTts.speak(mensagem);
      lastSpoken = DateTime.now(); // Reseta timer
    }
  }

  // Função chamada quando chega dado do Bluetooth
  void _processarSensor(String valorRaw, Function(String) updateUI, List<double> bufferHistorico) {
    try {
      double distancia = double.parse(valorRaw);

      // Atualiza UI
      if (mounted) updateUI(valorRaw);

      // Adiciona na memória e analisa
      _adicionarAoHistorico(bufferHistorico, distancia);
      _analisarPadroes();

    } catch (e) {
      // Ignora erro de parse
    }
  }

  // =================================================================
  // --- LÓGICA BLUETOOTH (CONEXÃO) ---
  // =================================================================

  void _startScan() {
    if (_isConnected) { _disconnect(); return; }

    setState(() { _isScanning = true; _status = "Procurando Capacete..."; });

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.platformName == targetDeviceName) {
          FlutterBluePlus.stopScan();
          _connectToDevice(r.device);
          break;
        }
      }
    });

    Future.delayed(const Duration(seconds: 5), () {
      if (!_isConnected && mounted) {
        setState(() { _isScanning = false; _status = "Não encontrado."; });
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() => _status = "Conectando...");
    try {
      await device.connect(autoConnect: false,license: License.free);
      _device = device;

      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            _isConnected = false; _status = "Conexão Perdida";
            txtFrente = "--"; txtEsq = "--"; txtDir = "--";
            // Limpa históricos para não dar avisos falsos ao reconectar
            histFrente.clear(); histEsq.clear(); histDir.clear();
          });
          flutterTts.speak("Conexão perdida");
        }
      });

      if (mounted) {
        setState(() { _isConnected = true; _isScanning = false; _status = "Sistema Ativo"; });
        flutterTts.speak("Sistema conectado. Iniciando navegação.");
      }

      await _discoverServices(device);

    } catch (e) {
      if (mounted) setState(() => _status = "Erro de Conexão");
    }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (var service in services) {
      if (service.uuid.toString() == serviceUuid) {
        for (var c in service.characteristics) {
          String uuid = c.uuid.toString();
          await c.setNotifyValue(true);

          if (uuid == charUuidS1) { // Frente
            _subS1 = c.lastValueStream.listen((val) {
              String s = String.fromCharCodes(val);
              _processarSensor(s, (v) => setState(() => txtFrente = v), histFrente);
            });
          }
          else if (uuid == charUuidS2) { // Esquerda
            _subS2 = c.lastValueStream.listen((val) {
              String s = String.fromCharCodes(val);
              _processarSensor(s, (v) => setState(() => txtEsq = v), histEsq);
            });
          }
          else if (uuid == charUuidS3) { // Direita
            _subS3 = c.lastValueStream.listen((val) {
              String s = String.fromCharCodes(val);
              _processarSensor(s, (v) => setState(() => txtDir = v), histDir);
            });
          }
        }
      }
    }
  }

  void _disconnect() async {
    await _device?.disconnect();
    if (mounted) setState(() => _isConnected = false);
  }

  // =================================================================
  // --- INTERFACE GRÁFICA (ALTO CONTRASTE) ---
  // =================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Navegação Assistiva", style: GoogleFonts.orbitron(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Barra de Status
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: _isConnected ? Colors.green[900] : Colors.red[900],
            child: Text(
              _status.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),

          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildCard("ESQUERDA", txtEsq, Colors.purpleAccent),
                  _buildCard("FRENTE", txtFrente, Colors.cyanAccent, isMain: true),
                  _buildCard("DIREITA", txtDir, Colors.orangeAccent),
                ],
              ),
            ),
          ),

          // Botão Grande
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
            child: SizedBox(
              width: double.infinity,
              height: 65,
              child: ElevatedButton.icon(
                icon: Icon(_isConnected ? Icons.stop_circle : Icons.play_circle, size: 30),
                label: Text(
                  _isConnected ? "PARAR SISTEMA" : "INICIAR SISTEMA",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
                ),
                onPressed: _isScanning ? null : (_isConnected ? _disconnect : _startScan),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isConnected ? Colors.red[800] : Colors.yellowAccent,
                  foregroundColor: _isConnected ? Colors.white : Colors.black, // Contraste texto/fundo
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(String label, String value, Color color, {bool isMain = false}) {
    // Formata o valor para a tela (se for 400 mostra >4m)
    String display = (value == "400.0" || value == "400") ? "> 4m" : value;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: isMain ? 30 : 20, horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E), // Cinza muito escuro
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: isMain ? 3 : 1), // Borda colorida para identificação
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold)),
          Row(
            children: [
              Text(
                display,
                style: GoogleFonts.orbitron(
                  fontSize: isMain ? 48 : 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              if (display != "> 4m" && display != "--")
                const Padding(
                  padding: EdgeInsets.only(left: 8.0, top: 10),
                  child: Text("cm", style: TextStyle(color: Colors.white54, fontSize: 16)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}