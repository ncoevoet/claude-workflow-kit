from shop import config


def export_header():
    return f"export ({config.load()['currency']})"
