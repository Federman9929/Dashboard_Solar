#!/usr/bin/env python3
"""
Módulo cliente para la API Cloud de SmartESS / DessMonitor.
Permite autenticarse automáticamente con usuario y contraseña,
consultar la telemetría en vivo del inversor solar (Casa_Falla)
y extraer métricas reales (voltaje de salida, estado de red, potencias, etc.)
sin requerir que la Mac esté en la misma subred Wi-Fi que el inversor.
"""

import hashlib
import json
import logging
import time
from typing import Any, Dict, Optional
import requests

logger = logging.getLogger("SmartESSCloud")

class SmartESSCloudClient:
    def __init__(self, email: str, password: str, company_key: str = "bnrl_frRFjEz8Mkn"):
        self.email = email
        self.password = password
        self.company_key = company_key
        self.token: Optional[str] = None
        self.secret: Optional[str] = None
        self.token_expire_time = 0.0

        # Identificadores de la planta / inversor
        self.pn: Optional[str] = None
        self.sn: Optional[str] = None
        self.devaddr: Optional[int] = None
        self.devcode: Optional[int] = None
        self.plant_alias: Optional[str] = None

    def _login(self) -> bool:
        """Autenticación en la API pública de SmartESS / DessMonitor."""
        try:
            salt = str(int(time.time() * 1000))
            pwd_hash = hashlib.sha1(self.password.encode("utf-8")).hexdigest()
            action_str = f"&action=authSource&usr={self.email}&company-key={self.company_key}&source=1"
            sign = hashlib.sha1((salt + pwd_hash + action_str).encode("utf-8")).hexdigest()

            url = f"https://web.dessmonitor.com/public/?sign={sign}&salt={salt}{action_str}"
            resp = requests.post(url, timeout=6)
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
        """Obtiene el PN, SN, devaddr y devcode del inversor registrado."""
        try:
            res = self._api_get("&action=webQueryDeviceEs&source=1")
            devices = res.get("dat", {}).get("device", [])
            if devices:
                d = devices[0]
                self.pn = d.get("pn", "Q0033239858759")
                self.sn = d.get("sn", "DEV1A1BD34C8C8C557")
                self.devaddr = d.get("devaddr", 4)
                self.devcode = d.get("devcode", 6422)
                self.plant_alias = d.get("collalias", "Casa_Falla")
                logger.info(f"Inversor detectado: {self.plant_alias} (PN: {self.pn}, SN: {self.sn})")
        except Exception as e:
            logger.warning(f"No se pudo cargar información del dispositivo: {e}")

    def _api_get(self, action_query: str) -> Dict[str, Any]:
        salt = str(int(time.time() * 1000))
        raw_sign = f"{salt}{self.secret}{self.token}{action_query}"
        sign = hashlib.sha1(raw_sign.encode("utf-8")).hexdigest()
        url = f"https://web.dessmonitor.com/public/?sign={sign}&salt={salt}&token={self.token}{action_query}"
        resp = requests.get(url, timeout=6)
        return resp.json()

    def get_latest_telemetry(self) -> Optional[Dict[str, Any]]:
        """
        Consulta la telemetría en tiempo real desde los servidores de SmartESS.
        Retorna diccionario unificado con métricas de batería, solar y consumo.
        """
        if not self._ensure_token():
            return None

        if not self.pn or not self.sn:
            self._load_device_info()

        try:
            # 1. Consulta de flujo de energía instantáneo
            flow_action = f"&action=webQueryDeviceEnergyFlowEs&source=1&pn={self.pn}&devaddr={self.devaddr}&sn={self.sn}&devcode={self.devcode}"
            flow_data = self._api_get(flow_action).get("dat", {})

            # 2. Consulta de parámetros detallados del inversor
            detail_action = f"&action=querySPDeviceLastData&source=1&devcode={self.devcode}&pn={self.pn}&devaddr={self.devaddr}&sn={self.sn}&i18n=es_ES"
            detail_data = self._api_get(detail_action).get("dat", {})

            # Parsear datos de flujo
            bt_status = {it.get("par"): it.get("val") for it in flow_data.get("bt_status", [])}
            pv_status = {it.get("par"): it.get("val") for it in flow_data.get("pv_status", [])}
            bc_status = {it.get("par"): it.get("val") for it in flow_data.get("bc_status", [])}
            gd_status = {it.get("par"): it.get("val") for it in flow_data.get("gd_status", [])}

            # Parsear parámetros detallados
            pars = detail_data.get("pars", {})
            pv_pars = {it.get("id"): it.get("val") for it in pars.get("pv_", [])}
            bc_pars = {it.get("id"): it.get("val") for it in pars.get("bc_", [])}
            sy_pars = {it.get("id"): it.get("val") for it in pars.get("sy_", [])}

            # Extraer potencias
            pv_power_kw = float(pv_status.get("pv_output_power", 0.0) or 0.0)
            pv_power_w = pv_power_kw * 1000.0 if pv_power_kw > 0 else float(pv_pars.get("pv_output_power", 0.0) or 0.0)

            load_power_kw = float(bc_status.get("load_active_power", 0.0) or 0.0)
            load_power_w = load_power_kw * 1000.0

            batt_power_kw = float(bt_status.get("battery_active_power", 0.0) or 0.0)
            batt_power_w = batt_power_kw * 1000.0

            # SOC y Voltaje
            soc_val = float(bt_status.get("bt_battery_capacity", 0.0) or 0.0)
            inverter_v = float(bc_pars.get("bc_phase_a_inverter_voltage", 240.0) or 240.0)
            work_state = sy_pars.get("status", "Normal").strip()

            return {
                "plant_name": self.plant_alias or "Casa_Falla",
                "inverter_sn": self.sn,
                "logger_pn": self.pn,
                "pv_power_w": pv_power_w,
                "load_power_w": load_power_w,
                "battery_power_w": batt_power_w,
                "battery_soc": soc_val,
                "inverter_voltage": inverter_v,
                "work_state": work_state,
                "raw_timestamp": flow_data.get("date"),
            }
        except Exception as e:
            logger.error(f"Error procesando telemetría de SmartESS: {e}")
            return None

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    client = SmartESSCloudClient("Federman9915@gmail.com", "Federman99")
    data = client.get_latest_telemetry()
    print("Datos obtenidos:", json.dumps(data, indent=2))
