import json
import os

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

PEERS_FILE = os.path.expanduser("~/.config/actionhub/peers.json")


def parse_cbor_item(data, offset):
    initial_byte = data[offset]
    major_type = initial_byte >> 5
    additional = initial_byte & 0x1F
    offset += 1
    if additional < 24:
        argument = additional
    elif additional == 24:
        argument = data[offset]
        offset += 1
    elif additional == 25:
        argument = int.from_bytes(data[offset:offset + 2], "big")
        offset += 2
    elif additional == 26:
        argument = int.from_bytes(data[offset:offset + 4], "big")
        offset += 4
    else:
        raise ValueError(f"unsupported cbor additional info {additional}")
    if major_type == 0:
        return argument, offset
    if major_type == 1:
        return -1 - argument, offset
    if major_type == 2:
        return data[offset:offset + argument], offset + argument
    if major_type == 3:
        return data[offset:offset + argument].decode(), offset + argument
    if major_type == 5:
        decoded_map = {}
        for _ in range(argument):
            key, offset = parse_cbor_item(data, offset)
            value, offset = parse_cbor_item(data, offset)
            decoded_map[key] = value
        return decoded_map, offset
    raise ValueError(f"unsupported cbor major type {major_type}")


def cose_key_to_pem(cose_key):
    x_coordinate = int.from_bytes(cose_key[-2], "big")
    y_coordinate = int.from_bytes(cose_key[-3], "big")
    public_key = ec.EllipticCurvePublicNumbers(x_coordinate, y_coordinate, ec.SECP256R1()).public_key()
    return public_key.public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()


def parse_pairing_data(authenticator_data):
    sign_count = int.from_bytes(authenticator_data[33:37], "big")
    credential_id_length = int.from_bytes(authenticator_data[53:55], "big")
    credential_id = authenticator_data[55:55 + credential_id_length]
    cose_key, _ = parse_cbor_item(authenticator_data, 55 + credential_id_length)
    return credential_id, cose_key_to_pem(cose_key), sign_count


def load_peers():
    try:
        with open(PEERS_FILE) as peers_file:
            return json.load(peers_file)
    except (OSError, json.JSONDecodeError):
        return {}


def save_peers(peers):
    os.makedirs(os.path.dirname(PEERS_FILE), exist_ok=True)
    with open(PEERS_FILE, "w") as peers_file:
        json.dump(peers, peers_file, indent=2)
