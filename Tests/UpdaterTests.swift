import Foundation

@main
enum UpdaterTests {
    static func main() {
        newerVersionsWin()
        olderAndEqualVersionsLose()
        mixedComponentCounts()
        print("Updater tests passed")
    }

    private static func newerVersionsWin() {
        require(Updater.isNewer("1.6", than: "1.5"), "1.6 > 1.5")
        require(Updater.isNewer("2.0", than: "1.9"), "2.0 > 1.9")
        require(Updater.isNewer("1.10", than: "1.9"), "1.10 > 1.9 (numeric, not lexicographic)")
        require(Updater.isNewer("1.5.1", than: "1.5"), "1.5.1 > 1.5")
    }

    private static func olderAndEqualVersionsLose() {
        require(!Updater.isNewer("1.5", than: "1.5"), "equal versions are not newer")
        require(!Updater.isNewer("1.4", than: "1.5"), "1.4 < 1.5")
        require(!Updater.isNewer("1.5", than: "1.5.0"), "1.5 == 1.5.0")
        require(!Updater.isNewer("0.9", than: "1.0"), "0.9 < 1.0")
    }

    private static func mixedComponentCounts() {
        require(Updater.isNewer("1.5.0.1", than: "1.5"), "extra nonzero component wins")
        require(!Updater.isNewer("1.5", than: "1.5.0.1"), "…and loses in reverse")
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAILED: \(message)")
            exit(1)
        }
    }
}
