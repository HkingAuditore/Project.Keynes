def port_indexed_writes(text, target):
    replacements = []
    for match in target.finditer(text):
        bracket = match.end() - 1
        cursor, depth = bracket + 1, 1
        while cursor < len(text) and depth:
            depth += (text[cursor] == "[") - (text[cursor] == "]")
            cursor += 1
        if depth:
            raise ValueError("unclosed indexed write")
        import re
        assignment = re.match(r"\s*(\+=|-=|\|=|&=|=(?!=))\s*", text[cursor:])
        if not assignment:
            continue
        rhs_begin = cursor + assignment.end()
        semicolon = text.find(";", rhs_begin)
        if semicolon < 0:
            raise ValueError("unclosed indexed assignment")
        column, index = text[match.start():bracket], text[bracket + 1:cursor - 1]
        rhs = text[rhs_begin:semicolon]
        if assignment.group(1) != "=":
            rhs = f"{column}[{index}] {assignment.group(1)[0]} ({rhs})"
        sink = ", market_mutation_sink()" if column.startswith(("market_store()", "population_store()")) else ""
        replacements.append((match.start(), semicolon + 1, f"{column}.write_scalar({index}, {rhs}{sink});"))
    return replacements
