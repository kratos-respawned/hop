func fuzzyScore(_ query: String, _ text: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = query.lowercased(), t = text.lowercased()
    if t.hasPrefix(q) { return 1000 - t.count }
    if t.contains(" " + q) { return 800 - t.count }
    if initials(text).hasPrefix(q) { return 700 - t.count }
    if t.contains(q) { return 500 - t.count }
    var rest = Substring(q), gaps = 0
    for c in t {
        guard let next = rest.first else { break }
        if c == next { rest.removeFirst() } else if rest.count < q.count { gaps += 1 }
    }
    return rest.isEmpty ? 300 - gaps - t.count : nil
}

private func initials(_ text: String) -> String {
    var out = "", prev: Character = " "
    for c in text {
        let startsWord = !(prev.isLetter || prev.isNumber) || (c.isUppercase && prev.isLowercase)
        if (c.isLetter || c.isNumber) && startsWord { out.append(c) }
        prev = c
    }
    return out.lowercased()
}
