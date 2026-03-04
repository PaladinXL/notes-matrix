// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotesTransfer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "notes-matrix", targets: ["NotesMatrix"])
    ],
    targets: [
        .executableTarget(
            name: "NotesMatrix",
            path: "Sources/NotesMatrix"
        ),
        .testTarget(
            name: "NotesMatrixTests",
            dependencies: ["NotesMatrix"],
            path: "Tests/NotesMatrixTests"
        )
    ]
)
