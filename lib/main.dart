import 'dart:async';
import 'dart:collection';
import 'dart:math';
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
        scaffoldBackgroundColor: const Color(0xFF000000),
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
  // --- CONFIGURAÇÃO BLUETOOTH (UUIDs do ESP32) ---
  final String targetDeviceName = "ESP32_Capacete";
  final String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";

  final String charUuidS1 = "beb5483e-36e1-4688-b7f5-ea07361b26a8"; // FRENTE
  final String charUuidS2 = "1c95d5e5-0466-4aa8-b8d9-e31d0ebf8453"; // ESQUERDA
  final String charUuidS3 = "aa2b5a6c-486a-4b68-b118-a61f5c6b6d3b"; // DIREITA
  
  // --- UUID do Acelerômetro ---
  final String charUuidAccel = "e9eaadd6-25f8-470c-b59e-4a608fced746"; 

  // --- VARIÁVEIS DE CONTROLE ---
  BluetoothDevice? _device;
  StreamSubscription? _scanSub;
  StreamSubscription? _subS1, _subS2, _subS3, _subAccel; 

  bool _isConnected = false;
  bool _isScanning = false;
  String _status = "Toque em CONECTAR";

  // --- CONTROLE DE POSTURA ---
  bool _sistemaPausadoPorPostura = false;
  double _anguloVerticalCabeca = 0.0;     

  // Valores de Tela
  String txtFrente = "--";
  String txtEsq = "--";
  String txtDir = "--";

  // --- BUFFER DE MEMÓRIA ---
  final int tamanhoBuffer = 10;
  Queue<double> histFrente = Queue<double>(); 
  Queue<double> histEsq = Queue<double>();
  Queue<double> histDir = Queue<double>();

  // --- SISTEMA DE ÁUDIO ---
  final FlutterTts flutterTts = FlutterTts();
  final Queue<String> _filaAltaPrioridade = Queue<String>();
  final Queue<String> _filaNormalPrioridade = Queue<String>();

  bool _processandoAudio = false;
  bool _falandoAlgoDeAltaPrioridade = false;

  // Filtro de SPAM
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
    _subS1?.cancel(); _subS2?.cancel(); _subS3?.cancel(); _subAccel?.cancel();
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
    // Se for msg repetida em curto prazo, ignora
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
      // Mensagens normais só entram se o sistema NÃO estiver pausado pela postura
      if (!_sistemaPausadoPorPostura) {
        if (!_filaNormalPrioridade.contains(mensagem) && !_filaAltaPrioridade.contains(mensagem)) {
          _filaNormalPrioridade.add(mensagem);
        }
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

  double _calcularMedia(Queue<double> fila) {
    if (fila.isEmpty) return 0.0;
    double soma = fila.reduce((a, b) => a + b);
    return soma / fila.length;
  }

  void _adicionarAoHistorico(Queue<double> fila, double valor) {
    if (valor < 2 || valor > 400) return;
    fila.add(valor);
    if (fila.length > tamanhoBuffer) fila.removeFirst();
  }

  // =================================================================
  // --- LÓGICA DO ACELERÔMETRO (NOVO) ---
  // =================================================================

  void _receberDadosAcelerometro(String valorRaw) {
    try {
      // Espera receber string formato: "x,y,z" (ex: "0.20,-0.10,9.80")
      List<String> partes = valorRaw.split(',');
      if (partes.length < 3) return;

      double ax = double.parse(partes[0]);
      double ay = double.parse(partes[1]);
      double az = double.parse(partes[2]);

      // Cálculo do Pitch (Inclinação)
      // Ajuste ax, ay, az na fórmula dependendo da montagem física do sensor
      double pitchRad = atan(ax / sqrt(pow(ay, 2) + pow(az, 2)));
      double pitchGraus = pitchRad * (180 / pi);

      // Suavização (Média Ponderada) para evitar oscilação
      _anguloVerticalCabeca = (_anguloVerticalCabeca * 0.8) + (pitchGraus * 0.2);

      // Lógica de Histerese (Zona Morta)
      // Pausa se inclinar mais que 30 graus (olhando pro chão)
      if (!_sistemaPausadoPorPostura && _anguloVerticalCabeca.abs() > 30) {
        setState(() {
          _sistemaPausadoPorPostura = true;
          // Limpa buffers para evitar dados velhos quando voltar
          histFrente.clear(); histEsq.clear(); histDir.clear();
          txtFrente = "--"; txtEsq = "--"; txtDir = "--";
        });
        _adicionarFilaVoz("Por favor, olhe para frente.", ehAltaPrioridade: true);
      }
      // Retoma se voltar para menos de 20 graus
      else if (_sistemaPausadoPorPostura && _anguloVerticalCabeca.abs() < 20) {
        setState(() {
          _sistemaPausadoPorPostura = false;
        });
        _adicionarFilaVoz("Leitura retomada.");
      }

    } catch (e) {
      // Erro de parse ignorado
    }
  }

  // =================================================================
  // --- LÓGICA DOS SENSORES ---
  // =================================================================

  void _analisarFrente(Queue<double> buffer) {

    if (buffer.length < tamanhoBuffer) return;
    if (_sistemaPausadoPorPostura) return;
    
    double mediaRecente = _calcularMedia(Queue.from(buffer.skip(buffer.length - 5)));

    if (mediaRecente < 50) {
      _adicionarFilaVoz("Pare! Frente.", ehAltaPrioridade: true);
      return;
    }

  }

 void _analisarLateral(Queue<double> buffer, String lado) {
    if (buffer.length < tamanhoBuffer) return;
    
    if (_sistemaPausadoPorPostura) return;

    double mediaAntiga = _calcularMedia(Queue.from(buffer.take(5)));
    double mediaRecente = _calcularMedia(Queue.from(buffer.skip(buffer.length - 5)));

    if ((mediaAntiga - mediaRecente) > 30 && mediaRecente < 60) {
      _adicionarFilaVoz("Cuidado $lado.", ehAltaPrioridade: true);
      return;
    }

    if (mediaAntiga < 80 && mediaRecente > 150) {
      _adicionarFilaVoz("Abertura à $lado.");
    }
  }

  // =================================================================
  // --- RECEBEDORES DE DADOS (CALLBACKS) ---
  // =================================================================

  void _receberDadosFrente(String valorRaw) {
    if (_sistemaPausadoPorPostura) return;

    try {
      double? valor = double.tryParse(valorRaw);
      if (valor == null) return;

      _adicionarAoHistorico(histFrente, valor);
      double media = _calcularMedia(histFrente);

      if (mounted) setState(() => txtFrente = media.toStringAsFixed(0));
      _analisarFrente(histFrente);
    } catch (e) { }
  }

  void _receberDadosEsquerda(String valorRaw) {
    if (_sistemaPausadoPorPostura) return;

    try {
      double? valor = double.tryParse(valorRaw);
      if (valor == null) return;

      _adicionarAoHistorico(histEsq, valor);
      double media = _calcularMedia(histEsq);

      if (mounted) setState(() => txtEsq = media.toStringAsFixed(0));
      _analisarLateral(histEsq, "esquerda");
    } catch (e) {}
  }

  void _receberDadosDireita(String valorRaw) {
    if (_sistemaPausadoPorPostura) return;

    try {
      double? valor = double.tryParse(valorRaw);
      if (valor == null) return;

      _adicionarAoHistorico(histDir, valor);
      double media = _calcularMedia(histDir);

      if (mounted) setState(() => txtDir = media.toStringAsFixed(0));
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

          if (uuid == charUuidS1) { // FRENTE
            _subS1 = c.lastValueStream.listen((val) => _receberDadosFrente(String.fromCharCodes(val)));
          } else if (uuid == charUuidS2) { // ESQUERDA
            _subS2 = c.lastValueStream.listen((val) => _receberDadosEsquerda(String.fromCharCodes(val)));
          } else if (uuid == charUuidS3) { // DIREITA
            _subS3 = c.lastValueStream.listen((val) => _receberDadosDireita(String.fromCharCodes(val)));
          } 
          else if (uuid == charUuidAccel) {
            _subAccel = c.lastValueStream.listen((val) {
               _receberDadosAcelerometro(String.fromCharCodes(val));
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
  // --- UI ---
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
          // --- BARRA DE STATUS ---
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            // Muda a cor se estiver Pausado por Postura
            color: _sistemaPausadoPorPostura 
                ? Colors.orange[900] // Laranja = Alerta Postura
                : (_isConnected ? Colors.green[900] : Colors.red[900]),
            child: Text(
              _sistemaPausadoPorPostura 
                  ? "POSTURA INCORRETA (PAUSADO)" 
                  : _status.toUpperCase(),
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
                  _buildCard("ESQUERDA", _sistemaPausadoPorPostura ? "--" : txtEsq, Colors.purpleAccent),
                  _buildCard("FRENTE", _sistemaPausadoPorPostura ? "--" : txtFrente, Colors.cyanAccent, isMain: true),
                  _buildCard("DIREITA", _sistemaPausadoPorPostura ? "--" : txtDir, Colors.orangeAccent),
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
    
    // Efeito visual de desabilitado se estiver pausado
    Color finalColor = _sistemaPausadoPorPostura ? Colors.grey : color;
    Color textColor = _sistemaPausadoPorPostura ? Colors.white38 : Colors.white;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: isMain ? 30 : 20, horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: finalColor, width: isMain ? 3 : 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: textColor.withOpacity(0.7), fontSize: 18, fontWeight: FontWeight.bold)),
          Row(
            children: [
              Text(
                display,
                style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                    fontFamily: 'Monospace'
                ),
              ),
              if (display != "> 4m" && display != "--")
                Padding(
                  padding: const EdgeInsets.only(left: 8.0, top: 10),
                  child: Text("cm", style: TextStyle(color: textColor.withOpacity(0.5), fontSize: 16)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}