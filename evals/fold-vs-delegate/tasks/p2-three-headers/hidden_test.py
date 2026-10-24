import unittest
from shop.reports import reports_header
from shop.export import export_header
from shop.audit import audit_header


class H(unittest.TestCase):
    def test(self):
        self.assertEqual(reports_header(upper=True), "REPORTS (EUR)")
        self.assertEqual(export_header(), "export (EUR)")
        self.assertEqual(audit_header(upper=True), "AUDIT (EUR)")
