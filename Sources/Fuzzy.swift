enum MatchScore {
    static let prefix = 1000
    static let wordStart = 800
    static let initials = 700
    static let substring = 500
    static let scattered = 300
}

func fuzzyScore(_ query: String, _ text: String) -> Int? {
    if query.isEmpty { return 0 }
    let wanted = query.lowercased(), name = text.lowercased()
    if name.hasPrefix(wanted) { return MatchScore.prefix - name.count }
    if name.contains(" " + wanted) { return MatchScore.wordStart - name.count }
    if initials(text).hasPrefix(wanted) { return MatchScore.initials - name.count }
    if name.contains(wanted) { return MatchScore.substring - name.count }
    var unmatched = Substring(wanted), gaps = 0
    for letter in name {
        guard let next = unmatched.first else { break }
        if letter == next { unmatched.removeFirst() } else if unmatched.count < wanted.count { gaps += 1 }
    }
    return unmatched.isEmpty ? MatchScore.scattered - gaps - name.count : nil
}

private func initials(_ text: String) -> String {
    var result = "", previous: Character = " "
    for char in text {
        let startsWord = !(previous.isLetter || previous.isNumber) || (char.isUppercase && previous.isLowercase)
        if (char.isLetter || char.isNumber) && startsWord { result.append(char) }
        previous = char
    }
    return result.lowercased()
}
