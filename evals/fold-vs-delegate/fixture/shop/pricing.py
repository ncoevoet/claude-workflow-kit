def calc_total(items):
    return sum(i.price * i.qty for i in items)


def apply_discount(total, pct):
    return total * (1 - pct / 100)
