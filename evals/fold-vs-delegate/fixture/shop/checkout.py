from shop.orders import Order
from shop.pricing import apply_discount


def amount_due(order: Order):
    return round(apply_discount(order.total(), order.discount_pct), 2)
