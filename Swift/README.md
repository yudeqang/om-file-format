# Using Om-Files in Swift

## Installation
Add `OmFileFormat` as a dependency to your `Package.swift`. Note: Unsafe compiler flags are required for SIMD instructions and this does not work if semantic versioning is used. Therefore, the git revision needs to be specified manually.

```swift
  dependencies: [
    .package(url: "https://github.com/open-meteo/om-file-format.git", revision: "7c9a3f7a0a546fab8091b84720fc95e5ce37cdb2")
  ],
  targets: [
    .target(name: "MyApp", dependencies: [.product(name: "OmFileFormat", package: "om-file-format")])
  ]
```

