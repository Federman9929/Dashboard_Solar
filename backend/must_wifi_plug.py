#!/usr/bin/env python3
"""
Módulo de lectura directa para inversores MUST (PV1800/PH1800)
a través del datalogger 'Wi-Fi Plug Pro' (Protocolo Solarman V5 / Modbus TCP en puerto 8899).
Permite lecturas en tiempo real cada 1-2 segundos sin pasar por la nube de SmartESS.
"""

import socket
import struct
import logging
from typing import Dict, Any, Optional

logger = logging.getLogger("MustWifiPlug")

class MustWifiPlugClient:
    """
    Cliente para comunicarse directamente con el Wi-Fi Plug Pro-05/25
    en la red local LAN (puerto 8899) encapsulando Modbus RTU en tramas Solarman V5.
    """

    def __init__(self, host: str, serial_number: int, port: int = 8899, timeout: float = 2.0):
        self.host = host
        self.port = port
        self.serial_number = serial_number  # Número de serie numérico del Wi-Fi Plug
        self.timeout = timeout

    def _calculate_checksum(self, data: bytes) -> int:
        checksum = 0
        for b in data:
            checksum = (checksum + b) & 0xFF
        return checksum

    def _build_solarman_v5_frame(self, modbus_payload: bytes) -> bytes:
        """
        Construye una trama Solarman V5 para enviar peticiones Modbus al inversor:
        Header: 0xA5
        Length: 2 bytes
        Control Code: 0x45 0x10 (Request)
        Serial: 2 bytes seq
        Dongle LSN: 4 bytes little-endian
        Payload Type: 0x02
        Sensor Type: 0x0000
        Delivery/Time: 8 bytes
        Modbus Frame + Checksum + 0x15
        """
        payload_len = len(modbus_payload)
        frame_len = payload_len + 15
        header = b"\xa5" + struct.pack("<H", frame_len) + b"\x45\x10\x00\x00"
        dongle_serial = struct.pack("<I", self.serial_number)
        sub_header = b"\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        
        # Modbus frame con CRC16
        crc = self._crc16(modbus_payload)
        full_modbus = modbus_payload + struct.pack("<H", crc)
        
        raw_body = header + dongle_serial + sub_header + full_modbus
        checksum = self._calculate_checksum(raw_body[1:])
        return raw_body + bytes([checksum, 0x15])

    def _crc16(self, data: bytes) -> int:
        crc = 0xFFFF
        for pos in data:
            crc ^= pos
            for _ in range(8):
                if (crc & 1) != 0:
                    crc = (crc >> 1) ^ 0xA001
                else:
                    crc >>= 1
        return crc

    def read_holding_registers(self, start_register: int = 15201, count: int = 15) -> Optional[list]:
        """
        Lee registros Holding del inversor MUST (ej. bloque 15201 - 15215 o 10101 - 10115).
        """
        # Función 0x03 (Read Holding Registers), Slave ID 0x01
        modbus_req = struct.pack(">BBHH", 0x01, 0x03, start_register, count)
        frame = self._build_solarman_v5_frame(modbus_req)

        try:
            with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
                sock.sendall(frame)
                response = sock.recv(1024)

            if len(response) < 28 or response[0] != 0xA5:
                # Si el plug responde en modo Modbus RTU transparente directo sobre TCP:
                return self._try_raw_modbus(modbus_req)

            # Extraer respuesta Modbus del interior de la trama Solarman V5
            # El payload de datos comienza típecticamente a partir del byte 25
            modbus_resp = response[25:-2]
            if len(modbus_resp) >= 3 and modbus_resp[1] == 0x03:
                byte_count = modbus_resp[2]
                raw_regs = modbus_resp[3:3 + byte_count]
                registers = [struct.unpack(">H", raw_regs[i:i+2])[0] for i in range(0, len(raw_regs), 2)]
                return registers
            
            return None
        except Exception as e:
            logger.debug(f"Fallo Solarman V5 en {self.host}:{self.port} ({e}), probando fallback Modbus TCP directo...")
            return self._try_raw_modbus(modbus_req)

    def _try_raw_modbus(self, modbus_req: bytes) -> Optional[list]:
        """Fallback en caso de que el Plug esté configurado en modo transparente TCP directo."""
        try:
            crc = self._crc16(modbus_req)
            req_with_crc = modbus_req + struct.pack("<H", crc)
            with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
                sock.sendall(req_with_crc)
                resp = sock.recv(512)
            if len(resp) >= 5 and resp[1] == 0x03:
                byte_count = resp[2]
                raw_regs = resp[3:3 + byte_count]
                return [struct.unpack(">H", raw_regs[i:i+2])[0] for i in range(0, len(raw_regs), 2)]
        except Exception:
            pass
        return None
