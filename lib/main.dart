import 'dart:async';
import 'dart:collection'; // Import para filas (Queue)
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart'; // Mantido para fontes seguras, se houver internet
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
        scaffoldBackgroundColor: const Color(0xFF000000), // Preto absoluto (Alto Contraste)
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
  final int tamanhoBuffer = 10; // ~1 segundo de histórico
  List<double> histFrente = [];
  List<double> histEsq = [];
  List<double> histDir = [];

  // --- SISTEMA DE ÁUDIO (DUPLA FILA) ---
  final FlutterTts flutterTts = FlutterTts();
  final Queue<String> _filaAltaPrioridade = Queue<String>();   // Emergências (PARE!)
  final Queue<String> _filaNormalPrioridade = Queue<String>(); // Navegação (Porta, Corredor)

  bool _processandoAudio = false;
  bool _falandoAlgoDeAltaPrioridade = false;

  // Controle de repetição (Spam Filter)
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
    await flutterTts.setSpeechRate(0.6); // Fala pausada e clara
    await flutterTts.setVolume(1.0);
    // CRÍTICO: Garante que o app espere a voz terminar antes de continuar a fila
    await flutterTts.awaitSpeakCompletion(true);
  }

  // =================================================================
  // --- GERENCIADOR DE ÁUDIO (PRIORITY QUEUE) ---
  // =================================================================

  void _adicionarFilaVoz(String mensagem, {bool ehAltaPrioridade = false}) async {
    // Filtro Anti-Spam: Não repete a mesma frase em menos de 3 segundos
    if (_ultimaMensagemDita == mensagem && DateTime.now().difference(_tempoUltimaFala).inSeconds < 3) {
      return;
    }

    if (ehAltaPrioridade) {
      if (!_filaAltaPrioridade.contains(mensagem)) {
        _filaAltaPrioridade.add(mensagem);


        if (_processandoAudio && !_falandoAlgoDeAltaPrioridade) {
          await flutterTts.stop();
        }
      }
    } else {
      // Mensagens normais entram no fim da fila
      if (!_filaNormalPrioridade.contains(mensagem) && !_filaAltaPrioridade.contains(mensagem)) {
        _filaNormalPrioridade.add(mensagem);
      }
    }

    // Se o processador de áudio estiver dormindo, acorda ele
    if (!_processandoAudio) _processarFilasDeAudio();
  }

  Future<void> _processarFilasDeAudio() async {
    if (_processandoAudio) return;
    _processandoAudio = true;

    // Loop enquanto houver mensagens
    while (_filaAltaPrioridade.isNotEmpty || _filaNormalPrioridade.isNotEmpty) {
      String msg = "";

      // 1. Sempre verifica a Alta Prioridade primeiro
      if (_filaAltaPrioridade.isNotEmpty) {
        msg = _filaAltaPrioridade.removeFirst();
        _falandoAlgoDeAltaPrioridade = true; // Protege contra interrupção
      }
      // 2. Só atende a Normal se a Alta estiver vazia
      else if (_filaNormalPrioridade.isNotEmpty) {
        msg = _filaNormalPrioridade.removeFirst();
        _falandoAlgoDeAltaPrioridade = false; // Pode ser interrompido
      }

      if (msg.isNotEmpty) {
        _ultimaMensagemDita = msg;
        _tempoUltimaFala = DateTime.now();
        await flutterTts.speak(msg);
        // Pequena pausa para respiração entre frases
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    _processandoAudio = false;
    _falandoAlgoDeAltaPrioridade = false;
  }

  // =================================================================
  // --- INTELIGÊNCIA ARTIFICIAL (ANÁLISE DE PADRÕES) ---
  // =================================================================

  double _calcularMedia(List<double> lista) {
    if (lista.isEmpty) return 400.0;
    double soma = lista.reduce((a, b) => a + b);
    return soma / lista.length;
  }

  void _adicionarAoHistorico(List<double> lista, double valor) {
    // Filtra ruído elétrico do sensor (< 2cm)
    if (valor <= 2.0) return;
    lista.add(valor);
    if (lista.length > tamanhoBuffer) lista.removeAt(0);
  }

  void _analisarPadroes() {
    // Só analisa se o buffer estiver cheio (dados confiáveis)
    if (histFrente.length < tamanhoBuffer || histEsq.length < tamanhoBuffer || histDir.length < tamanhoBuffer) return;

    // --- CÁLCULO DE MÉDIAS ---
    double mediaFrente = _calcularMedia(histFrente); // Estado Atual Geral

    // Comparação Passado (Início do Buffer) vs Presente (Fim do Buffer)
    // Usamos blocos de 5 leituras para evitar falsos positivos
    double mediaAntigaFrente = _calcularMedia(histFrente.sublist(0, 5));
    double mediaRecenteFrente = _calcularMedia(histFrente.sublist(histFrente.length - 5));

    double mediaAntigaEsq = _calcularMedia(histEsq.sublist(0, 5));
    double mediaRecenteEsq = _calcularMedia(histEsq.sublist(histEsq.length - 5));

    double mediaAntigaDir = _calcularMedia(histDir.sublist(0, 5));
    double mediaRecenteDir = _calcularMedia(histDir.sublist(histDir.length - 5));


    // 1. EMERGÊNCIA (PARE!) - Prioridade Alta
    if (mediaFrente < 60) {
      _adicionarFilaVoz("Pare! Frente.", ehAltaPrioridade: true);
      return;
    }

    // 2. TENDÊNCIA DE APROXIMAÇÃO (Diferença > 30cm) - Prioridade Alta
    if ((mediaAntigaEsq - mediaRecenteEsq > 30) && mediaRecenteEsq < 150) {
      _adicionarFilaVoz("Aproximando esquerda.", ehAltaPrioridade: true);
    }
    if ((mediaAntigaDir - mediaRecenteDir > 30) && mediaRecenteDir < 150) {
      _adicionarFilaVoz("Aproximando direita.", ehAltaPrioridade: true);
    }
    if ((mediaAntigaFrente - mediaRecenteFrente > 40) && mediaRecenteFrente < 180) {
      _adicionarFilaVoz("Aproximando frente.", ehAltaPrioridade: true);
    }

    // 3. DETECÇÃO DE AMBIENTE - Prioridade Normal

    // Aberturas (Portas): Estava perto (<80) e ficou longe (>150)
    if (mediaAntigaEsq < 80 && mediaRecenteEsq > 150) {
      _adicionarFilaVoz("Abertura Esquerda.");
    }
    else if (mediaAntigaDir < 80 && mediaRecenteDir > 150) {
      _adicionarFilaVoz("Abertura Direita.");
    }
    // Corredor: Apertado nos dois lados, livre na frente
    else if (mediaRecenteEsq < 110 && mediaRecenteDir < 110 && mediaRecenteFrente > 150) {
      _adicionarFilaVoz("Corredor detectado.");
    }
  }

  // --- PROCESSAMENTO PRINCIPAL ---
  void _processarSensor(String valorRaw, Function(String) updateUI, List<double> bufferHistorico) {
    try {
      double distanciaBruta = double.parse(valorRaw);

      // 1. Guarda Bruto na memória
      _adicionarAoHistorico(bufferHistorico, distanciaBruta);

      // 2. Calcula Média para estabilidade
      double media = _calcularMedia(bufferHistorico);

      // 3. Atualiza a Tela com a MÉDIA (e não o valor bruto que pisca)
      if (mounted) updateUI(media.toStringAsFixed(0));

      // 4. Analisa perigos usando a Média
      _analisarPadroes();

    } catch (e) { }
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
      // Conexão padrão sem parâmetros extras
      await device.connect(autoConnect: false,license: License.free);
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

          if (uuid == charUuidS1) { // S1 = Frente
            _subS1 = c.lastValueStream.listen((val) {
              _processarSensor(String.fromCharCodes(val), (v) => setState(() => txtFrente = v), histFrente);
            });
          } else if (uuid == charUuidS2) { // S2 = Esquerda
            _subS2 = c.lastValueStream.listen((val) {
              _processarSensor(String.fromCharCodes(val), (v) => setState(() => txtEsq = v), histEsq);
            });
          } else if (uuid == charUuidS3) { // S3 = Direita
            _subS3 = c.lastValueStream.listen((val) {
              _processarSensor(String.fromCharCodes(val), (v) => setState(() => txtDir = v), histDir);
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
  // --- INTERFACE GRÁFICA (UI) ---
  // =================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Sem GoogleFonts para não travar offline
        title: const Text("Assistente Visual", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24)),
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

          // Cards dos Sensores
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

          // Botão de Ação
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
    // Tratamento visual para "infinito"
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
                    fontFamily: 'Monospace' // Fonte monoespaçada nativa (segura offline)
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