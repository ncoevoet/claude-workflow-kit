from shop import config


def reports_header():
    return f"reports ({config.load()['currency']})"
