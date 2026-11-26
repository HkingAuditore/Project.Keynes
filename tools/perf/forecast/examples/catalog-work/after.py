def read_entry(price):
    return price * 2


def lookup(table, index):
    return table[index]


def quote(prices, orders):
    if not orders:
        return 0
    table = [read_entry(price) for price in prices]
    return sum(lookup(table, index) for index in orders)
