from shop.models import Item


def parse_line(line):
    name, price, qty = (p.strip() for p in line.split(","))
    return Item(name, float(price), int(qty))
