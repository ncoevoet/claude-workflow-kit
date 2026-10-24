import contextlib, io, json, unittest
from shop.cli import main
from shop.formatter import format_order_json
from shop.parser import parse_line


class H(unittest.TestCase):
    def test(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            main(["--json", "a, 2.0, 3"])
        d = json.loads(out.getvalue())
        self.assertEqual(d["total"], 6.0)
        self.assertEqual(d["items"][0]["name"], "a")
        self.assertEqual(json.loads(format_order_json([parse_line("b, 1.0, 1")]))["total"], 1.0)
