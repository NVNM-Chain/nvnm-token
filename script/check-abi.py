#!/usr/bin/env python3
"""Fail when the reviewed token's callable ABI or constructor changes, including mutability."""

import argparse
import json
from pathlib import Path


# Changes to this list require review of the corresponding capability change.
# Output types and mutability are included because a selector alone omits both.
APPROVED = {
    "DOMAIN_SEPARATOR()": ("bytes32", "view"),
    "INITIAL_SUPPLY()": ("uint256", "view"),
    "allowance(address,address)": ("uint256", "view"),
    "approve(address,uint256)": ("bool", "nonpayable"),
    "balanceOf(address)": ("uint256", "view"),
    "decimals()": ("uint8", "view"),
    "eip712Domain()": ("bytes1,string,string,uint256,address,bytes32,uint256[]", "view"),
    "name()": ("string", "view"),
    "nonces(address)": ("uint256", "view"),
    "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)": ("", "nonpayable"),
    "symbol()": ("string", "view"),
    "totalSupply()": ("uint256", "view"),
    "transfer(address,uint256)": ("bool", "nonpayable"),
    "transferFrom(address,address,uint256)": ("bool", "nonpayable"),
}

# The constructor is reviewed as well: its inputs and mutability.
APPROVED_CONSTRUCTOR = ("address", "nonpayable")


def canonical_type(parameter):
    kind = parameter["type"]
    if kind.startswith("tuple"):
        fields = ",".join(canonical_type(item) for item in parameter["components"])
        return f"({fields}){kind[5:]}"
    return kind


def validate(abi):
    actual = {}
    constructors = []
    for item in abi:
        kind = item["type"]
        if kind in {"fallback", "receive"}:
            raise ValueError(f"Unapproved {kind} entrypoint")
        if kind == "constructor":
            inputs = ",".join(canonical_type(value) for value in item["inputs"])
            constructors.append((inputs, item["stateMutability"]))
            continue
        if kind != "function":
            continue
        inputs = ",".join(canonical_type(value) for value in item["inputs"])
        signature = f"{item['name']}({inputs})"
        if signature in actual:
            raise ValueError(f"Duplicate ABI function: {signature}")
        actual[signature] = (
            ",".join(canonical_type(value) for value in item["outputs"]),
            item["stateMutability"],
        )
    added = sorted(actual.keys() - APPROVED.keys())
    removed = sorted(APPROVED.keys() - actual.keys())
    changed = sorted(key for key in actual.keys() & APPROVED.keys() if actual[key] != APPROVED[key])
    if added or removed or changed:
        raise ValueError(f"ABI mismatch: added={added}; removed={removed}; changed={changed}")
    if constructors != [APPROVED_CONSTRUCTOR]:
        raise ValueError(f"Constructor mismatch: {constructors}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", nargs="?", default="out/NVNMToken.sol/NVNMToken.json", type=Path)
    args = parser.parse_args()
    try:
        with args.artifact.open() as source:
            validate(json.load(source)["abi"])
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"ABI check failed: {error}\n")
    print(f"Approved callable ABI: {len(APPROVED)} functions and constructor({APPROVED_CONSTRUCTOR[0]}); "
          "no fallback or receive")


if __name__ == "__main__":
    main()
