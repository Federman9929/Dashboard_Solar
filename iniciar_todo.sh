#!/usr/bin/env zsh
# ==============================================================================
# INICIADOR COMPLETO DESDE CERO: MONITOR SOLAR FAMILIAR
# ==============================================================================
set -e

ROOT_DIR="/Users/federico/Documents/Federico2026/Panel_Solar"
BACKEND_DIR="$ROOT_DIR/backend"
APP_DIR="$ROOT_DIR/solar_family_app"
FLUTTER_BIN="/Users/federico/flutter/bin/flutter"
ADB_BIN="/opt/homebrew/bin/adb"
EMULATOR_BIN="/Users/federico/Library/Android/sdk/emulator/emulator"
MOSQUITTO_BIN="/opt/homebrew/sbin/mosquitto"

echo "=================================================================="
echo "☀️  PASO 1: Iniciando Broker MQTT Local (Mosquitto en puerto 1883)"
echo "=================================================================="
if ! pgrep -x "mosquitto" > /dev/null; then
    "$MOSQUITTO_BIN" -c "$BACKEND_DIR/mosquitto/mosquitto_solar.conf" -d
    echo "✅ Broker Mosquitto iniciado en segundo plano."
else
    echo "✅ Broker Mosquitto ya estaba corriendo."
fi

echo ""
echo "=================================================================="
echo "🔋 PASO 2: Iniciando Servidor Solar Python (SmartESS -> MQTT)"
echo "=================================================================="
pkill -f "solar_monitor.py" 2>/dev/null || true
if [ -x "$BACKEND_DIR/venv/bin/python3" ]; then
    PYTHON_BIN="$BACKEND_DIR/venv/bin/python3"
else
    PYTHON_BIN="/usr/bin/python3"
fi
nohup "$PYTHON_BIN" "$BACKEND_DIR/solar_monitor.py" > "$BACKEND_DIR/logs/solar_monitor_live.log" 2>&1 &
echo "✅ Servicio Python iniciado (conectado a tu planta Casa_Falla)."

echo ""
echo "=================================================================="
echo "📱 PASO 3: Iniciando Emulador Android (Pixel_7)"
echo "=================================================================="
if ! "$ADB_BIN" devices | grep -q "emulator-"; then
    echo "⏳ Encendiendo emulador Pixel_7..."
    nohup "$EMULATOR_BIN" -avd Pixel_7 -netdelay none -netspeed full > /dev/null 2>&1 &
    echo "⏳ Esperando a que Android termine de arrancar..."
    "$ADB_BIN" wait-for-device
    while [ -z "$("$ADB_BIN" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" ]; do
        sleep 2
    done
    echo "✅ Emulador Pixel_7 listo."
else
    echo "✅ Emulador Android ya está encendido."
fi

# Conectar el puerto 1883 del emulador directamente al puerto 1883 de la MacBook
"$ADB_BIN" reverse tcp:1883 tcp:1883 || true

echo ""
echo "=================================================================="
echo "🚀 PASO 4: Instalando y abriendo la App en el Emulador"
echo "=================================================================="
cd "$APP_DIR"
"$FLUTTER_BIN" run -d emulator-5554
