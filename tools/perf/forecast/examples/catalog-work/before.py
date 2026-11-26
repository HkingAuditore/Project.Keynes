def read_entry(price):
    return price * 2


def lookup(table, index):
    return table[index]


def quote(prices, orders):
    total = 0
    for index in orders:
        table = [read_entry(price) for price in prices]
        total += lookup(table, index)
    return total
