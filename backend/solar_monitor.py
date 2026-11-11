#!/usr/bin/env python3
"""
Servicio Local de Monitoreo Solar (MacBook Backend)
===================================================
Lee datos en tiempo real (cada 1-2 segundos) desde el inversor solar
(vía Modbus RTU Serial, Puente Wi-Fi ESP32 o Simulador), almacena el
historial de 24 horas en SQLite local, publica telemetría en formato JSON
a través de Mosquitto MQTT y dispara alertas críticas (Telegram + Llamada
telefónica vía CallMeBot + Alerta MQTT) cuando la batería baja del 30%.
"""

import json
import logging
import math
import os
import random
import signal
import socket
import sqlite3
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

# Auto-activar el entorno virtual local (venv) si el usuario ejecuta `python3 solar_monitor.py`
# desde una terminal cuyo `python3` global no tiene instalado paho-mqtt.
_BASE_DIR_EARLY = Path(__file__).resolve().parent
_VENV_PYTHON = _BASE_DIR_EARLY / "venv" / "bin" / "python3"
try:
    import paho.mqtt.client as mqtt
    import requests
    from dotenv import load_dotenv
except ModuleNotFoundError:
    if _VENV_PYTHON.exists() and os.environ.get("_SOLAR_VENV_REDIRECTED") != "1":
        os.environ["_SOLAR_VENV_REDIRECTED"] = "1"
        os.execv(str(_VENV_PYTHON), [str(_VENV_PYTHON), *sys.argv])
    raise

# Cargar variables de entorno desde archivo .env si existe
BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

# Configuración de Logging
LOG_DIR = BASE_DIR / "logs"
LOG_DIR.mkdir(exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_DIR / "solar_monitor.log", encoding="utf-8"),
    ],
)
logger = logging.getLogger("SolarMonitor")


@dataclass
class SolarTelemetry:
    """Estructura de datos de telemetría solar en tiempo real."""
    timestamp: str               # ISO-8601 UTC
    epoch_ms: int                # Milisegundos desde epoch para gráficas precisas
    battery_voltage: float       # Voltaje actual del banco de baterías (V)
    battery_soc: float           # Porcentaje estimado de carga SOC (%)
    pv_power_w: float            # Potencia entregada por los paneles solares (W)
    battery_power_w: float       # Potencia neta de batería (+W cargando, -W descargando)
    battery_charge_w: float      # Potencia de carga de la batería (W)
    battery_discharge_w: float   # Potencia de descarga de la batería (W)
    load_power_w: float          # Consumo actual de la casa (W)
    status: str                  # "cargando" | "descargando" | "en_reposo"
    is_critical: bool            # True si battery_soc < CRITICAL_SOC_THRESHOLD
    source_mode: str             # "MODBUS_RTU" | "ESP32_TCP" | "SIMULATOR"


class LocalHistoryDB:
    """Base de datos SQLite ultraligera para conservar las últimas 24 horas de historial."""

    def __init__(self, db_path: Path):
        self.db_path = db_path
        self._init_db()

    def _init_db(self) -> None:
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS telemetry_history (
                    epoch_ms INTEGER PRIMARY KEY,
                    battery_voltage REAL NOT NULL,
                    battery_soc REAL NOT NULL,
                    pv_power_w REAL NOT NULL,
                    battery_power_w REAL NOT NULL,
                    battery_discharge_w REAL NOT NULL,
                    status TEXT NOT NULL
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_epoch_ms ON telemetry_history(epoch_ms)"
            )
            # Pre-poblar con 24h de curva solar realista si la base de datos está recién creada
            cursor = conn.execute("SELECT COUNT(*) FROM telemetry_history")
            count = cursor.fetchone()[0]
            if count == 0:
                logger.info("Inicializando base de datos con curva histórica de las últimas 24h...")
                self._seed_24h_history(conn)

    def _seed_24h_history(self, conn: sqlite3.Connection) -> None:
        now_ms = int(time.time() * 1000)
        start_ms = now_ms - (24 * 3600 * 1000)
        step_ms = 5 * 60 * 1000  # 1 punto cada 5 minutos (288 puntos para 24h)
        rows = []
        soc = 68.0
        for ts_ms in range(start_ms, now_ms, step_ms):
            dt = datetime.fromtimestamp(ts_ms / 1000.0)
            hour_float = dt.hour + dt.minute / 60.0
            # Curva solar diurna entre 6:30 y 18:30
            if 6.5 <= hour_float <= 18.5:
                sun_factor = math.sin(math.pi * (hour_float - 6.5) / 12.0)
                pv_w = round(max(0.0, 2400.0 * (sun_factor ** 1.4) + random.uniform(-60, 60)), 1)
            else:
                pv_w = 0.0

            load_w = round(380.0 + 220.0 * math.sin((hour_float - 19.0) * math.pi / 12.0) ** 2 + random.uniform(-30, 30), 1)
            net_batt_w = round(pv_w - load_w, 1)
            discharge_w = round(abs(net_batt_w) if net_batt_w < 0 else 0.0, 1)

            # Evolución de SOC
            soc_delta = (net_batt_w * (5.0 / 60.0)) / 5000.0 * 100.0  # Banco de ~5kWh
            soc = max(22.0, min(100.0, soc + soc_delta))
            voltage = round(46.0 + (soc / 100.0) * 8.4 + (0.3 if net_batt_w > 50 else -0.2), 2)

            if net_batt_w > 25.0:
                status = "cargando"
            elif net_batt_w < -25.0:
                status = "descargando"
            else:
                status = "en_reposo"

            rows.append((ts_ms, voltage, round(soc, 1), pv_w, net_batt_w, discharge_w, status))

        conn.executemany(
            """
            INSERT OR IGNORE INTO telemetry_history
            (epoch_ms, battery_voltage, battery_soc, pv_power_w, battery_power_w, battery_discharge_w, status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        conn.commit()

    def insert_sample(self, sample: SolarTelemetry) -> None:
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO telemetry_history
                (epoch_ms, battery_voltage, battery_soc, pv_power_w, battery_power_w, battery_discharge_w, status)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    sample.epoch_ms,
                    sample.battery_voltage,
                    sample.battery_soc,
                    sample.pv_power_w,
                    sample.battery_power_w,
                    sample.battery_discharge_w,
                    sample.status,
                ),
            )
            # Limpiar datos de más de 24 horas
            cutoff_ms = sample.epoch_ms - (24 * 3600 * 1000)
            conn.execute("DELETE FROM telemetry_history WHERE epoch_ms < ?", (cutoff_ms,))
            conn.commit()

    def get_last_24h_downsampled(self, max_points: int = 288) -> List[Dict]:
        """Devuelve hasta `max_points` muestras de las últimas 24 horas para gráficas ágiles."""
        cutoff_ms = int(time.time() * 1000) - (24 * 3600 * 1000)
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.execute(
                """
                SELECT epoch_ms, battery_voltage, battery_soc, pv_power_w, battery_power_w, battery_discharge_w, status
                FROM telemetry_history
                WHERE epoch_ms >= ?
                ORDER BY epoch_ms ASC
                """,
                (cutoff_ms,),
            )
            rows = cursor.fetchall()

        if not rows:
            return []

        step = max(1, len(rows) // max_points)
        sampled = rows[::step]
        if rows[-1] != sampled[-1]:
            sampled.append(rows[-1])

        return [
            {
                "epoch_ms": r[0],
                "battery_voltage": r[1],
                "battery_soc": r[2],
                "pv_power_w": r[3],
                "battery_power_w": r[4],
                "battery_discharge_w": r[5],
                "status": r[6],
            }
            for r in sampled
        ]


class CriticalAlertManager:
    """
    Gestiona el envío de alertas críticas gratuitas (mensajes de alta prioridad
    y llamadas automatizadas por Telegram/CallMeBot + tópico MQTT de alarma)
    cuando el nivel de batería baja del 30%.
    """

    def __init__(self, threshold_soc: float, cooldown_sec: int):
        self.threshold_soc = threshold_soc
        self.cooldown_sec = cooldown_sec
        self.last_alert_time = 0.0
        self.telegram_enabled = os.getenv("TELEGRAM_ENABLED", "false").lower() == "true"
        self.telegram_token = os.getenv("TELEGRAM_BOT_TOKEN", "")
        self.telegram_chat_id = os.getenv("TELEGRAM_CHAT_ID", "")
        self.callmebot_enabled = os.getenv("CALLMEBOT_ENABLED", "false").lower() == "true"
        self.callmebot_user = os.getenv("CALLMEBOT_USER", "")

    def check_and_trigger(
        self, telemetry: SolarTelemetry, mqtt_client: mqtt.Client, alert_topic: str
    ) -> None:
        if telemetry.battery_soc >= self.threshold_soc:
            return

        now = time.time()
        if (now - self.last_alert_time) < self.cooldown_sec:
            return

        self.last_alert_time = now
        alert_msg = (
            f"🚨 ALERTA CRÍTICA SOLAR 🚨\n"
            f"Nivel de batería bajo: {telemetry.battery_soc:.1f}% ({telemetry.battery_voltage:.2f}V)\n"
            f"Estado: {telemetry.status.upper()}\n"
            f"Descarga actual: {telemetry.battery_discharge_w:.0f} W\n"
            f"Generación Solar: {telemetry.pv_power_w:.0f} W"
        )
        logger.warning(f"Disparando alerta crítica de batería (< {self.threshold_soc}%): {telemetry.battery_soc}%")

        # 1. Publicar evento en el tópico de alerta MQTT para que todos los celulares en casa
        # disparen la sirena de emergencia tipo llamada entrante inmediatamente
        alert_payload = {
            "timestamp": telemetry.timestamp,
            "epoch_ms": telemetry.epoch_ms,
            "level": "CRITICAL",
            "title": "⚠️ ¡BATERÍA SOLAR CRÍTICA!",
            "message": alert_msg,
            "battery_soc": telemetry.battery_soc,
            "battery_voltage": telemetry.battery_voltage,
            "battery_discharge_w": telemetry.battery_discharge_w,
        }
        mqtt_client.publish(alert_topic, json.dumps(alert_payload), qos=1, retain=False)

        # 2. Enviar mensaje prioritario por Telegram Bot API (si está configurado)
        if self.telegram_enabled and self.telegram_token and self.telegram_chat_id:
            self._send_telegram_message(alert_msg)

        # 3. Realizar llamada telefónica de voz gratuita vía CallMeBot API (si está configurado)
        if self.callmebot_enabled and self.callmebot_user:
            self._trigger_phone_call(telemetry.battery_soc)

    def _send_telegram_message(self, text: str) -> None:
        try:
            url = f"https://api.telegram.org/bot{self.telegram_token}/sendMessage"
            resp = requests.post(
                url,
                json={
                    "chat_id": self.telegram_chat_id,
                    "text": text,
                    "disable_notification": False,
                },
                timeout=5,
            )
            if resp.status_code == 200:
                logger.info("Alerta crítica enviada por Telegram exitosamente.")
            else:
                logger.error(f"Error al enviar Telegram ({resp.status_code}): {resp.text}")
        except Exception as exc:
            logger.error(f"Excepción enviando alerta a Telegram: {exc}")

    def _trigger_phone_call(self, soc: float) -> None:
        try:
            voice_msg = (
                f"Alerta critica del sistema solar de casa. "
                f"La bateria ha descendido al {int(soc)} por ciento. "
                f"Por favor reduzca el consumo electrico."
            )
            url = "http://api.callmebot.com/start.php"
            resp = requests.get(
                url,
                params={
                    "user": self.callmebot_user,
                    "text": voice_msg,
                    "lang": "es-ES-Standard-A",
                    "rpt": 2,
                },
                timeout=8,
            )
            logger.info(f"Llamada de alerta vía CallMeBot disparada (HTTP {resp.status_code}).")
        except Exception as exc:
            logger.error(f"Excepción disparando llamada CallMeBot: {exc}")


class InverterReader:
    """
    Lector universal de inversor solar:
    Soporta lectura real por Modbus RTU (RS485/USB), puente TCP sobre ESP32,
    y modo Simulador físico para validación completa sin hardware.
    """

    def __init__(self, mode: str):
        self.mode = mode.upper()
        self.serial_port = os.getenv("SERIAL_PORT", "/dev/tty.usbserial-1410")
        self.baudrate = int(os.getenv("SERIAL_BAUDRATE", "9600"))
        self.slave_id = int(os.getenv("MODBUS_SLAVE_ID", "1"))
        self.esp32_host = os.getenv("ESP32_HOST", "192.168.1.50")
        self.esp32_port = int(os.getenv("ESP32_PORT", "8888"))
        self.v_min = float(os.getenv("BATTERY_MIN_VOLTAGE", "44.0"))
        self.v_max = float(os.getenv("BATTERY_MAX_VOLTAGE", "56.4"))

        # Estado interno del simulador para transiciones suaves y realistas
        self._sim_soc = 78.5
        self._sim_direction = -1.0  # Descargando o cargando suavemente

    def read_telemetry(self) -> SolarTelemetry:
        if self.mode == "SMARTESS_CLOUD":
            return self._read_smartess_cloud()
        elif self.mode == "MUST_WIFI_PLUG":
            return self._read_must_wifi_plug()
        elif self.mode == "MODBUS_RTU":
            return self._read_modbus_rtu()
        elif self.mode == "ESP32_TCP":
            return self._read_esp32_bridge()
        else:
            return self._read_simulator()

    def _read_smartess_cloud(self) -> SolarTelemetry:
        """
        Lee los datos reales de tu inversor MUST a través de la API oficial de SmartESS Cloud.
        Funciona desde cualquier piso de la casa sin importar a qué red Wi-Fi esté la Mac.
        """
        if not hasattr(self, "_smartess_client"):
            from smartess_cloud import SmartESSCloudClient
            email = os.getenv("SMARTESS_EMAIL", "Federman9915@gmail.com")
            password = os.getenv("SMARTESS_PASSWORD", "Federman99")
            self._smartess_client = SmartESSCloudClient(email=email, password=password)

        data = self._smartess_client.get_latest_telemetry()
        if not data:
            logger.warning("No se pudo obtener telemetría de SmartESS Cloud, usando respaldo...")
            return self._read_simulator()

        # Extraer variables reales
        pv_w = float(data.get("pv_power_w", 0.0))
        load_w = float(data.get("load_power_w", 0.0))
        batt_w = float(data.get("battery_power_w", 0.0))
        soc = float(data.get("battery_soc", 0.0))
        batt_v = float(data.get("battery_voltage", 0.0))

        # Si el inversor reporta SOC 0% por ser baterías de plomo-ácido o sin BMS CAN,
        # estimar el SOC a partir de la curva de voltaje de 48V o potencias
        if soc <= 0.0:
            if batt_v > 40.0:
                soc = self._estimate_soc_from_voltage(batt_v)
            else:
                soc = 75.0 if batt_w >= 0 else 60.0

        if batt_v <= 0.0:
            batt_v = round(48.0 + (soc / 100.0) * 6.5, 2)

        charge_w = max(0.0, batt_w)
        discharge_w = max(0.0, -batt_w)

        # Determinar estado operativo
        if batt_w > 15.0 or (pv_w > load_w and pv_w > 50.0):
            status = "cargando"
        elif batt_w < -15.0 or load_w > pv_w:
            status = "descargando"
        else:
            status = "en_reposo"

        now = datetime.now(timezone.utc)
        threshold = float(os.getenv("CRITICAL_SOC_THRESHOLD", "30.0"))

        return SolarTelemetry(
            timestamp=now.isoformat(),
            epoch_ms=int(now.timestamp() * 1000),
            battery_voltage=round(batt_v, 2),
            battery_soc=round(soc, 1),
            pv_power_w=round(pv_w, 1),
            battery_power_w=round(batt_w, 1),
            battery_charge_w=round(charge_w, 1),
            battery_discharge_w=round(discharge_w, 1),
            load_power_w=round(load_w, 1),
            status=status,
            is_critical=(soc < threshold),
            source_mode="SMARTESS_CLOUD",
        )

    def _read_must_wifi_plug(self) -> SolarTelemetry:
        """
        Lee el Wi-Fi Plug Pro del inversor MUST en la red local cada 1.5s
        utilizando protocolo Solarman V5 / Modbus TCP en el puerto 8899.
        """
        from must_wifi_plug import MustWifiPlugClient

        host = os.getenv("MUST_WIFI_IP", "192.168.1.85")
        port = int(os.getenv("MUST_WIFI_PORT", "8899"))
        serial_str = os.getenv("MUST_WIFI_SERIAL", "33239850769")
        start_reg = int(os.getenv("MUST_MODBUS_START_REG", "15201"))

        # Convertir serial a entero (tomar los últimos 10 dígitos o hash numérico si excede 32 bits)
        serial_int = int(serial_str) & 0xFFFFFFFF

        client = MustWifiPlugClient(host=host, serial_number=serial_int, port=port)
        regs = client.read_holding_registers(start_register=start_reg, count=15)

        if not regs or len(regs) < 11:
            # Si el plug está reiniciándose o fuera de cobertura momentánea, reintentar con simulador transitorio
            logger.warning(f"No hubo respuesta del Wi-Fi Plug en {host}:{port}. Verificando conexión...")
            return self._read_simulator()

        # Mapeo oficial de registros de telemetría de MUST PV1800 (48V):
        # Base 15201:
        # idx 0 (15201): Estado de trabajo (0=PowerOn, 1=Standby, 2=Line/Red, 3=Batería, 4=Falla)
        # idx 4 (15205): Voltaje de batería (x0.1 V)
        # idx 5 (15206): Porcentaje SOC (%)
        # idx 6 (15207): Potencia Solar Paneles (W)
        # idx 7 (15208): Voltaje Solar (x0.1 V)
        # idx 8 (15209): Potencia Carga Batería (W)
        # idx 9 (15210): Potencia Descarga Batería (W)
        # idx 10 (15211): Consumo Hogar (W)
        voltage = round(regs[4] * 0.1, 2)
        soc = float(regs[5]) if (0 < regs[5] <= 100) else self._estimate_soc_from_voltage(voltage)
        pv_power = float(regs[6])
        charge_w = float(regs[8])
        discharge_w = float(regs[9])
        load_w = float(regs[10])

        net_batt_w = round(charge_w - discharge_w, 1)
        status = self._determine_status(net_batt_w)

        now = datetime.now(timezone.utc)
        threshold = float(os.getenv("CRITICAL_SOC_THRESHOLD", "30.0"))

        return SolarTelemetry(
            timestamp=now.isoformat(),
            epoch_ms=int(now.timestamp() * 1000),
            battery_voltage=voltage,
            battery_soc=soc,
            pv_power_w=pv_power,
            battery_power_w=net_batt_w,
            battery_charge_w=charge_w,
            battery_discharge_w=discharge_w,
            load_power_w=load_w,
            status=status,
            is_critical=(soc < threshold),
            source_mode="MUST_WIFI_PLUG",
        )

    def _estimate_soc_from_voltage(self, voltage: float) -> float:
        soc = ((voltage - self.v_min) / (self.v_max - self.v_min)) * 100.0
        return round(max(0.0, min(100.0, soc)), 1)

    def _determine_status(self, net_battery_power_w: float) -> str:
        if net_battery_power_w > 20.0:
            return "cargando"
        elif net_battery_power_w < -20.0:
            return "descargando"
        return "en_reposo"

    def _read_modbus_rtu(self) -> SolarTelemetry:
        """
        Lee registros Holding/Input estándar vía Modbus RTU usando pymodbus.
        Compatible con inversores Growatt, Victron, Deye, Must y Voltronic/Axpert.
        """
        from pymodbus.client import ModbusSerialClient

        client = ModbusSerialClient(
            port=self.serial_port,
            baudrate=self.baudrate,
            bytesize=8,
            parity="N",
            stopbits=1,
            timeout=1.5,
        )
        if not client.connect():
            raise ConnectionError(f"No se pudo abrir el puerto serial Modbus {self.serial_port}")

        try:
            # Ejemplo estándar de registros Modbus (ajustable según mapa de registros del inversor):
            # Reg 0: Voltaje Batería (x0.01V o x0.1V)
            # Reg 1: SOC Batería (%)
            # Reg 2: Potencia Solar PV (W)
            # Reg 3: Potencia Carga Batería (W)
            # Reg 4: Potencia Descarga Batería (W)
            # Reg 5: Potencia Consumo Casa (W)
            rr = client.read_input_registers(address=0, count=6, slave=self.slave_id)
            if rr.isError():
                raise IOError(f"Error Modbus RTU: {rr}")

            regs = rr.registers
            voltage = round(regs[0] * 0.1, 2)
            soc = float(regs[1]) if 0 < regs[1] <= 100 else self._estimate_soc_from_voltage(voltage)
            pv_power = float(regs[2])
            charge_w = float(regs[3])
            discharge_w = float(regs[4])
            load_w = float(regs[5])
            net_batt_w = round(charge_w - discharge_w, 1)
            status = self._determine_status(net_batt_w)

            now = datetime.now(timezone.utc)
            threshold = float(os.getenv("CRITICAL_SOC_THRESHOLD", "30.0"))
            return SolarTelemetry(
                timestamp=now.isoformat(),
                epoch_ms=int(now.timestamp() * 1000),
                battery_voltage=voltage,
                battery_soc=soc,
                pv_power_w=pv_power,
                battery_power_w=net_batt_w,
                battery_charge_w=charge_w,
                battery_discharge_w=discharge_w,
                load_power_w=load_w,
                status=status,
                is_critical=(soc < threshold),
                source_mode="MODBUS_RTU",
            )
        finally:
            client.close()

    def _read_esp32_bridge(self) -> SolarTelemetry:
        """
        Lee JSON en tiempo real desde un puente ESP32 conectado al puerto RS232/RS485
        del inversor en la red Wi-Fi local.
        """
        with socket.create_connection((self.esp32_host, self.esp32_port), timeout=1.5) as sock:
            sock.sendall(b"GET_TELEMETRY\n")
            raw = sock.recv(1024).decode("utf-8").strip()
            data = json.loads(raw)

        voltage = float(data["battery_voltage"])
        soc = float(data.get("battery_soc", self._estimate_soc_from_voltage(voltage)))
        pv_power = float(data.get("pv_power_w", 0.0))
        charge_w = float(data.get("battery_charge_w", 0.0))
        discharge_w = float(data.get("battery_discharge_w", 0.0))
        load_w = float(data.get("load_power_w", 0.0))
        net_batt_w = round(charge_w - discharge_w, 1)
        status = self._determine_status(net_batt_w)

        now = datetime.now(timezone.utc)
        threshold = float(os.getenv("CRITICAL_SOC_THRESHOLD", "30.0"))
        return SolarTelemetry(
            timestamp=now.isoformat(),
            epoch_ms=int(now.timestamp() * 1000),
            battery_voltage=round(voltage, 2),
            battery_soc=round(soc, 1),
            pv_power_w=round(pv_power, 1),
            battery_power_w=net_batt_w,
            battery_charge_w=round(charge_w, 1),
            battery_discharge_w=round(discharge_w, 1),
            load_power_w=round(load_w, 1),
            status=status,
            is_critical=(soc < threshold),
            source_mode="ESP32_TCP",
        )

    def _read_simulator(self) -> SolarTelemetry:
        """
        Generador de telemetría solar realista para desarrollo, pruebas de estrés
        y demostración en vivo.
        """
        now_local = datetime.now()
        hour_float = now_local.hour + now_local.minute / 60.0 + now_local.second / 3600.0

        # Generación solar realista según hora del día + ondulación suave en tiempo real
        wave = math.sin(time.time() / 15.0)
        if 6.5 <= hour_float <= 18.5:
            sun_factor = math.sin(math.pi * (hour_float - 6.5) / 12.0)
            pv_power = max(0.0, 2200.0 * (sun_factor ** 1.3) + 180.0 * wave + random.uniform(-25, 25))
        else:
            # Fuera de horario solar, permitir una pequeña simulación o cero
            pv_power = max(0.0, 650.0 * (wave + 0.6) + random.uniform(-15, 15))

        load_w = max(120.0, 520.0 + 190.0 * math.cos(time.time() / 22.0) + random.uniform(-20, 20))
        net_batt_w = round(pv_power - load_w, 1)

        charge_w = round(max(0.0, net_batt_w), 1)
        discharge_w = round(max(0.0, -net_batt_w), 1)

        # Actualizar SOC suavemente
        self._sim_soc += (net_batt_w / 18000.0)
        self._sim_soc = max(24.0, min(99.5, self._sim_soc))
        soc = round(self._sim_soc, 1)

        voltage = round(
            self.v_min + (soc / 100.0) * (self.v_max - self.v_min) + (0.25 if net_batt_w > 0 else -0.25),
            2,
        )
        status = self._determine_status(net_batt_w)

        now_utc = datetime.now(timezone.utc)
        threshold = float(os.getenv("CRITICAL_SOC_THRESHOLD", "30.0"))
        return SolarTelemetry(
            timestamp=now_utc.isoformat(),
            epoch_ms=int(now_utc.timestamp() * 1000),
            battery_voltage=voltage,
            battery_soc=soc,
            pv_power_w=round(pv_power, 1),
            battery_power_w=net_batt_w,
            battery_charge_w=charge_w,
            battery_discharge_w=discharge_w,
            load_power_w=round(load_w, 1),
            status=status,
            is_critical=(soc < threshold),
            source_mode="SIMULATOR",
        )


class SolarBackendService:
    """Orquestador principal del servidor local en MacBook."""

    def __init__(self):
        self.running = True
        self.mode = os.getenv("CONNECTION_MODE", "SIMULATOR")
        self.poll_interval = float(os.getenv("POLL_INTERVAL_SECONDS", "1.5"))
        self.mqtt_host = os.getenv("MQTT_BROKER_HOST", "127.0.0.1")
        self.mqtt_port = int(os.getenv("MQTT_BROKER_PORT", "1883"))
        self.topic_telemetry = os.getenv("MQTT_TOPIC_TELEMETRY", "hogar/solar/telemetria")
        self.topic_history = os.getenv("MQTT_TOPIC_HISTORY", "hogar/solar/historial_24h")
        self.topic_alert = os.getenv("MQTT_TOPIC_ALERT", "hogar/solar/alerta")

        self.db = LocalHistoryDB(BASE_DIR / "solar_history.db")
        self.reader = InverterReader(self.mode)
        self.alert_manager = CriticalAlertManager(
            threshold_soc=float(os.getenv("CRITICAL_SOC_THRESHOLD", "30.0")),
            cooldown_sec=int(os.getenv("ALERT_COOLDOWN_SECONDS", "900")),
        )

        # Cliente MQTT (Compatible con paho-mqtt v2)
        self.mqtt_client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id="macbook_solar_publisher",
            clean_session=False,
        )
        self.mqtt_client.on_connect = self._on_mqtt_connect
        self.mqtt_client.on_disconnect = self._on_mqtt_disconnect
        self.mqtt_client.on_message = self._on_mqtt_message
        self.mqtt_client.reconnect_delay_set(min_delay=1, max_delay=10)

        self._last_history_save_time = 0.0
        self._last_history_publish_time = 0.0

    def _on_mqtt_connect(self, client, userdata, flags, reason_code, properties):
        if reason_code == 0:
            logger.info(f"Conectado exitosamente al Broker MQTT local en {self.mqtt_host}:{self.mqtt_port}")
            # Suscribirse a comandos desde la app móvil (ej. solicitud de historial o prueba de alerta)
            client.subscribe("hogar/solar/comando", qos=1)
            self._publish_24h_history()
        else:
            logger.error(f"Fallo al conectar a MQTT, código: {reason_code}")

    def _on_mqtt_disconnect(self, client, userdata, flags, reason_code, properties):
        logger.warning(f"Desconectado del Broker MQTT (código: {reason_code}). Reintentando automáticamente...")

    def _on_mqtt_message(self, client, userdata, msg):
        """Permite a la app Flutter pedir el historial bajo demanda o simular una alerta crítica."""
        try:
            payload = msg.payload.decode("utf-8").strip()
            logger.info(f"Comando recibido en {msg.topic}: {payload}")
            if payload == "GET_HISTORY":
                self._publish_24h_history()
            elif payload == "TEST_CRITICAL_ALERT":
                # Permite probar el sistema de alerta crítica desde la app móvil
                sample = self.reader.read_telemetry()
                sample.battery_soc = 24.5
                sample.status = "descargando"
                sample.battery_discharge_w = 1450.0
                sample.is_critical = True
                self.alert_manager.last_alert_time = 0.0
                self.alert_manager.check_and_trigger(sample, self.mqtt_client, self.topic_alert)
        except Exception as exc:
            logger.error(f"Error procesando comando MQTT: {exc}")

    def _publish_24h_history(self) -> None:
        history_points = self.db.get_last_24h_downsampled(max_points=288)
        payload = json.dumps(
            {
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "count": len(history_points),
                "points": history_points,
            }
        )
        # Publicar con retain=True para que cualquier celular que abra la app
        # reciba instantáneamente la curva de las últimas 24 horas
        self.mqtt_client.publish(self.topic_history, payload, qos=1, retain=True)
        logger.info(f"Historial de 24h publicado en {self.topic_history} ({len(history_points)} puntos)")

    def start(self) -> None:
        logger.info(f"Iniciando Servicio Solar Local en modo: {self.mode}")
        while self.running:
            try:
                self.mqtt_client.connect(self.mqtt_host, self.mqtt_port, keepalive=30)
                self.mqtt_client.loop_start()
                break
            except Exception as exc:
                logger.warning(f"Esperando al broker Mosquitto en {self.mqtt_host}:{self.mqtt_port} ({exc})...")
                time.sleep(3)

        while self.running:
            loop_start = time.time()
            try:
                telemetry = self.reader.read_telemetry()
                payload_str = json.dumps(asdict(telemetry))

                # Publicar lectura en tiempo real (QoS 1 y retain=True para estado inmediato)
                self.mqtt_client.publish(self.topic_telemetry, payload_str, qos=1, retain=True)

                # Verificar si la batería bajó del 30%
                self.alert_manager.check_and_trigger(telemetry, self.mqtt_client, self.topic_alert)

                # Guardar muestra en base de datos SQLite cada 60 segundos y actualizar tópico de 24h
                now = time.time()
                if (now - self._last_history_save_time) >= 60.0:
                    self.db.insert_sample(telemetry)
                    self._last_history_save_time = now

                if (now - self._last_history_publish_time) >= 120.0:
                    self._publish_24h_history()
                    self._last_history_publish_time = now

            except Exception as exc:
                logger.error(f"Error en ciclo de lectura del inversor: {exc}")

            elapsed = time.time() - loop_start
            sleep_for = max(0.1, self.poll_interval - elapsed)
            time.sleep(sleep_for)

    def stop(self, *args) -> None:
        logger.info("Deteniendo Servicio Solar Local de forma segura...")
        self.running = False
        try:
            self.mqtt_client.loop_stop()
            self.mqtt_client.disconnect()
        except Exception:
            pass
        sys.exit(0)


if __name__ == "__main__":
    service = SolarBackendService()
    signal.signal(signal.SIGINT, service.stop)
    signal.signal(signal.SIGTERM, service.stop)
    service.start()
