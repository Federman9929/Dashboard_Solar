/**
 * Firmware Opcional para Puente ESP32 (RS485/Modbus -> TCP Wi-Fi Local)
 * =====================================================================
 * Si el inversor solar está lejos de la MacBook, puedes conectar un ESP32
 * económico ($4 USD) con un módulo MAX485 al puerto RS485 del inversor.
 * El script de Python en la Mac (`CONNECTION_MODE=ESP32_TCP`) se conectará
 * a este ESP32 por Wi-Fi local en el puerto 8888 cada 1-2 segundos.
 */

#include <WiFi.h>

const char* WIFI_SSID = "TU_RED_WIFI_HOGAR";
const char* WIFI_PASS = "TU_CLAVE_WIFI";
const uint16_t SERVER_PORT = 8888;

// Pines UART2 para conversor RS485 (MAX485)
#define RS485_RX_PIN 16
#define RS485_TX_PIN 17

WiFiServer server(SERVER_PORT);

void setup() {
  Serial.begin(115200);
  Serial2.begin(9600, SERIAL_8N1, RS485_RX_PIN, RS485_TX_PIN);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
  }
  Serial.print("ESP32 Puente Solar activo en IP: ");
  Serial.println(WiFi.localIP());
  server.begin();
}

void loop() {
  WiFiClient client = server.available();
  if (!client) return;

  while (client.connected()) {
    if (client.available()) {
      String cmd = client.readStringUntil('\n');
      cmd.trim();
      if (cmd == "GET_TELEMETRY") {
        // Aquí puedes leer los registros de Serial2 (RS485) o sensores ADC/INA226
        // y responder con el JSON limpio que espera el backend en Python:
        String jsonResponse = "{"
          "\"battery_voltage\": 51.8,"
          "\"battery_soc\": 82.5,"
          "\"pv_power_w\": 1450.0,"
          "\"battery_charge_w\": 920.0,"
          "\"battery_discharge_w\": 0.0,"
          "\"load_power_w\": 530.0"
        "}\n";
        client.print(jsonResponse);
      }
    }
  }
  client.stop();
}
