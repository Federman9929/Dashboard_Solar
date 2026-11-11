#!/usr/bin/env python3
"""
Módulo cliente resiliente para la API Cloud de SmartESS / DessMonitor.
Permite autenticarse automáticamente con usuario y contraseña,
consultar la telemetría en vivo del inversor solar (Casa_Falla)
y extraer métricas reales con caché inteligente, sesión HTTP persistente
(keep-alive) y reintentos automáticos sin bloqueos.
"""

import hashlib
import json
import logging
import time
from typing import Any, Dict, Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger("SmartESSCloud")


class SmartESSCloudClient:
    def __init__(
        self,
        email: str,
        password: str,
        company_key: str = "bnrl_frRFjEz8Mkn",
        cache_ttl_seconds: float = 10.0,
    ):
        self.email = email
        self.password = password
        self.company_key = company_key
        self.cache_ttl_seconds = cache_ttl_seconds

        self.token: Optional[str] = None
        self.secret: Optional[str] = None
        self.token_expire_time = 0.0

        # Identificadores pre-conocidos de la planta / inversor Casa_Falla como respaldo inmediato
        self.pn: str = "Q0033239858759"
        self.sn: str = "DEV1A1BD34C8C8C557"
        self.devaddr: int = 4
        self.devcode: int = 6422
        self.plant_alias: str = "Casa_Falla"

        # Caché en memoria para no saturar el servidor de SmartESS cada 1.5s
        self._cached_telemetry: Optional[Dict[str, Any]] = None
        self._last_fetch_time: float = 0.0

        # Sesión HTTP con Keep-Alive y Retry automático
        self.session = requests.Session()
        retry_strategy = Retry(
            total=2,
            backoff_factor=0.5,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["GET", "POST"],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy, pool_connections=4, pool_maxsize=4)
        self.session.mount("https://", adapter)
        self.session.mount("http://", adapter)

    def _login(self) -> bool:
        """Autenticación en la API pública de SmartESS / DessMonitor."""
        try:
            salt = str(int(time.time() * 1000))
            pwd_hash = hashlib.sha1(self.password.encode("utf-8")).hexdigest()
            action_str = (
                f"&action=authSource&usr={self.email}&company-key={self.company_key}&source=1"
            )
            sign = hashlib.sha1((salt + pwd_hash + action_str).encode("utf-8")).hexdigest()

            url = f"https://web.dessmonitor.com/public/?sign={sign}&salt={salt}{action_str}"
            resp = self.session.post(url, timeout=10)
            data = resp.json()

            if data.get("err") == 0:
                dat = data.get("dat", {})
                self.token = dat.get("token")
                self.secret = dat.get("secret")
                expire_seconds = float(dat.get("expire", 432000))
                self.token_expire_time = time.time() + expire_seconds - 300
                logger.info(f"Autenticado exitosamente en SmartESS como {dat.get('usr')}")
                self._load_device_info()
                return True
            else:
                logger.error(f"Error de autenticación SmartESS: {data.get('desc')}")
                return False
        except Exception as e:
            logger.error(f"Excepción conectando a SmartESS Cloud: {e}")
            return False

    def _ensure_token(self) -> bool:
        if not self.token or not self.secret or time.time() >= self.token_expire_time:
            return self._login()
        return True

    def _load_device_info(self) -> None:
        """Obtiene el PN, SN, devaddr y devcode del inversor registrado (con fallback a valores conocidos)."""
        try:
            res = self._api_get("&action=webQueryDeviceEs&source=1")
            devices = res.get("dat", {}).get("device", [])
            if devices:
                d = devices[0]
                self.pn = d.get("pn", self.pn)
                self.sn = d.get("sn", self.sn)
                self.devaddr = int(d.get("devaddr", self.devaddr))
                self.devcode = int(d.get("devcode", self.devcode))
                self.plant_alias = d.get("collalias", self.plant_alias)
                logger.info(
                    f"Inversor detectado: {self.plant_alias} (PN: {self.pn}, SN: {self.sn})"
                )
        except Exception as e:
            logger.info(
                f"Usando identificadores preconfigurados para {self.plant_alias} (PN: {self.pn}) tras timeout inicial: {e}"
            )

    def _api_get(self, action_query: str) -> Dict[str, Any]:
        salt = str(int(time.time() * 1000))
        raw_sign = f"{salt}{self.secret}{self.token}{action_query}"
        sign = hashlib.sha1(raw_sign.encode("utf-8")).hexdigest()
        url = f"https://web.dessmonitor.com/public/?sign={sign}&salt={salt}&token={self.token}{action_query}"
        resp = self.session.get(url, timeout=10)
        return resp.json()

    def get_latest_telemetry(self) -> Optional[Dict[str, Any]]:
        """
        Consulta la telemetría desde los servidores de SmartESS.
        Si se consultó hace menos de `cache_ttl_seconds`, devuelve el último dato válido
        instantáneamente para mantener el stream MQTT fluido a 1.5s sin saturar la API Cloud.
        """
        now = time.time()
        if (
            self._cached_telemetry is not None
            and (now - self._last_fetch_time) < self.cache_ttl_seconds
        ):
            return self._cached_telemetry

        if not self._ensure_token():
            return self._cached_telemetry

        try:
            # 1. Consulta de flujo de energía instantáneo
            flow_action = (
                f"&action=webQueryDeviceEnergyFlowEs&source=1"
                f"&pn={self.pn}&devaddr={self.devaddr}&sn={self.sn}&devcode={self.devcode}"
            )
            flow_resp = self._api_get(flow_action)
            if flow_resp.get("err") in (257, 258, 401):  # Token expirado
                self.token = None
                if not self._ensure_token():
                    return self._cached_telemetry
                flow_resp = self._api_get(flow_action)

            flow_data = flow_resp.get("dat", {})

            # 2. Consulta de parámetros detallados del inversor
            detail_action = (
                f"&action=querySPDeviceLastData&source=1"
                f"&devcode={self.devcode}&pn={self.pn}&devaddr={self.devaddr}&sn={self.sn}&i18n=en_US"
            )
            detail_data = self._api_get(detail_action).get("dat", {})

            # Parsear datos de flujo
            bt_status = {it.get("par"): it.get("val") for it in flow_data.get("bt_status", [])}
            pv_status = {it.get("par"): it.get("val") for it in flow_data.get("pv_status", [])}
            bc_status = {it.get("par"): it.get("val") for it in flow_data.get("bc_status", [])}

            # Parsear parámetros detallados (incluyendo categoría bt_ si existe)
            pars = detail_data.get("pars", {})
            pv_pars = {it.get("id"): it.get("val") for it in pars.get("pv_", [])}
            bc_pars = {it.get("id"): it.get("val") for it in pars.get("bc_", [])}
            bt_pars = {it.get("id"): it.get("val") for it in pars.get("bt_", [])}
            sy_pars = {it.get("id"): it.get("val") for it in pars.get("sy_", [])}

            # Extraer potencias
            pv_power_kw = float(pv_status.get("pv_output_power", 0.0) or 0.0)
            pv_power_w = (
                pv_power_kw * 1000.0
                if pv_power_kw > 0
                else float(pv_pars.get("pv_output_power", 0.0) or 0.0)
            )

            load_power_kw = float(bc_status.get("load_active_power", 0.0) or 0.0)
            load_power_w = load_power_kw * 1000.0
            if load_power_w <= 0.0:
                # Si load_active_power no viene en kW, calcular de V * I de salida
                inv_v = float(bc_pars.get("bc_phase_a_inverter_voltage", 240.0) or 240.0)
                load_a = float(bc_pars.get("bc_load_current", 0.0) or 0.0)
                load_power_w = round(inv_v * load_a, 1)

            batt_power_kw = float(bt_status.get("battery_active_power", 0.0) or 0.0)
            batt_power_w = batt_power_kw * 1000.0

            # SOC y Voltaje de batería
            soc_val = float(
                bt_status.get("bt_battery_capacity", 0.0)
                or bt_pars.get("bt_battery_capacity", 0.0)
                or 0.0
            )
            batt_v = float(
                bt_pars.get("bt_voltage", 0.0)
                or bt_pars.get("bt_battery_voltage", 0.0)
                or 0.0
            )
            inverter_v = float(bc_pars.get("bc_phase_a_inverter_voltage", 240.0) or 240.0)
            work_state = sy_pars.get("status", "Normal").strip()

            self._cached_telemetry = {
                "plant_name": self.plant_alias,
                "inverter_sn": self.sn,
                "logger_pn": self.pn,
                "pv_power_w": pv_power_w,
                "load_power_w": load_power_w,
                "battery_power_w": batt_power_w,
                "battery_soc": soc_val,
                "battery_voltage": batt_v,
                "inverter_voltage": inverter_v,
                "work_state": work_state,
                "raw_timestamp": flow_data.get("date"),
            }
            self._last_fetch_time = now
            return self._cached_telemetry

        except Exception as e:
            logger.warning(f"Timeout temporal consultando SmartESS Cloud ({e}); manteniendo última lectura válida.")
            return self._cached_telemetry


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    client = SmartESSCloudClient("Federman9915@gmail.com", "Federman99")
    data = client.get_latest_telemetry()
    print("Datos obtenidos:", json.dumps(data, indent=2))
