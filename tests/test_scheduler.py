"""Small deterministic method tests; no paper workloads or result data."""

from dataclasses import replace
from fractions import Fraction
from itertools import product
from math import lcm
import unittest
from unittest.mock import patch

from gasp import Flow, Packet, schedule
from gasp.scheduler import GuardPolicy, add_flow, offset_mask, validate


def flow(uid="a", requirement=0, member=0, **attributes):
    values = dict(uid=uid, requirement=requirement, parent="D", asil="D",
                  member=member, source=0, destination=4, period=1_000_000,
                  payload=8, deadline=50_000, priority=1)
    values.update(attributes)
    return Flow(**values)


class ApiTests(unittest.TestCase):
    def test_duration_and_offsets_use_ten_ns_ticks(self):
        packet, offset = schedule((flow(),))[0]
        self.assertEqual(packet.duration(), 672)
        self.assertEqual(packet.wire_bytes, 84)
        self.assertEqual(offset, 0)

    def test_empty_input_is_valid(self):
        self.assertEqual(schedule(()), [])

    def test_invalid_fields_raise_input_errors(self):
        invalid = ({"source": 99}, {"source": -1}, {"destination": 5},
                   {"source": 4}, {"period": 0}, {"period": -1},
                   {"period": 1.5}, {"period": True}, {"deadline": 0},
                   {"payload": 9}, {"payload": -1}, {"payload": False},
                   {"priority": 2048}, {"priority": -1}, {"member": -1},
                   {"requirement": -1}, {"uid": ""}, {"asil": "QM"},
                   {"parent": "unknown"})
        for attributes in invalid:
            with self.subTest(attributes=attributes), self.assertRaises(ValueError):
                schedule((replace(flow(), **attributes),))
        with self.assertRaises(ValueError):
            schedule((object(),))

    def test_invalid_guard_is_rejected(self):
        for value in (-1, 1.0, True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                schedule((flow(),), guard_ticks=value)

    def test_group_attributes_must_match(self):
        for attributes in ({"period": 2_000_000}, {"deadline": 30_000},
                           {"payload": 7}, {"destination": 3}, {"parent": "C"}):
            with self.subTest(attributes=attributes), self.assertRaises(ValueError):
                schedule((flow(), flow("b", member=1, **attributes)))

    def test_duplicate_identifiers_are_rejected(self):
        cases = ((flow(), flow()),
                 (flow(), flow("b")),
                 (flow(), flow("q", parent="QM", asil="QM")),
                 (flow("q", parent="QM", asil="QM"),
                  flow("q2", parent="QM", asil="QM")))
        for messages in cases:
            with self.subTest(messages=messages), self.assertRaises(ValueError):
                schedule(messages)

    def test_all_members_are_required_despite_supplied_success_sets(self):
        messages = (flow(success_sets=((0,),)),
                    flow("b", member=3, source=1, success_sets=((0,),)))
        result = schedule(messages)
        self.assertEqual({f.uid for p,_ in result for f in p.flows}, {"a", "b"})
        self.assertEqual(len(result), 2)

    def test_same_domain_members_are_separated_and_cross_group_merge_remains(self):
        messages = (flow(), flow("b", member=1, asil="B"),
                    flow("c", requirement=1))
        result = schedule(messages)
        self.assertEqual(len(result), 2)
        self.assertEqual({f.uid for p,_ in result for f in p.flows}, {"a", "b", "c"})
        self.assertTrue(any(len(p.flows) == 2 for p,_ in result))
        for packet,_ in result:
            groups = [f.requirement for f in packet.flows]
            self.assertEqual(len(groups), len(set(groups)))

    def test_failed_group_rolls_back_then_next_group_is_attempted(self):
        messages = (
            flow("committed", deadline=1400),
            flow("failed0", requirement=1, asil="B", deadline=1500, priority=2),
            flow("failed1", requirement=1, member=1, asil="B", source=1,
                 deadline=1500, priority=3),
            flow("later", requirement=2, source=2, deadline=3000, priority=4),
            flow("q", requirement=3, parent="QM", asil="QM", source=3,
                 deadline=5000, priority=5),
        )
        result = schedule(messages)
        self.assertEqual({f.uid for p,_ in result for f in p.flows},
                         {"committed", "later", "q"})

    def test_result_check_rejects_partial_group(self):
        a,b = flow(), flow("b", member=1)
        with patch("gasp.api.group_schedule", return_value=[(Packet((a,)),0)]):
            with self.assertRaisesRegex(RuntimeError, "partially"):
                schedule((a,b))

    def test_result_check_rejects_same_group_copacking(self):
        a,b = flow(), flow("b", member=1)
        with patch("gasp.api.group_schedule", return_value=[(Packet((a,b)),0)]):
            with self.assertRaisesRegex(RuntimeError, "co-packed"):
                schedule((a,b))


class CoreTests(unittest.TestCase):
    def test_runtime_validator_remains_active_under_python_optimization(self):
        a,b = flow(), flow("b", requirement=1)
        invalid = ([(Packet((a,)),0),(Packet((b,)),0)],
                   [(Packet((replace(a,payload=9),)),0)],
                   [(Packet((a,)),0.5)],
                   [(Packet((a,)),50_000)])
        for certificate in invalid:
            with self.subTest(certificate=certificate), self.assertRaises(ValueError):
                validate(certificate, (a,b))

    def test_guard_start_boundary_is_strict(self):
        critical = Packet((flow(),))
        noncritical = Packet((flow("q", requirement=1, parent="QM", asil="QM"),))
        mask = offset_mask(noncritical, [(critical,20_000)],
                           guard=GuardPolicy(12_336,"gate"))
        boundary = 20_000-12_336
        self.assertTrue(mask & (1 << (boundary-1)))
        self.assertFalse(mask & (1 << boundary))
        self.assertTrue(mask & (1 << (20_000+critical.duration())))

    def test_merge_preserves_previously_admitted_deadlines(self):
        old = Packet(tuple(flow(f"a{i}", requirement=i, deadline=1500)
                           for i in range(3)))
        new = flow("new", requirement=4, deadline=3000)
        result = add_flow(new, [(old,0)], 1, GuardPolicy(12_336,"gate"),
                          True, True, payload_cap=1500)
        self.assertIsNotNone(result)
        self.assertIn((old,0), result[2])
        self.assertEqual(len(result[2][-1][0].flows), 1)
        validate(result[2], old.flows+(new,), guard=GuardPolicy(12_336,"gate"))

    def test_exact_increment_tie_prefers_earlier_completion(self):
        a = Packet(tuple(flow(f"a{i}", requirement=100+i, period=2_000_000,
                              payload=p, deadline=30_000)
                         for i,p in enumerate((8,8,8,8,8,6,0))))
        b = Packet(tuple(flow(f"b{i}", requirement=200+i, period=5_000_000,
                              deadline=30_000) for i in range(3)))
        new = flow("new", requirement=999, payload=0, deadline=30_000)
        for old in ([(a,0),(b,10_000)], [(b,10_000),(a,0)]):
            with self.subTest(order=old):
                result = add_flow(new, old, 1, GuardPolicy(12_336,"gate"),
                                  True, True, payload_cap=1500)
                self.assertEqual(result[0], Fraction(2,3125))
                self.assertEqual(result[1], 2432)
                self.assertEqual(result[2][-1][0].flows, a.flows+(new,))

    def test_periodic_mask_matches_explicit_event_expansion(self):
        # Small synthetic certificates, independent of the paper generator.
        pairs = ((2016,2016),(2016,4032),(3024,2016),(4032,3024))
        for (t,u), ac,bc,width,source,size in product(
                pairs, (False,True), (False,True), (0,672), (0,1), (1,3)):
            a = Packet((flow(parent="D" if ac else "QM", asil="D" if ac else "QM",
                             period=t, deadline=1524),))
            b = Packet(tuple(flow(f"b{i}",requirement=10+i, source=source,
                                  parent="D" if bc else "QM", asil="D" if bc else "QM",
                                  period=u, deadline=20_000) for i in range(size)))
            old_offset = u-300
            ca,cb = a.duration(), b.duration()
            horizon = lcm(t,u)
            expected = 0
            for offset in range(min(t-1,a.deadline-2*ca)+1):
                legal = True
                for hop in (0,1):
                    if a.route[hop] != b.route[hop]:
                        continue
                    for n in range(horizon//t,2*horizon//t):
                        start = offset+n*t+hop*ca
                        for m in range(3*horizon//u+3):
                            other = old_offset+m*u+hop*cb
                            if start < other+cb and other < start+ca:
                                legal = False
                            if ac != bc:
                                be,tt,tc = (other,start,ca) if ac else (start,other,cb)
                                if tt-width <= be < tt+tc:
                                    legal = False
                if legal:
                    expected |= 1 << offset
            with self.subTest(periods=(t,u),classes=(ac,bc),guard=width,
                              source=source,size=size):
                self.assertEqual(offset_mask(a,[(b,old_offset)],
                                             guard=GuardPolicy(width,"gate")), expected)


if __name__ == "__main__":
    unittest.main()
