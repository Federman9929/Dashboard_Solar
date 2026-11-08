# ☀️ Sistema de Monitoreo Solar Local 100% Gratuito (MacBook + MQTT + Flutter)

Arquitectura completa de telemetría solar doméstica en tiempo real (1 a 2 segundos de latencia), diseñada para ejecutarse **sin servidores en la nube ni costos de suscripción**, utilizando tu **MacBook como servidor local** (`Mosquitto MQTT` + `Python` + `SQLite`) y una **Aplicación Móvil Multiplataforma en Flutter** para toda la familia.

---

## 🏗️ Arquitectura y Estructura del Proyecto

```text
Panel_Solar/
├── README.md                                   # Guía paso a paso de despliegue 100% gratuito
├── backend/                                    # Servidor Local en MacBook (Python + Mosquitto)
│   ├── .env.example                            # Plantilla de configuración (Modbus, ESP32, Telegram, CallMeBot)
│   ├── requirements.txt                        # Dependencias Python (paho-mqtt, pymodbus, pyserial, requests)
│   ├── solar_monitor.py                        # Demonio principal: lectura 1.5s, SQLite 24h, MQTT y Alertas <30%
│   ├── esp32_bridge/
│   │   └── esp32_solar_bridge.ino              # Firmware opcional si usas un ESP32 como puente Wi-Fi a RS485
│   ├── mosquitto/
│   │   └── mosquitto_solar.conf                # Configuración de Mosquitto para red local (LAN 0.0.0.0:1883)
│   └── launchd/                                # Auto-arranque en segundo plano al encender la Mac
│       ├── com.hogar.mosquitto.plist           # LaunchAgent para el broker Mosquitto
│       ├── com.hogar.solarmonitor.plist        # LaunchAgent para el lector solar en Python
│       └── install_services.sh                 # Script instalador automático de servicios en macOS
└── solar_family_app/                           # Aplicación Móvil Multiplataforma en Flutter (MVVM)
    ├── pubspec.yaml                            # Dependencias (mqtt_client, fl_chart, local_notifications, ringtone)
    ├── android/app/src/main/AndroidManifest.xml# Permisos de Notificación Permanente y Alarma FullScreen
    └── lib/
        ├── main.dart                           # Punto de entrada e inyección de dependencias
        ├── domain/
        │   └── models/
        │       └── solar_reading.dart          # Modelo inmutable de lectura solar y lógica de semáforo (🟢/🔴)
        ├── data/
        │   ├── services/
        │   │   ├── mqtt_solar_service.dart     # Cliente MQTT resiliente con Watchdog y reconexión instantánea
        │   │   └── notification_alert_service.dart # Notificación fija en barra de estado y sirena tipo llamada
        │   └── repositories/
        │       └── solar_repository.dart       # Caché de 24h, streams en tiempo real y orquestación de alertas
        └── ui/
            └── features/
                └── dashboard/
                    ├── view_models/
                    │   └── solar_dashboard_view_model.dart
                    └── views/
                        ├── solar_dashboard_screen.dart
                        └── widgets/
                            └── interactive_solar_chart.dart # Gráficas con Pinch-to-Zoom, paneo y tooltip exacto
```

---

## 🚀 Paso 1: Configurar el Servidor Local en la MacBook

### 1.1 Instalar Mosquitto MQTT vía Homebrew
Abre la aplicación **Terminal** en tu MacBook y ejecuta:

```bash
brew install mosquitto python
```

> **Nota importante:** No inicies el servicio por defecto de Homebrew (`brew services start mosquitto`), ya que por defecto solo escucha en `localhost` y no permitiría que los celulares de la familia se conecten. Nuestro script instalará el archivo `mosquitto_solar.conf` optimizado para escuchar en toda tu red Wi-Fi (`0.0.0.0:1883`).

### 1.2 Conocer la IP Local de tu MacBook
Ejecuta este comando en la Terminal para saber la IP local de tu Mac (por ejemplo `192.168.1.100`):

```bash
ipconfig getifaddr en0
```
*(Te recomendamos reservar esta IP como fija/estática en la página de configuración de tu router Wi-Fi doméstico).*

### 1.3 Configurar la conexión con el Inversor y Alertas (`.env`)
Copia el archivo de configuración de ejemplo:

```bash
cd /Users/federico/Documents/Federico2026/Panel_Solar/backend
cp .env.example .env
```

Edita el archivo `.env` según cómo esté conectado tu inversor solar:
- **`CONNECTION_MODE=SIMULATOR`**: *(Valor por defecto)* Genera curvas solares y descargas realistas para probar todo el sistema y la app móvil inmediatamente sin conectar cables.
- **`CONNECTION_MODE=MODBUS_RTU`**: Lee el inversor por cable USB-RS485/Serial conectado a la Mac. Ajusta `SERIAL_PORT=/dev/tty.usbserial-XXXX` y `SERIAL_BAUDRATE=9600`.
- **`CONNECTION_MODE=ESP32_TCP`**: Si el inversor está lejos de la Mac, carga el firmware `backend/esp32_bridge/esp32_solar_bridge.ino` en un ESP32 y define `ESP32_HOST=192.168.1.50`.

### 1.4 Activar el Inicio Automático al Encender la Mac (`LaunchAgents`)
Ejecuta el instalador incluido. Este script creará el entorno virtual `venv`, instalará las librerías de Python, ajustará las rutas en los archivos `.plist` y registrará ambos servicios en `~/Library/LaunchAgents`:

```bash
cd /Users/federico/Documents/Federico2026/Panel_Solar/backend/launchd
./install_services.sh
```

Para verificar que están corriendo en tiempo real:
```bash
launchctl list | grep com.hogar
tail -f /Users/federico/Documents/Federico2026/Panel_Solar/backend/logs/solar_monitor.log
```

---

## 📞 Paso 2: Configurar las Alertas Críticas Gratuitas (< 30% Batería)

El sistema incluye **3 capas de alerta simultáneas y 100% gratuitas** cuando el nivel de batería baja del `30%`:

1. **Sirena Tipo Llamada Entrante en la App Móvil (`flutter_ringtone_player` + `fullScreenIntent`)**:
   - En cuanto el broker MQTT reporta `< 30%`, todos los celulares de la familia conectados al Wi-Fi hacen sonar el timbre de alarma/llamada en bucle con vibración y pantalla completa hasta que alguien presione **"SILENCIAR"**.
2. **Mensaje Instantáneo al Grupo Familiar en Telegram (Telegram Bot API)**:
   - Habla con `@BotFather` en Telegram y envía `/newbot` para obtener tu `TELEGRAM_BOT_TOKEN` gratis.
   - Crea un grupo con tu familia, agrega el bot y coloca el `TELEGRAM_CHAT_ID` en `backend/.env` (y cambia `TELEGRAM_ENABLED=true`).
3. **Llamada Telefónica Automatizada con Voz Real (CallMeBot API para Telegram)**:
   - Inicia un chat en Telegram con `@CallMeBot_txtbot` o autoriza tu usuario `@tu_usuario` gratuitamente en [callmebot.com](https://www.callmebot.com/blog/free-api-telegram-phone-calls/).
   - En `backend/.env`, activa `CALLMEBOT_ENABLED=true` y coloca `CALLMEBOT_USER=@tu_usuario_telegram`. Cuando la batería baje del 30%, tu celular recibirá una llamada real de voz hablada en español leyendo el porcentaje de batería.

---

## 📱 Paso 3: Compilar e Instalar la App en Flutter (Sin Costos)

### 3.1 Preparar el proyecto Flutter
Si aún no has generado las carpetas nativas base de tu versión local de Flutter SDK, ejecuta desde la carpeta `solar_family_app`:

```bash
cd /Users/federico/Documents/Federico2026/Panel_Solar/solar_family_app
flutter create . --project-name solar_family_monitor --org com.hogar
flutter pub get
```
*(El archivo `AndroidManifest.xml`, `pubspec.yaml` y toda la carpeta `lib/` ya están listos y configurados).*

### 3.2 Distribuir Gratis en Celulares Android de la Familia (Vía APK)
En Android no necesitas pagar cuenta de desarrollador. Compila el instalador `.apk` de producción:

```bash
flutter build apk --release
```
El archivo quedará listo en:
`build/app/outputs/flutter-apk/app-release.apk`
Envíalo por WhatsApp, Telegram o AirDrop a los miembros de la familia e instálalo directamente.

### 3.3 Distribuir Gratis en iPhone / iPad (iOS)
Con tu MacBook y Xcode instalado, puedes instalar la app gratis en los iPhones de la familia usando tu Apple ID personal (perfil gratuito *Personal Team* en Xcode):
1. Conecta el iPhone por cable a la MacBook.
2. Abre `ios/Runner.xcworkspace` en Xcode, ve a **Signing & Capabilities** y selecciona tu cuenta personal en **Team**.
3. Ejecuta:
```bash
flutter run --release
```

---

## 📊 Uso de las Funcionalidades Clave en la App

1. **Conectar a la MacBook**:
   - Toca el ícono de **Engranaje (⚙️)** arriba a la derecha, escribe la IP local de tu MacBook (ej. `192.168.1.100`) y pulsa **Guardar y Conectar**.
   - Si quieres probar las gráficas fuera de casa, activa el interruptor **"Modo Simulador en el Celular"**.
2. **Notificación Permanente en Barra de Estado**:
   - Desliza la barra de notificaciones de tu celular: verás permanentemente el porcentaje de batería (`%`), el estado (`Cargando` / `Descargando`) y el indicador visual circular **🟢 Verde** (cuando carga o está en nivel saludable) o **🔴 Rojo** (cuando descarga o está bajo).
3. **Gráficas Interactivas (Zoom + Toque de Precisión)**:
   - **Pellizca con 2 dedos** sobre cualquiera de las 3 gráficas (o usa los botones `+` / `-`) para hacer zoom de hasta `6.0x` y desliza la barra inferior para recorrer el historial.
   - **Toca cualquier punto de la curva** para ver un cuadro emergente con el valor numérico exacto (`%` o `W`), el voltaje y la **marca de tiempo exacta (`HH:mm:ss` / `dd/MM HH:mm`)**.
4. **Probar Alerta Crítica (< 30%)**:
   - Toca el botón rojo de campana (**`!` Test Alerta**) en la barra superior de la app para simular una caída al `26.4%` y verificar el sonido de llamada entrante, el banner de emergencia y las notificaciones.
