#!/usr/bin/env python3
"""Synthetic analyzer unit tests only; never opens SSH, sockets, polkit or BPF."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('reload_vm', Path(__file__).with_name('linux-appfilter-reload-vm.py'))
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


class ReceiptChecks(unittest.TestCase):
    def setUp(self):
        self.hashes = [str(i) * 64 for i in range(1, 5)]
        self.rows = [{'event': 'policy_activated', 'gen': n, 'policy': self.hashes[n - 1],
                      'old_policy': self.hashes[n - 2], 'new_policy': self.hashes[n - 1]} for n in range(2, 5)]
        self.rows += [{'event': 'kernel_drop', 'gen': n, 'detail': f'tgid=99 kernel_monotonic_ns={n * 10 + 1}'} for n in range(1, 5)]
        self.windows = [(n, n * 10, n * 10 + 5) for n in range(1, 5)]

    def test_consistent_generations_and_activation_hashes(self):
        vm.validate_activations(self.rows, self.hashes)
        vm.validate_windows(self.rows, self.windows, 99, 4)

    def test_missing_duplicate_and_mismatched_activation(self):
        for rows in [self.rows[1:], self.rows + [self.rows[0]], copy.deepcopy(self.rows)]:
            if len(rows) == len(self.rows): rows[0]['new_policy'] = '0' * 64
            with self.assertRaises(RuntimeError): vm.validate_activations(rows, self.hashes)

    def test_old_events_must_not_be_relabeled_with_current_generation(self):
        self.rows[-1]['gen'] = 1
        with self.assertRaisesRegex(RuntimeError, 'different generation'):
            vm.validate_windows(self.rows, self.windows, 99, 4)

    def test_no_false_pass_without_observations_or_on_loss(self):
        with self.assertRaises(RuntimeError): vm.validate_activations([], self.hashes)
        with self.assertRaises(RuntimeError): vm.validate_windows([], self.windows, 99, 0)
        with self.assertRaises(RuntimeError): vm.validate_windows(self.rows, self.windows, 99, 5)
        self.rows.append({'event': 'receipt_loss', 'dropped': 1})
        with self.assertRaisesRegex(RuntimeError, 'receipt loss'): vm.validate_activations(self.rows, self.hashes)

    def test_state_digest_offset_and_untrusted_bpftool_bytes(self):
        data = bytes(range(48))
        self.assertEqual(vm.state_hash({'value': [f'{x:02x}' for x in data]}), data[16:48].hex())
        for value in [[], ['zz'], [256], 'not a byte array']:
            with self.assertRaises(RuntimeError): vm.state_hash({'value': value})


if __name__ == '__main__':
    unittest.main(verbosity=2)
