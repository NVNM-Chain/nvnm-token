"""Mutation checks against the freshly compiled production ABI."""

import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_abi", ROOT / "script/check-abi.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class AbiGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with (ROOT / "out/NVNMToken.sol/NVNMToken.json").open() as source:
            cls.production = json.load(source)["abi"]

    def test_production_abi_is_approved(self):
        GATE.validate(self.production)

    def test_added_mint_is_rejected(self):
        abi = copy.deepcopy(self.production)
        abi.append({"type": "function", "name": "mint", "inputs": [
            {"type": "address"}, {"type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"})
        with self.assertRaisesRegex(ValueError, "mint\\(address,uint256\\)"):
            GATE.validate(abi)

    def test_removed_function_is_rejected(self):
        abi = [item for item in self.production if item.get("name") != "permit"]
        with self.assertRaisesRegex(ValueError, "removed=.*permit"):
            GATE.validate(abi)

    def test_added_burn_is_rejected(self):
        abi = copy.deepcopy(self.production)
        abi.append({"type": "function", "name": "burn", "inputs": [{"type": "uint256"}], "outputs": [],
                    "stateMutability": "nonpayable"})
        with self.assertRaisesRegex(ValueError, "added=.*burn\\(uint256\\)"):
            GATE.validate(abi)

    def test_changed_constructor_is_rejected(self):
        for inputs, mutability in (([{"type": "address"}, {"type": "address"}], "nonpayable"),
                                   ([{"type": "address"}], "payable"), ([], "nonpayable")):
            abi = [item for item in self.production if item["type"] != "constructor"]
            abi.append({"type": "constructor", "inputs": inputs, "stateMutability": mutability})
            with self.subTest(inputs=inputs, mutability=mutability), \
                    self.assertRaisesRegex(ValueError, "Constructor mismatch"):
                GATE.validate(abi)

    def test_missing_constructor_is_rejected(self):
        abi = [item for item in self.production if item["type"] != "constructor"]
        with self.assertRaisesRegex(ValueError, "Constructor mismatch"):
            GATE.validate(abi)

    def test_payable_change_is_rejected(self):
        abi = copy.deepcopy(self.production)
        next(item for item in abi if item.get("name") == "transfer")["stateMutability"] = "payable"
        with self.assertRaisesRegex(ValueError, "changed=.*transfer"):
            GATE.validate(abi)

    def test_receive_and_fallback_are_rejected(self):
        for kind in ("receive", "fallback"):
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, kind):
                GATE.validate(self.production + [{"type": kind, "stateMutability": "payable"}])

    def test_nested_tuple_arrays_are_canonical(self):
        self.assertEqual(GATE.canonical_type({"type": "tuple[]", "components": [
            {"type": "address"}, {"type": "tuple[2]", "components": [{"type": "uint256"}]}]}),
            "(address,(uint256)[2])[]")


if __name__ == "__main__":
    unittest.main()
