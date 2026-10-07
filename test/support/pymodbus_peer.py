"""Independent pymodbus TCP, RTU, and ASCII peer used by AVModbus tests.

    python pymodbus_peer.py server tcp PORT
    python pymodbus_peer.py server rtu|ascii DEVICE
    python pymodbus_peer.py client tcp PORT
    python pymodbus_peer.py client rtu|ascii DEVICE
    python pymodbus_peer.py extension-server tcp PORT
    python pymodbus_peer.py extension-client rtu|ascii DEVICE

The server exposes deterministic data for unit 1. The client runs a fixed set
of reads and writes and prints one machine-readable result per operation.
"""

import asyncio
import os
import sys

from pymodbus import FramerType, ModbusDeviceIdentification
from pymodbus.datastore import (
    ModbusDeviceContext,
    ModbusSequentialDataBlock,
    ModbusServerContext,
)
from pymodbus.pdu import ModbusPDU


class CustomEchoPDU(ModbusPDU):
    """Fixed-size user-defined PDU used to verify function-code extensions."""

    function_code = 0x41
    rtu_frame_size = 7

    def __init__(self, data=b"", dev_id=1, transaction_id=0):
        super().__init__(dev_id=dev_id, transaction_id=transaction_id)
        self.data = data

    def encode(self):
        return self.data

    def decode(self, data):
        self.data = data

    async def datastore_update(self, context, device_id):
        del context
        return CustomEchoPDU(
            self.data[::-1],
            dev_id=device_id,
            transaction_id=self.transaction_id,
        )


class GenericMEIPDU(ModbusPDU):
    """Fixed-size generic MEI PDU used independently of device identification."""

    function_code = 0x2B
    rtu_frame_size = 7

    def __init__(self, mei_type=0x0D, data=b"", dev_id=1, transaction_id=0):
        super().__init__(dev_id=dev_id, transaction_id=transaction_id)
        self.mei_type = mei_type
        self.data = data

    def encode(self):
        return bytes([self.mei_type]) + self.data

    def decode(self, data):
        self.mei_type = data[0]
        self.data = data[1:]

    async def datastore_update(self, context, device_id):
        del context
        return GenericMEIPDU(
            self.mei_type,
            self.data[::-1],
            dev_id=device_id,
            transaction_id=self.transaction_id,
        )


def server(transport, target, extensions=False):
    from pymodbus.server import ModbusSerialServer, ModbusTcpServer

    store = ModbusDeviceContext(
        di=ModbusSequentialDataBlock(1, [False] * 100),
        co=ModbusSequentialDataBlock(1, [index % 3 == 0 for index in range(100)]),
        hr=ModbusSequentialDataBlock(1, [1000 + index for index in range(100)]),
        ir=ModbusSequentialDataBlock(1, [2000 + index for index in range(100)]),
    )
    context = ModbusServerContext(devices={1: store}, single=False)
    identity = ModbusDeviceIdentification(
        info_name={
            "VendorName": "pymodbus",
            "ProductCode": "PM",
            "MajorMinorRevision": "3.15",
        }
    )

    async def serve():
        def trace_packet(sending, data):
            print(
                f"packet {'send' if sending else 'recv'} {data.hex()}",
                flush=True,
            )
            return data

        trace = trace_packet if os.environ.get("PYMODBUS_DEBUG") else None

        if transport == "tcp":
            server_instance = ModbusTcpServer(
                context,
                identity=identity,
                address=("127.0.0.1", int(target)),
                trace_packet=trace,
                custom_pdu=[CustomEchoPDU, GenericMEIPDU] if extensions else None,
            )
        else:
            framer = FramerType.RTU if transport == "rtu" else FramerType.ASCII
            server_instance = ModbusSerialServer(
                context,
                identity=identity,
                port=target,
                framer=framer,
                baudrate=19_200,
                bytesize=8,
                parity="N",
                stopbits=1,
                trace_packet=trace,
                custom_pdu=[CustomEchoPDU, GenericMEIPDU] if extensions else None,
            )
        await server_instance.serve_forever(background=True)
        print("ready", flush=True)
        await server_instance.serving

    asyncio.run(serve())


def client(transport, target, extensions=False):
    from pymodbus.client import ModbusSerialClient, ModbusTcpClient

    if transport == "tcp":
        connection = ModbusTcpClient("127.0.0.1", port=int(target), timeout=2)
    else:
        framer = FramerType.RTU if transport == "rtu" else FramerType.ASCII
        connection = ModbusSerialClient(
            target,
            framer=framer,
            baudrate=19_200,
            bytesize=8,
            parity="N",
            stopbits=1,
            timeout=2,
        )
    if not connection.connect():
        raise RuntimeError("could not connect to AVModbus server")

    if extensions:
        connection.register(CustomEchoPDU)
        connection.register(GenericMEIPDU)

        custom = connection.execute(
            False, CustomEchoPDU(b"\x01\x02\x03", dev_id=1)
        )
        print("custom ok", *custom.data, flush=True)

        mei = connection.execute(
            False, GenericMEIPDU(0x0D, b"\x04\x05", dev_id=1)
        )
        print("mei ok", *mei.data, flush=True)
        connection.close()
        return

    def show(name, response, field=None):
        if response.isError():
            print(name, "exception", getattr(response, "exception_code", "?"), flush=True)
            return

        value = getattr(response, field) if field else None
        if isinstance(value, list):
            value = " ".join(str(int(item)) for item in value)
        print(name, "ok", value if value is not None else "", flush=True)

    show("write_registers", connection.write_registers(10, [1, 2, 3], device_id=1))
    show(
        "read_holding_registers",
        connection.read_holding_registers(10, count=3, device_id=1),
        "registers",
    )
    show("write_register", connection.write_register(20, 0x12, device_id=1))
    show(
        "mask_write_register",
        connection.mask_write_register(
            address=20, and_mask=0xF2, or_mask=0x25, device_id=1
        ),
    )
    show(
        "read_holding_registers",
        connection.read_holding_registers(20, count=1, device_id=1),
        "registers",
    )
    show("write_coils", connection.write_coils(5, [True, False, True], device_id=1))
    show("read_coils", connection.read_coils(5, count=3, device_id=1), "bits")
    show("write_coil", connection.write_coil(9, True, device_id=1))
    show("read_coils", connection.read_coils(9, count=1, device_id=1), "bits")
    show(
        "readwrite_registers",
        connection.readwrite_registers(
            read_address=30,
            read_count=2,
            write_address=30,
            values=[7, 8],
            device_id=1,
        ),
        "registers",
    )
    show(
        "read_input_registers",
        connection.read_input_registers(0, count=2, device_id=1),
        "registers",
    )
    show(
        "read_discrete_inputs",
        connection.read_discrete_inputs(0, count=2, device_id=1),
        "bits",
    )
    show(
        "read_holding_registers",
        connection.read_holding_registers(999, count=2, device_id=1),
        "registers",
    )
    connection.close()


if __name__ == "__main__":
    arguments = sys.argv[1:]

    if len(arguments) == 2:
        role, target = arguments
        transport = "tcp"
    else:
        role, transport, target = arguments

    if role == "server":
        server(transport, target)
    elif role == "extension-server":
        server(transport, target, extensions=True)
    elif role == "extension-client":
        client(transport, target, extensions=True)
    else:
        client(transport, target)
