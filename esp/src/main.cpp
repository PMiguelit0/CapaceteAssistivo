#include <Arduino.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ==========================================
// --- CONFIGURAÇÃO DE HARDWARE ---
// ==========================================
#define TRIG_PIN_FRONT 26
#define ECHO_PIN_FRONT 25

#define TRIG_PIN_LEFT 13
#define ECHO_PIN_LEFT 12

#define TRIG_PIN_RIGHT 18
#define ECHO_PIN_RIGHT 19

// Endereço I2C do MPU6050
const int MPU_ADDR = 0x68;

// ==========================================
// --- UUIDs BLE ---
// ==========================================
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_UUID_S1        "beb5483e-36e1-4688-b7f5-ea07361b26a8" // FRENTE
#define CHAR_UUID_S2        "1c95d5e5-0466-4aa8-b8d9-e31d0ebf8453" // ESQUERDA
#define CHAR_UUID_S3        "aa2b5a6c-486a-4b68-b118-a61f5c6b6d3b" // DIREITA
#define CHAR_UUID_GYRO      "e9eaadd6-25f8-470c-b59e-4a608fced746" // AGORA É GIROSCÓPIO

// Objetos Globais BLE
BLECharacteristic *pCharFrente;
BLECharacteristic *pCharEsq;
BLECharacteristic *pCharDir;
BLECharacteristic *pCharGyro;

bool deviceConnected = false;
portMUX_TYPE timerMux = portMUX_INITIALIZER_UNLOCKED;

// ==========================================
// --- CALLBACKS BLE ---
// ==========================================
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
    };
    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      BLEDevice::startAdvertising();
    }
};

// ==========================================
// --- LEITURA ULTRASSOM (COM PROTEÇÃO) ---
// ==========================================
int lerDistancia(int trig, int echo) {
  unsigned long duration = 0;

  portENTER_CRITICAL(&timerMux);
  digitalWrite(trig, LOW);
  delayMicroseconds(2);
  digitalWrite(trig, HIGH);
  delayMicroseconds(10);
  digitalWrite(trig, LOW);
  duration = pulseIn(echo, HIGH, 25000); // Timeout 25ms
  portEXIT_CRITICAL(&timerMux);
  
  if (duration == 0) return 400; 
  return (int)(duration * 0.034 / 2);
}

// ==========================================
// --- TAREFAS (PARALELISMO) ---
// ==========================================

// TAREFA 1: Lê os 3 Sensores Ultrassônicos e envia via BLE
void taskUltrassom(void * parameter) {
  char txString[10];
  for (;;) {
    if (deviceConnected) {
      // Frente
      int dFront = lerDistancia(TRIG_PIN_FRONT, ECHO_PIN_FRONT);
      itoa(dFront, txString, 10);
      pCharFrente->setValue(txString);
      pCharFrente->notify();
      vTaskDelay(15 / portTICK_PERIOD_MS);

      // Esquerda
      int dLeft = lerDistancia(TRIG_PIN_LEFT, ECHO_PIN_LEFT);
      itoa(dLeft, txString, 10);
      pCharEsq->setValue(txString);
      pCharEsq->notify();
      vTaskDelay(15 / portTICK_PERIOD_MS);

      // Direita
      int dRight = lerDistancia(TRIG_PIN_RIGHT, ECHO_PIN_RIGHT);
      itoa(dRight, txString, 10);
      pCharDir->setValue(txString);
      pCharDir->notify();
    }
    // Delay geral dos ultrassons
    vTaskDelay(100 / portTICK_PERIOD_MS); 
  }
}

// TAREFA 2: Lê o MPU6050 (Wire Puro) e envia via BLE + Serial Plotter
void taskMPU(void * parameter) {
  char txString[32]; 

  for (;;) {
    // 1. Solicita dados do MPU via I2C
    Wire.beginTransmission(MPU_ADDR);
    Wire.write(0x43); // 0x43 = Começo dos registros do GIROSCÓPIO
    Wire.endTransmission(false);
    Wire.requestFrom(MPU_ADDR, 6, true); // Pede 6 bytes (X, Y, Z)

    if (Wire.available() >= 6) {
      // Lê os bytes high/low
      int16_t raw_gx = Wire.read() << 8 | Wire.read();
      int16_t raw_gy = Wire.read() << 8 | Wire.read();
      int16_t raw_gz = Wire.read() << 8 | Wire.read();

      // Converte para Graus por Segundo (escala padrão)
      float gx = raw_gx / 131.0;
      float gy = raw_gy / 131.0;
      float gz = raw_gz / 131.0;

      // A. DEBUG NO SERIAL (Formato Plotter)
      // "Nome:Valor" cria gráficos automáticos na IDE Arduino
      Serial.print(">GiroX:"); Serial.print(gx); Serial.print(","); 
      Serial.print("GiroY:"); Serial.print(gy); Serial.print(",");
      Serial.print("GiroZ:"); Serial.println(gz); 

      // B. ENVIA VIA BLUETOOTH (Formato CSV para o App)
      if (deviceConnected) {
        // Cria string "gx,gy,gz" (ex: "12.50,-4.10,0.05")
        sprintf(txString, "%.2f,%.2f,%.2f", gx, gy, gz);
        pCharGyro->setValue(txString);
        pCharGyro->notify();
      }
    }
    
    // Delay de 50ms (20 leituras por segundo)
    vTaskDelay(50 / portTICK_PERIOD_MS);
  }
}

// ==========================================
// --- SETUP ---
// ==========================================
void setup() {
  Serial.begin(115200);

  // 1. Configura Pinos Ultrassom
  pinMode(TRIG_PIN_FRONT, OUTPUT); pinMode(ECHO_PIN_FRONT, INPUT_PULLDOWN);
  pinMode(TRIG_PIN_LEFT, OUTPUT); pinMode(ECHO_PIN_LEFT, INPUT_PULLDOWN);
  pinMode(TRIG_PIN_RIGHT, OUTPUT); pinMode(ECHO_PIN_RIGHT, INPUT_PULLDOWN);

  // 2. Configura MPU6050 (Wire Manual)
  Wire.begin(21, 22); // SDA=21, SCL=22
  // Acorda o MPU (tira do modo sleep)
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B); // Registro PWR_MGMT_1
  Wire.write(0);    // Escreve 0 para acordar
  Wire.endTransmission();
  Serial.println("MPU6050 Acordado (Modo Wire)!");

  // 3. Configura BLE
  BLEDevice::init("ESP32_Capacete");
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCharFrente = pService->createCharacteristic(CHAR_UUID_S1, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pCharFrente->addDescriptor(new BLE2902());

  pCharEsq = pService->createCharacteristic(CHAR_UUID_S2, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pCharEsq->addDescriptor(new BLE2902());

  pCharDir = pService->createCharacteristic(CHAR_UUID_S3, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pCharDir->addDescriptor(new BLE2902());

  pCharGyro = pService->createCharacteristic(CHAR_UUID_GYRO, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pCharGyro->addDescriptor(new BLE2902());

  pService->start();
  BLEDevice::getAdvertising()->addServiceUUID(SERVICE_UUID);
  BLEDevice::startAdvertising();
  Serial.println("Bluetooth Pronto!");

  // 4. Inicia Tarefas Paralelas
  xTaskCreatePinnedToCore(taskUltrassom, "TaskUS", 4096, NULL, 1, NULL, 1);
  xTaskCreatePinnedToCore(taskMPU,       "TaskMPU", 4096, NULL, 1, NULL, 1);
}

void loop() {
  vTaskDelay(portMAX_DELAY); 
}