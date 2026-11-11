#!/usr/bin/env zsh
# ==============================================================================
# DETENER SERVIDOR SOLAR (Python + Mosquitto MQTT)
# ==============================================================================
echo "🛑 Deteniendo servicio Python (solar_monitor.py)..."
pkill -f "solar_monitor.py" 2>/dev/null && echo "✅ Servicio Python detenido." || echo "ℹ️ El servicio Python no estaba corriendo."

echo "🛑 Deteniendo broker Mosquitto MQTT..."
pkill -x "mosquitto" 2>/dev/null && echo "✅ Broker Mosquitto detenido." || echo "ℹ️ El broker Mosquitto no estaba corriendo."

echo "🏁 Todos los servicios del monitor solar han sido detenidos."
