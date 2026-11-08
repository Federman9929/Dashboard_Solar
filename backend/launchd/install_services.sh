#!/usr/bin/env zsh
# ==============================================================================
# Instalador Automático de Servicios en Segundo Plano (LaunchAgents macOS)
# ==============================================================================
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$PROJECT_DIR/logs"

echo "☀️  Configurando Backend Solar Local en: $PROJECT_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"

# 1. Crear entorno virtual de Python si no existe
if [ ! -d "$PROJECT_DIR/venv" ]; then
    echo "📦 Creando entorno virtual de Python (venv)..."
    python3 -m venv "$PROJECT_DIR/venv"
fi

echo "📥 Instalando dependencias de Python..."
"$PROJECT_DIR/venv/bin/pip" install --upgrade pip
"$PROJECT_DIR/venv/bin/pip" install -r "$PROJECT_DIR/requirements.txt"

# 2. Crear archivo .env a partir de .env.example si no existe
if [ ! -f "$PROJECT_DIR/.env" ]; then
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    echo "✅ Archivo .env creado con valores por defecto (modo SIMULATOR inicial)."
fi

# 3. Detectar ruta real de mosquitto (Apple Silicon /opt/homebrew vs Intel /usr/local)
MOSQUITTO_BIN="$(which mosquitto || echo '/opt/homebrew/sbin/mosquitto')"
echo "🔍 Binario de Mosquitto detectado en: $MOSQUITTO_BIN"

# 4. Ajustar rutas dinámicamente en los archivos .plist y copiarlos a ~/Library/LaunchAgents
sed -e "s|/Users/federico/Documents/Federico2026/Panel_Solar/backend|$PROJECT_DIR|g" \
    -e "s|/opt/homebrew/sbin/mosquitto|$MOSQUITTO_BIN|g" \
    "$PROJECT_DIR/launchd/com.hogar.mosquitto.plist" > "$LAUNCH_AGENTS_DIR/com.hogar.mosquitto.plist"

sed -e "s|/Users/federico/Documents/Federico2026/Panel_Solar/backend|$PROJECT_DIR|g" \
    "$PROJECT_DIR/launchd/com.hogar.solarmonitor.plist" > "$LAUNCH_AGENTS_DIR/com.hogar.solarmonitor.plist"

# 5. Recargar servicios en launchctl
echo "🚀 Registrando e iniciando LaunchAgents en macOS..."
launchctl unload "$LAUNCH_AGENTS_DIR/com.hogar.mosquitto.plist" 2>/dev/null || true
launchctl unload "$LAUNCH_AGENTS_DIR/com.hogar.solarmonitor.plist" 2>/dev/null || true

launchctl load -w "$LAUNCH_AGENTS_DIR/com.hogar.mosquitto.plist"
launchctl load -w "$LAUNCH_AGENTS_DIR/com.hogar.solarmonitor.plist"

echo "✅ ¡Listo! Mosquitto y el Monitor Solar Python están corriendo en segundo plano."
echo "📄 Puedes ver los logs en vivo ejecutando:"
echo "   tail -f $LOG_DIR/solar_monitor.log"
