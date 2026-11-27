#!/usr/bin/env zsh
# ==============================================================================
# DOBLE CLIC EN FINDER PARA ENCENDER / REINICIAR EL SERVIDOR SOLAR
# ==============================================================================
ROOT_DIR="/Users/federico/Documents/Federico2026/Panel_Solar"
cd "$ROOT_DIR" || exit 1

clear
echo "=========================================="
echo "   ☀️  MONITOR SOLAR FAMILIAR - SERVIDOR"
echo "=========================================="
echo ""

"$ROOT_DIR/iniciar_servidor.sh"
sleep 3

MAC_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "No detectada")
echo ""
echo "📡 IP local actual de esta Mac: $MAC_IP (Puerto 1883)"
echo "📊 Últimas líneas del registro:"
tail -n 5 "$ROOT_DIR/backend/logs/solar_monitor.log"
echo ""
echo "✅ Ya puedes cerrar esta ventana (el servidor sigue corriendo en 2.º plano)."
read -k 1 "?Presiona cualquier tecla para cerrar..."
echo ""
