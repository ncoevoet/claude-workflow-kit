import unittest
from shop.text import slugify
from shop.mathutil import clamp


class H(unittest.TestCase):
    def test(self):
        self.assertEqual(slugify("  Hello, World!! "), "hello-world")
        self.assertEqual(slugify("a__b"), "a-b")
        self.assertEqual(clamp(5, 0, 3), 3)
        self.assertEqual(clamp(-1, 0, 3), 0)
        with self.assertRaises(ValueError):
            clamp(1, 3, 0)
