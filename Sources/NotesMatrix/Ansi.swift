import Foundation

enum ANSI {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let inverse = "\u{001B}[7m"
    static let green = "\u{001B}[32m"
    static let brightGreen = "\u{001B}[92m"
    static let brightCyan = "\u{001B}[96m"
    static let cyan = "\u{001B}[36m"
    static let yellow = "\u{001B}[33m"
    static let dim = "\u{001B}[2m"
    static let clear = "\u{001B}[2J\u{001B}[H"

    static func paint(_ text: String, _ color: String) -> String {
        "\(color)\(text)\(reset)"
    }

    static func fg256(_ code: Int) -> String {
        "\u{001B}[38;5;\(code)m"
    }

    static func fgRGB(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\u{001B}[38;2;\(r);\(g);\(b)m"
    }
}

func printMatrixHeader() {
    let lines = [
        " _   _       _              __  __       _        _",
        "| \\ | | ___ | |_ ___  ___  |  \\/  | __ _| |_ _ __(_)_  __",
        "|  \\| |/ _ \\| __/ _ \\/ __| | |\\/| |/ _` | __| '__| \\ \\/ /",
        "| |\\  | (_) | ||  __/\\__ \\ | |  | | (_| | |_| |  | |>  <",
        "|_| \\_|\\___/ \\__\\___||___/ |_|  |_|\\__,_|\\__|_|  |_/_/\\_\\"
    ]

    // 256-color gradient is more portable across terminals than truecolor.
    let gradient256 = [120, 121, 122, 87, 51]

    for (i, line) in lines.enumerated() {
        let code = gradient256[min(i, gradient256.count - 1)]
        print("\(ANSI.fg256(code))\(line)\(ANSI.reset)")
    }

    print(ANSI.paint("apple notes -> markdown exporter", ANSI.fg256(120)))
}

func clearScreen() {
    print(ANSI.clear, terminator: "")
}
