import 'dart:async';
import 'dart:collection'; // Import para filas (Queue)
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
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
        scaffoldBackgroundColor: const Color(0xFF000000), // Preto absoluto
        primaryColor: Colors.blueAccent,
        textTheme: ThemeData.dark().textTheme,
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
  // --- CONFIGURAÇÃO BLE (UUIDs do ESP32) ---
  final String targetDeviceName = "ESP32_Capacete";
  final String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";

  final String charUuidS1 = "beb5483e-36e1-4688-b7f5-ea07361b26a8"; // FRENTE
  final String charUuidS2 = "1c95d5e5-0466-4aa8-b8d9-e31d0ebf8453"; // ESQUERDA
  final String charUuidS3 = "aa2b5a6c-486a-4b68-b118-a61f5c6b6d3b"; // DIREITA

  // --- VARIÁVEIS DE CONTROLE ---
  BluetoothDevice? _device;
  StreamSubscription? _scanSub;
  StreamSubscription? _subS1, _subS2, _subS3;

  bool _isConnected = false;
  bool _isScanning = false;
  String _status = "Toque em CONECTAR";

  // Valores de Tela
  String txtFrente = "--";
  String txtEsq = "--";
  String txtDir = "--";

  // --- BUFFER DE MEMÓRIA (Janela Deslizante) ---
  final int tamanhoBuffer = 10;
  List<double> histFrente = [];
  List<double> histEsq = [];
  List<double> histDir = [];

  // --- SISTEMA DE ÁUDIO ---
  final FlutterTts flutterTts = FlutterTts();
  final Queue<String> _filaAltaPrioridade = Queue<String>();
  final Queue<String> _filaNormalPrioridade = Queue<String>();

  bool _processandoAudio = false;
  bool _falandoAlgoDeAltaPrioridade = false;

  // Spam Filter
  String _ultimaMensagemDita = "";
  DateTime _tempoUltimaFala = DateTime.now();

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
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
  }

  Future<void> _initTTS() async {
    await flutterTts.setLanguage("pt-BR");
    await flutterTts.setSpeechRate(0.6);
    await flutterTts.setVolume(1.0);
    await flutterTts.awaitSpeakCompletion(true);
  }

  // =================================================================
  // --- GERENCIADOR DE ÁUDIO ---
  // =================================================================

  void _adicionarFilaVoz(String mensagem, {bool ehAltaPrioridade = false}) async {
    // Filtro: Não repete a mesma frase em menos de 3 segundos
    if (_ultimaMensagemDita == mensagem && DateTime.now().difference(_tempoUltimaFala).inSeconds < 3) {
      return;
    }

    if (ehAltaPrioridade) {
      if (!_filaAltaPrioridade.contains(mensagem)) {
        _filaAltaPrioridade.add(mensagem);
        if (_processandoAudio && !_falandoAlgoDeAltaPrioridade) {
          await flutterTts.stop(); // Interrompe fala normal para emergência
        }
      }
    } else {
      if (!_filaNormalPrioridade.contains(mensagem) && !_filaAltaPrioridade.contains(mensagem)) {
        _filaNormalPrioridade.add(mensagem);
      }
    }

    if (!_processandoAudio) _processarFilasDeAudio();
  }

  Future<void> _processarFilasDeAudio() async {
    if (_processandoAudio) return;
    _processandoAudio = true;

    while (_filaAltaPrioridade.isNotEmpty || _filaNormalPrioridade.isNotEmpty) {
      String msg = "";

      if (_filaAltaPrioridade.isNotEmpty) {
        msg = _filaAltaPrioridade.removeFirst();
        _falandoAlgoDeAltaPrioridade = true;
      } else if (_filaNormalPrioridade.isNotEmpty) {
        msg = _filaNormalPrioridade.removeFirst();
        _falandoAlgoDeAltaPrioridade = false;
      }

      if (msg.isNotEmpty) {
        _ultimaMensagemDita = msg;
        _tempoUltimaFala = DateTime.now();
        await flutterTts.speak(msg);
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    _processandoAudio = false;
    _falandoAlgoDeAltaPrioridade = false;
  }

  // =================================================================
  // --- MATEMÁTICA E HELPERS ---
  // =================================================================

  double _calcularMedia(List<double> lista) {
    if (lista.isEmpty) return 0.0;
    double soma = lista.reduce((a, b) => a + b);
    return soma / lista.length;
  }

  void _adicionarAoHistorico(List<double> lista, double valor) {
    lista.add(valor);
    if (lista.length > tamanhoBuffer) lista.removeAt(0);
  }

  // Retorna diferença: Positivo = APROXIMANDO, Negativo = AFASTANDO
  double _calcularTendencia(List<double> historico) {
    if (historico.length < 5) return 0.0;
    double mediaAntiga = _calcularMedia(historico.sublist(0, 5));
    double mediaRecente = _calcularMedia(historico.sublist(historico.length - 5));
    return mediaAntiga - mediaRecente;
  }

  // =================================================================
  // --- LÓGICA DE ANÁLISE SEPARADA ---
  // =================================================================

  void _analisarFrente(List<double> buffer) {
    if (buffer.length < tamanhoBuffer) return;

    double mediaAtual = _calcularMedia(buffer);
    double tendencia = _calcularTendencia(buffer);

    // 1. EMERGÊNCIA (PARE!)
    if (mediaAtual < 60) {
      _adicionarFilaVoz("Pare! Frente.", ehAltaPrioridade: true);
      return;
    }

    // 2. ATENÇÃO RÁPIDA (Alguém entrou na frente)
    if (tendencia > 40 && mediaAtual < 180) {
      _adicionarFilaVoz("Atenção frente.", ehAltaPrioridade: true);
      return;
    }
  }

  void _analisarLateral(List<double> buffer, String lado) {
    if (buffer.length < tamanhoBuffer) return;

    double mediaAtual = _calcularMedia(buffer);
    double tendencia = _calcularTendencia(buffer);

    // 1. APROXIMAÇÃO PERIGOSA (Andando torto)
    if (tendencia > 30 && mediaAtual < 60) {
      _adicionarFilaVoz("Cuidado $lado.", ehAltaPrioridade: true);
      return;
    }

    // 2. DETECÇÃO DE ABERTURA (Portas)
    // Estava PERTO (<80) e ficou LONGE (>150)
    double mediaAntiga = _calcularMedia(buffer.sublist(0, 5));
    if (mediaAntiga < 80 && mediaAtual > 150) {
      _adicionarFilaVoz("Abertura à $lado.");
    }
  }

  // =================================================================
  // --- RECEBEDORES DE DADOS (CALLBACKS ESPECÍFICOS) ---
  // =================================================================

  void _receberDadosFrente(String valorRaw) {
    try {
      double? valor = double.tryParse(valorRaw);
      if (valor == null) return;

      _adicionarAoHistorico(histFrente, valor);
      double media = _calcularMedia(histFrente);

      if (mounted) setState(() => txtFrente = media.toStringAsFixed(0));

      // Chama análise específica
      _analisarFrente(histFrente);
    } catch (e) { /* Ignora erro de parse */ }
  }

  void _receberDadosEsquerda(String valorRaw) {
    try {
      double? valor = double.tryParse(valorRaw);
      if (valor == null) return;

      _adicionarAoHistorico(histEsq, valor);
      double media = _calcularMedia(histEsq);

      if (mounted) setState(() => txtEsq = media.toStringAsFixed(0));

      // Chama análise específica
      _analisarLateral(histEsq, "esquerda");
    } catch (e) {}
  }

  void _receberDadosDireita(String valorRaw) {
    try {
      double? valor = double.tryParse(valorRaw);
      if (valor == null) return;

      _adicionarAoHistorico(histDir, valor);
      double media = _calcularMedia(histDir);

      if (mounted) setState(() => txtDir = media.toStringAsFixed(0));

      // Chama análise específica
      _analisarLateral(histDir, "direita");
    } catch (e) {}
  }

  // =================================================================
  // --- BLUETOOTH ---
  // =================================================================

  void _startScan() {
    if (_isConnected) { _disconnect(); return; }
    setState(() { _isScanning = true; _status = "Procurando..."; });
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
      await device.connect(autoConnect: false, license: License.free);
      _device = device;

      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            _isConnected = false; _status = "Conexão Perdida";
            txtFrente = "--"; txtEsq = "--"; txtDir = "--";
            histFrente.clear(); histEsq.clear(); histDir.clear();
          });
          _adicionarFilaVoz("Conexão perdida", ehAltaPrioridade: true);
        }
      });

      if (mounted) {
        setState(() { _isConnected = true; _isScanning = false; _status = "Sistema Ativo"; });
        _adicionarFilaVoz("Conectado.", ehAltaPrioridade: true);
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

          // AQUI ESTÁ A MUDANÇA: Cada UUID aponta para sua função específica
          if (uuid == charUuidS1) { // FRENTE
            _subS1 = c.lastValueStream.listen((val) {
              _receberDadosFrente(String.fromCharCodes(val));
            });
          } else if (uuid == charUuidS2) { // ESQUERDA
            _subS2 = c.lastValueStream.listen((val) {
              _receberDadosEsquerda(String.fromCharCodes(val));
            });
          } else if (uuid == charUuidS3) { // DIREITA
            _subS3 = c.lastValueStream.listen((val) {
              _receberDadosDireita(String.fromCharCodes(val));
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
  // --- UI (Mantida Igual) ---
  // =================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Assistente Visual", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
            child: SizedBox(
              width: double.infinity,
              height: 65,
              child: ElevatedButton.icon(
                icon: Icon(_isConnected ? Icons.stop_circle : Icons.play_circle, size: 30),
                label: Text(
                  _isConnected ? "DESCONECTAR" : "CONECTAR",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
                ),
                onPressed: _isScanning ? null : (_isConnected ? _disconnect : _startScan),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isConnected ? Colors.red[800] : Colors.yellowAccent,
                  foregroundColor: _isConnected ? Colors.white : Colors.black,
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
    String display = (value == "400" || value == "400.0") ? "> 4m" : value;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: isMain ? 30 : 20, horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: isMain ? 3 : 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold)),
          Row(
            children: [
              Text(
                display,
                style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontFamily: 'Monospace'
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