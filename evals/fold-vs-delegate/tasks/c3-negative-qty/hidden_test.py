import contextlib, io, unittest
from shop.parser import parse_line
from shop.cli import main


class H(unittest.TestCase):
    def test(self):
        with self.assertRaises(ValueError):
            parse_line("a, 1.0, -1")
        with self.assertRaises(ValueError):
            parse_line("a, 1.0, 0")
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(["a, 1.0, -2"]), 2)
        self.assertTrue(err.getvalue().strip())
