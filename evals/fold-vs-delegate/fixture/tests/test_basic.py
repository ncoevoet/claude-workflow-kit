import unittest

from shop.models import Item
from shop.orders import Order
from shop.pricing import calc_total


class Basic(unittest.TestCase):
    def test_total(self):
        self.assertEqual(calc_total([Item("a", 2.0, 3)]), 6.0)

    def test_order_discount(self):
        self.assertAlmostEqual(Order([Item("a", 10.0, 1)], 10).total(), 9.0)
