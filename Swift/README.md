# Using Om-Files in Swift

## Installation
Add `OmFileFormat` as a dependency to your `Package.swift`. Note: Unsafe compiler flags are required for SIMD instructions and this does not work if semantic versioning is used. Therefore, the git revision needs to be specified manually.

```swift
  dependencies: [
    .package(url: "https://github.com/open-meteo/om-file-format.git", revision: "63b93c313dc5d29893f3aabccd616c3047b3fa87")
  ],
  targets: [
    .target(name: "MyApp", dependencies: [.product(name: "OmFileFormat", package: "om-file-format")])
  ]
```

# Reading files

Assuming the file `data.om` directly contains a floating point array with 3 dimensions

```
import OmFileFormat

let file = "data.om"
let fn = try FileHandle.openFileReading(file: file)
let mmap = try MmapFile(fn: fn)
let read = try OmFileReader2(fn: mmap).asArray(of: Float.self)!

let data = try read.read(range: [50..<51, 20..<21, 10..<200])
```
