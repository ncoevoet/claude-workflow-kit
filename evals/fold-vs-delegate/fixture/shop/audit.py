from shop import config


def audit_header():
    return f"audit ({config.load()['currency']})"
