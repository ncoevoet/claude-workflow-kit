import unittest
from shop.models import Item
from shop.formatter import format_item, format_order


class H(unittest.TestCase):
    def test(self):
        self.assertEqual(format_item(Item("pen", 1.5, 2)), "pen x2 @ 1.50")
        self.assertIn("TOTAL 3.00", format_order([Item("pen", 1.5, 2)]))
