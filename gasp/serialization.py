"""Padded Ethernet occupancy used by the GASP implementation."""


def wire_bytes(record_bytes):
    """Byte-equivalent occupancy, including preamble/SFD, FCS, pad and IFG."""
    if record_bytes < 0:
        raise ValueError("negative record length")
    return 20 + max(64, 22 + record_bytes)
