from shop.pricing import apply_discount, calc_total


class Order:
    def __init__(self, items, discount_pct=0):
        self.items = items
        self.discount_pct = discount_pct

    def total(self):
        return apply_discount(calc_total(self.items), self.discount_pct)
