from shop.models import Item


def low_stock(items, threshold=3):
    return [i for i in items if i.qty < threshold]
