# Capacete Assistivo: Sistema de Navegação Inteligente
Este projeto consiste em um protótipo de Tecnologia Assistiva (TA) desenvolvido para proporcionar maior autonomia e segurança à mobilidade de pessoas com deficiência visual. O sistema atua como um dispositivo sensorial expandido, traduzindo informações espaciais em feedback sonoro contextualizado.

## Funcionalidades do Sistema
O diferencial deste projeto é o tratamento inteligente dos dados brutos, evitando alarmes falsos comuns em sensores ultrassônicos.

- Monitoramento Multidirecional: Cobertura simultânea de obstáculos à Frente, Esquerda e Direita.

- Tratamento de Dados (Sliding Window): Utiliza buffers de memória (Queue) para suavizar leituras, calculando médias móveis e ignorando ruídos momentâneos.

- Trava de Segurança Postural (Interlock):

- Integração com Acelerômetro para monitorar a inclinação da cabeça.

- Pausa Inteligente: Se o usuário olhar para o chão (>30°), o sistema pausa os alertas frontais para não confundir o solo com um obstáculo.

- Histerese: Sistema de margem de segurança (trava em 30°, destrava em 20°) para evitar oscilações de leitura.

- Feedback de Voz Gerenciado:

  - Sistema de Filas de Prioridade (Alertas de "PARE" interrompem avisos informativos).

  - Controle de repetição para evitar que o sistema se torne repetitivo e cansativo.

- Detecção de Cenários:

  - Diferenciação entre obstáculos estáticos e "fechadas" laterais.

  - Identificação de aberturas (corredores) baseada na variação histórica da distância.

## Arquitetura de Software (App)
O aplicativo serve como interface de processamento e feedback, desenvolvido em Flutter (Dart).

- Fluxo de Dados
  - Recepção (BLE): O app recebe strings de dados via Bluetooth Low Energy.

  - Validação: Filtros de "Interlock" verificam se a postura do usuário é válida.

  - Processamento: Os dados válidos entram em filas (Queue) deslizantes de tamanho fixo.

  - Análise Comparativa: O algoritmo compara a Média Antiga (início da fila) com a Média Recente (fim da fila) para determinar tendências de aproximação ou afastamento.

  - Atuação (TTS): O motor de Text-to-Speech vocaliza os alertas com base na prioridade calculada.
