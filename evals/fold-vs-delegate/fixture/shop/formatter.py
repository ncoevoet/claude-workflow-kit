from shop.pricing import calc_total


def format_item(item):
    return f"{item.name} x{item.qty} @ {item.price}"


def format_order(items):
    lines = [format_item(i) for i in items]
    lines.append(f"TOTAL {calc_total(items)}")
    return "\n".join(lines)
