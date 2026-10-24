import sys

from shop.formatter import format_order
from shop.parser import parse_line


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    items = [parse_line(a) for a in argv]
    print(format_order(items))
    return 0
