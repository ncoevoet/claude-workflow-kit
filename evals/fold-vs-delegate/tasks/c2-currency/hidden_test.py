import unittest
from shop.models import Item
from shop.parser import parse_line
from shop.formatter import format_item


class H(unittest.TestCase):
    def test(self):
        self.assertEqual(Item("a", 1.0, 1).currency, "EUR")
        self.assertEqual(parse_line("pen, 1.5, 2, USD").currency, "USD")
        self.assertEqual(parse_line("pen, 1.5, 2").currency, "EUR")
        self.assertEqual(format_item(parse_line("pen, 1.5, 2, USD")), "pen x2 @ 1.5 USD")
