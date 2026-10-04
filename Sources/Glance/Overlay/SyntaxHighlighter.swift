import SwiftUI

/// Token colours for code blocks. Muted on purpose: enough hue to parse the
/// shape of the code at a glance, never louder than the prose around it.
struct SyntaxTheme {
    let plain: Color
    let keyword: Color
    let type: Color
    let string: Color
    let number: Color
    let comment: Color
    let function: Color

    static let dark = SyntaxTheme(
        plain: Color(red: 0xdf/255, green: 0xe4/255, blue: 0xf0/255),
        keyword: Color(red: 0xe8/255, green: 0x9f/255, blue: 0xb4/255),
        type: Color(red: 0x7f/255, green: 0xc8/255, blue: 0xcd/255),
        string: Color(red: 0xa6/255, green: 0xd1/255, blue: 0x8c/255),
        number: Color(red: 0xe6/255, green: 0xb9/255, blue: 0x7a/255),
        comment: Color(red: 0x73/255, green: 0x7b/255, blue: 0x8c/255),
        function: Color(red: 0x8f/255, green: 0xb7/255, blue: 0xf2/255))

    static let light = SyntaxTheme(
        plain: DS.textPrimary,
        keyword: Color(hexRGB: "B03A62")!,
        type: Color(hexRGB: "0E7C86")!,
        string: Color(hexRGB: "3B7D2B")!,
        number: Color(hexRGB: "A15C00")!,
        comment: Color(hexRGB: "8A93A0")!,
        function: Color(hexRGB: "2B63C4")!)
}

/// Small language-agnostic highlighter. It is a single forward scan per line
/// (comments, strings, numbers, identifiers), so it is cheap enough to re-run
/// on every streamed chunk and never throws on half-written code — an
/// unterminated string simply colours to the end of the line.
enum SyntaxHighlighter {

    static func highlight(_ code: String, language: String?, theme: SyntaxTheme,
                          monoSize: CGFloat) -> AttributedString {
        let lang = language?.lowercased()
        let hashComments = lang == nil || hashLanguages.contains(lang!)
        let slashComments = lang == nil || !hashLanguages.contains(lang!)
        let dashComments = lang.map(dashLanguages.contains) ?? false

        var out = AttributedString()
        func emit(_ text: String, _ color: Color, italic: Bool = false) {
            guard !text.isEmpty else { return }
            var run = AttributedString(text)
            run.foregroundColor = color
            if italic { run.font = .system(size: monoSize, design: .monospaced).italic() }
            out.append(run)
        }

        let lines = code.components(separatedBy: "\n")
        for (n, line) in lines.enumerated() {
            if n > 0 { emit("\n", theme.plain) }
            let chars = Array(line)
            var i = 0
            var plainStart = 0
            func flushPlain(upTo end: Int) {
                if end > plainStart { emit(String(chars[plainStart..<end]), theme.plain) }
            }
            func startsWith(_ s: String, at idx: Int) -> Bool {
                let p = Array(s)
                guard idx + p.count <= chars.count else { return false }
                return Array(chars[idx..<idx + p.count]) == p
            }
            let firstNonSpace = chars.firstIndex { $0 != " " && $0 != "\t" }

            while i < chars.count {
                let c = chars[i]

                // Comments run to the end of the line.
                let isHash = c == "#" && hashComments
                    && (lang != nil || i == firstNonSpace)
                let isSlash = slashComments && startsWith("//", at: i)
                let isDash = dashComments && startsWith("--", at: i)
                if isHash || isSlash || isDash {
                    flushPlain(upTo: i)
                    emit(String(chars[i...]), theme.comment, italic: true)
                    i = chars.count; plainStart = i
                    break
                }

                // Strings. A lone apostrophe is usually prose or a lifetime,
                // so single quotes need a closing partner on the same line.
                if c == "\"" || c == "`" || c == "'" {
                    if let end = stringEnd(chars, from: i, quote: c) {
                        flushPlain(upTo: i)
                        emit(String(chars[i..<end]), theme.string)
                        i = end; plainStart = i
                        continue
                    }
                }

                // Numbers (not the tail of an identifier like `v2`).
                if c.isNumber, i == 0 || !isIdentChar(chars[i - 1]) {
                    var j = i
                    while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "_"
                            || chars[j] == "x" { j += 1 }
                    flushPlain(upTo: i)
                    emit(String(chars[i..<j]), theme.number)
                    i = j; plainStart = i
                    continue
                }

                // Identifiers.
                if c.isLetter || c == "_" {
                    var j = i
                    while j < chars.count, isIdentChar(chars[j]) { j += 1 }
                    let word = String(chars[i..<j])
                    var color: Color?
                    if keywords.contains(word) {
                        color = theme.keyword
                    } else if word.first?.isUppercase == true, word.count > 1 {
                        color = theme.type
                    } else if j < chars.count, chars[j] == "(" {
                        color = theme.function
                    }
                    if let color {
                        flushPlain(upTo: i)
                        emit(word, color)
                        plainStart = j
                    }
                    i = j
                    continue
                }

                i += 1
            }
            flushPlain(upTo: chars.count)
        }
        return out
    }

    /// Index just past the closing quote, or nil when a single quote has no
    /// partner. Double quotes and backticks colour to end-of-line while a
    /// string is still streaming in.
    private static func stringEnd(_ chars: [Character], from start: Int, quote: Character) -> Int? {
        var j = start + 1
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == quote { return j + 1 }
            j += 1
        }
        return quote == "'" ? nil : chars.count
    }

    private static func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    private static let hashLanguages: Set<String> = [
        "python", "py", "bash", "sh", "zsh", "shell", "console", "yaml", "yml", "toml", "ruby", "rb",
        "graphql", "gql", "dockerfile", "makefile", "make", "r", "perl", "powershell", "ini", "conf",
        "env", "elixir", "nix"]
    private static let dashLanguages: Set<String> = ["sql", "lua", "haskell", "hs", "elm"]

    private static let keywords: Set<String> = [
        "let", "var", "const", "func", "function", "def", "class", "struct", "enum", "protocol", "interface",
        "type", "typealias", "import", "from", "export", "return", "if", "else", "elif", "for", "while",
        "switch", "case", "break", "continue", "default", "guard", "in", "is", "as", "new", "try", "catch",
        "throw", "throws", "async", "await", "static", "public", "private", "protected", "final", "extends",
        "implements", "true", "false", "nil", "null", "none", "None", "True", "False", "self", "this",
        "fn", "pub", "use", "mod", "impl", "trait", "match", "where", "with", "yield", "lambda", "pass",
        "override", "init", "extension", "some", "any", "do", "defer", "package", "namespace",
        "select", "insert", "update", "delete", "create", "table", "join", "group", "order", "by", "limit",
        "query", "mutation", "subscription", "schema", "input", "scalar", "union", "directive", "fragment",
        "on", "and", "or", "not"]
}
