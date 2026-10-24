import unittest
from shop.models import Item
from shop.pricing import order_total
from shop.formatter import format_order


class H(unittest.TestCase):
    def test(self):
        self.assertEqual(order_total([Item("a", 1.5, 2)]), 3.0)
        self.assertIn("TOTAL 3.0", format_order([Item("a", 1.5, 2)]))
