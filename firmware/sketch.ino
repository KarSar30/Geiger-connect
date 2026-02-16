#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_AHTX0.h>   // Temperature/Humidity sensor library
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

/* ==========================================================================
   CONFIG & SENSORS
   ========================================================================== */
Adafruit_AHTX0 aht; // Used for data simulation during the prototype phase

/* ==========================================================================
   BLE SETTINGS
   Note: Do not change UUIDs or Device Name if you are using the pre-built app.
   ========================================================================== */
#define SERVICE_UUID        "12345678-1234-1234-1234-1234567890ab"
#define TEMP_CHAR_UUID      "abcd0001-1234-1234-1234-1234567890ab"

BLECharacteristic *pCharacteristic;
bool deviceConnected = false;
unsigned long lastNotify = 0;

/* ==========================================================================
   BLE CALLBACKS
   ========================================================================== */
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println(">>> Smartphone connected!");
  }

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println(">>> Smartphone disconnected!");
    // Restart advertising so the phone can find it again
    pServer->getAdvertising()->start();
  }
};

void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22); // Default I2C pins for ESP32

  // Initialize sensor for simulation
  if (!aht.begin()) {
    Serial.println("AHT10/20 sensor not found! Simulation will fail.");
  }

  // Initialize BLE with the name expected by the Flutter app
  BLEDevice::init("ESP32-Temp"); 
  
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
      TEMP_CHAR_UUID,
      BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );

  pCharacteristic->addDescriptor(new BLE2902());
  pService->start();

  // Start broadcasting
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  Serial.println("GeigerConnect: Waiting for a client connection...");
}

void loop() {
  // Update and send data every 1 second
  if (millis() - lastNotify > 1000) {
    lastNotify = millis();

    /* ======================================================================
       DATA ACQUISITION (SIMULATION)
       Replace this block with your Geiger counter pulse counting logic.
       ====================================================================== */
    sensors_event_t humidity, temp;
    aht.getEvent(&humidity, &temp);

    // Using temperature to simulate radiation levels (uSv/h or CPM)
    float currentData = temp.temperature; 
    
    Serial.print("Current Data (Simulated): ");
    Serial.println(currentData);

    // Send data to the App if connected
    if (deviceConnected) {
      pCharacteristic->setValue((uint8_t*)&currentData, sizeof(currentData));
      pCharacteristic->notify();
    }
  }
}
