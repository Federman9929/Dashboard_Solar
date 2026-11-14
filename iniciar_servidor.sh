#!/usr/bin/env zsh
# ==============================================================================
# INICIAR SERVIDOR SOLAR LIGERO (Mosquitto MQTT + Backend Python + Anti-Reposo AC)
# ==============================================================================
ROOT_DIR="/Users/federico/Documents/Federico2026/Panel_Solar"
BACKEND_DIR="$ROOT_DIR/backend"
MOSQUITTO_BIN="/opt/homebrew/sbin/mosquitto"

if ! pgrep -x "mosquitto" > /dev/null; then
    "$MOSQUITTO_BIN" -c "$BACKEND_DIR/mosquitto/mosquitto_solar.conf" -d
    echo "✅ Broker Mosquitto iniciado en puerto 1883."
else
    echo "✅ Broker Mosquitto ya estaba activo."
fi

pkill -f "solar_monitor.py" 2>/dev/null || true
sleep 0.5
nohup caffeinate -s "$BACKEND_DIR/venv/bin/python3" "$BACKEND_DIR/solar_monitor.py" > "$BACKEND_DIR/logs/solar_monitor_live.log" 2>&1 &
echo "✅ Servidor Python (solar_monitor.py) iniciado en segundo plano (anti-reposo con cargador conectado)."
echo "📊 Puedes ver los datos en vivo ejecutando: tail -f $BACKEND_DIR/logs/solar_monitor.log"
