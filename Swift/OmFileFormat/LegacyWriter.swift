@_implementationOnly import OmFileFormatC
import Foundation


/// Write an om file and write multiple chunks of data
public final class OmFileWriterState<Backend: OmFileWriterBackend> {
    public let fn: Backend
    
    public let dim0: Int
    public let dim1: Int
    
    public let chunk0: Int
    public let chunk1: Int
    
    public let compression: CompressionType
    public let scalefactor: Float
    
    /// Buffer where chunks are moved to, before compression them. => input for compression call
    private var readBuffer: UnsafeMutableRawBufferPointer
    
    /// Compressed chunks are written into this buffer
    /// 1 MB write buffer or larger if chunks are very large
    private var writeBuffer: UnsafeMutableBufferPointer<UInt8>
    
    public var bytesWrittenSinceLastFlush = 0
    
    public var writeBufferPos = 0
    
    /// Number of bytes after data should be flushed with fsync
    private let fsyncFlushSize: Int?
    
    /// Position of last chunk that has been written
    public var c0: Int = 0
    
    public var nDim0Chunks: Int {
        dim0.divideRoundedUp(divisor: chunk0)
    }
    
    public var nDim1Chunks: Int {
        dim1.divideRoundedUp(divisor: chunk1)
    }
    
    public var nChunks: Int {
        nDim0Chunks * nDim1Chunks
    }
    
    /// Store all byte offsets where our compressed chunks start. Later, we want to decompress chunk 1234 and know it starts at byte offset 5346545
    public var chunkOffsetBytes = [Int]()
    
    /**
     Write new or overwrite new compressed file. Data must be supplied with a closure which supplies the current position in dimension 0. Typically this is the location offset. The closure must return either an even number of elements of `chunk0 * dim1` elements or all remaining elements at once.
     
     One chunk should be around 2'000 to 16'000 elements. Fewer or more are not useful!
     
     Note: `chunk0` can be a uneven multiple of `dim0`. E.g. for 10 location, we can use chunks of 3, so the last chunk will only cover 1 location.
     */
    public init(fn: Backend, dim0: Int, dim1: Int, chunk0: Int, chunk1: Int, compression: CompressionType, scalefactor: Float, fsync: Bool) throws {
        self.fn = fn
        self.dim0 = dim0
        self.dim1 = dim1
        self.chunk0 = chunk0
        self.chunk1 = chunk1
        self.compression = compression
        self.scalefactor = scalefactor
        self.fsyncFlushSize = fsync ? 32 * 1024 * 1024 : nil
        
        guard chunk0 > 0 && chunk1 > 0 && dim0 > 0 && dim1 > 0 else {
            throw OmFileFormatSwiftError.dimensionMustBeLargerThan0
        }
        guard chunk0 <= dim0 && chunk1 <= dim1 else {
            throw OmFileFormatSwiftError.chunkDimensionIsSmallerThenOverallDim
        }
        
        let chunkSizeByte = chunk0 * chunk1 * 4
        if chunkSizeByte > 1024 * 1024 * 4 {
            print("WARNING: Chunk size greater than 4 MB (\(Float(chunkSizeByte) / 1024 / 1024) MB)!")
        }

        let bufferSize = P4NENC256_BOUND(n: chunk0*chunk1, bytesPerElement: 4)
        
        // Read buffer needs to be a bit larger for AVX 256 bit alignment
        self.readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 4)
        self.writeBuffer = .allocate(capacity: max(1024 * 1024, bufferSize))
        
        chunkOffsetBytes.reserveCapacity(nChunks)
    }
    
    deinit {
        readBuffer.deallocate()
        writeBuffer.deallocate()
    }
    
    public func writeHeader() throws {
        /// Create header and write to file
        let header = OmHeader(
            compression: compression.rawValue,
            scalefactor: scalefactor,
            dim0: dim0,
            dim1: dim1,
            chunk0: chunk0,
            chunk1: chunk1)
        
        try withUnsafeBytes(of: header) { ptr in
            assert(ptr.count == OmHeader.length)
            try fn.write(contentsOf: ptr)
        }
        
        /// reserve space for chunk offsets
        try fn.write(contentsOf: Data(repeating: 0, count: nChunks * MemoryLayout<Int>.size))
    }
    
    public func writeTail() throws {
        // Write remainind data from buffer
        try fn.write(contentsOf: UnsafeBufferPointer(start: writeBuffer.baseAddress, count: writeBufferPos))
        
        //print("avg chunk size bytes", (chunkOffsetBytes.last ?? 0) / (nDim0Chunks*nDim1Chunks))
        
        // write trailing byte to allow the encoder to read with 256 bit alignment
        let trailingBytes = P4NDEC256_BOUND(n: 0, bytesPerElement: 4)
        try fn.write(contentsOf: Data(repeating: 0, count: trailingBytes))
        
        // write dictionary
        try chunkOffsetBytes.withUnsafeBufferPointer { ptr in
            try fn.write(contentsOf: ptr.toUnsafeRawBufferPointer(), atOffset: OmHeader.length)
        }
        
        if fsyncFlushSize != nil {
            // ensure data is written to disk
            try fn.synchronize()
        }
    }
    
    public func write(_ uncompressedInput: ArraySlice<Float>) throws {
        switch compression {
        case .p4nzdec256:
            fallthrough
        case .p4nzdec256logarithmic:
            let buffer = readBuffer.baseAddress!.assumingMemoryBound(to: Int16.self)
            // Make sure that we received an even number of `c0 * chunk0` or all remaining elements at once. The last chunk might be smaller than `c0 * chunk0`
            /// Number of elements in a row of chunks. Not just one chunk.
            let elementsPerChunkRow = chunk0 * dim1
            let missingElements = dim0 * dim1 - c0 * elementsPerChunkRow
            if missingElements < elementsPerChunkRow {
                // For the last chunk, the number must match exactly
                guard uncompressedInput.count == missingElements else {
                    throw OmFileFormatSwiftError.chunkHasWrongNumberOfElements
                }
            }
            let isEvenMultipleOfChunkSize = uncompressedInput.count % elementsPerChunkRow == 0
            guard isEvenMultipleOfChunkSize || uncompressedInput.count == missingElements else {
                throw OmFileFormatSwiftError.chunkHasWrongNumberOfElements
            }
            
            let nReadChunks = uncompressedInput.count.divideRoundedUp(divisor: elementsPerChunkRow)
            
            for c00 in 0..<nReadChunks {
                let length0 = min((c0+c00+1) * chunk0, dim0) - (c0+c00) * chunk0
                
                for c1 in 0..<nDim1Chunks {
                    // load chunk into buffer
                    // consider the length, even if the last is only partial... E.g. at 1000 elements with 600 chunk length, the last one is only 400
                    let length1 = min((c1+1) * chunk1, dim1) - c1 * chunk1
                    for d0 in 0..<length0 {
                        let start = c1 * chunk1 + d0 * dim1 + c00*elementsPerChunkRow + uncompressedInput.startIndex
                        let rangeBuffer = d0*length1 ..< (d0+1)*length1
                        let rangeInput = start ..< start + length1
                        for (posBuffer, posInput) in zip(rangeBuffer, rangeInput) {
                            let val = uncompressedInput[posInput]
                            if val.isNaN {
                                // Int16.min is not representable because of zigzag coding
                                buffer[posBuffer] = Int16.max
                            }
                            let scaled = compression == .p4nzdec256logarithmic ? (log10(1+val) * scalefactor) : (val * scalefactor)
                            buffer[posBuffer] = Int16(max(Float(Int16.min), min(Float(Int16.max), round(scaled))))
                        }
                    }
                    
                    // 2D delta encoding
                    delta2d_encode(length0, length1, buffer)
                    
                    let writeLength = p4nzenc128v16(buffer, length1 * length0, writeBuffer.baseAddress?.advanced(by: writeBufferPos))
                    
                    /// If the write buffer is too full, write it to disk. Too full means, that the next compressed chunk may not fit inside
                    writeBufferPos += writeLength
                    if (writeBuffer.count - writeBufferPos) < readBuffer.count {
                        try fn.write(contentsOf: UnsafeBufferPointer(start: writeBuffer.baseAddress, count: writeBufferPos))
                        if let fsyncFlushSize {
                            bytesWrittenSinceLastFlush += writeBufferPos
                            if bytesWrittenSinceLastFlush >= fsyncFlushSize {
                                // Make sure to write to disk, otherwise we get a lot of dirty pages and overload kernel page cache
                                try fn.synchronize()
                                bytesWrittenSinceLastFlush = 0
                            }
                        }
                        writeBufferPos = 0
                    }
                    
                    // Store chunk offset position in our lookup table
                    let previous = chunkOffsetBytes.last ?? 0
                    chunkOffsetBytes.append(previous + writeLength)
                }
            }
            c0 += nReadChunks
        case .fpxdec32:
            let bufferFloat = readBuffer.baseAddress!.assumingMemoryBound(to: Float.self)
            let buffer = readBuffer.baseAddress!.assumingMemoryBound(to: UInt32.self)
            
            // Make sure that we received an even number of `c0 * chunk0` or all remaining elements at once. The last chunk might be smaller than `c0 * chunk0`
            /// Number of elements in a row of chunks. Not just one chunk.
            let elementsPerChunkRow = chunk0 * dim1
            let missingElements = dim0 * dim1 - c0 * elementsPerChunkRow
            if missingElements < elementsPerChunkRow {
                // For the last chunk, the number must match exactly
                guard uncompressedInput.count == missingElements else {
                    throw OmFileFormatSwiftError.chunkHasWrongNumberOfElements
                }
            }
            let isEvenMultipleOfChunkSize = uncompressedInput.count % elementsPerChunkRow == 0
            guard isEvenMultipleOfChunkSize || uncompressedInput.count == missingElements else {
                throw OmFileFormatSwiftError.chunkHasWrongNumberOfElements
            }
            
            let nReadChunks = uncompressedInput.count.divideRoundedUp(divisor: elementsPerChunkRow)
            
            for c00 in 0..<nReadChunks {
                let length0 = min((c0+c00+1) * chunk0, dim0) - (c0+c00) * chunk0
                
                for c1 in 0..<nDim1Chunks {
                    // load chunk into buffer
                    // consider the length, even if the last is only partial... E.g. at 1000 elements with 600 chunk length, the last one is only 400
                    let length1 = min((c1+1) * chunk1, dim1) - c1 * chunk1
                    for d0 in 0..<length0 {
                        let start = c1 * chunk1 + d0 * dim1 + c00*elementsPerChunkRow + uncompressedInput.startIndex
                        let rangeBuffer = d0*length1 ..< (d0+1)*length1
                        let rangeInput = start ..< start + length1
                        for (posBuffer, posInput) in zip(rangeBuffer, rangeInput) {
                            let val = uncompressedInput[posInput]
                            bufferFloat[posBuffer] = val
                        }
                    }
                    
                    // 2D xor encoding
                    delta2d_encode_xor(length0, length1, bufferFloat)
                    
                    let writeLength = fpxenc32(buffer, length1 * length0, writeBuffer.baseAddress?.advanced(by: writeBufferPos), 0)
                    
                    /// If the write buffer is too full, write it to disk. Too full means, that the next compressed chunk may not fit inside
                    writeBufferPos += writeLength
                    if (writeBuffer.count - writeBufferPos) < readBuffer.count {
                        try fn.write(contentsOf: UnsafeBufferPointer(start: writeBuffer.baseAddress, count: writeBufferPos))
                        if let fsyncFlushSize {
                            bytesWrittenSinceLastFlush += writeBufferPos
                            if bytesWrittenSinceLastFlush >= fsyncFlushSize {
                                // Make sure to write to disk, otherwise we get a lot of dirty pages and overload kernel page cache
                                try fn.synchronize()
                                bytesWrittenSinceLastFlush = 0
                            }
                        }
                        writeBufferPos = 0
                    }
                    
                    // Store chunk offset position in our lookup table
                    let previous = chunkOffsetBytes.last ?? 0
                    chunkOffsetBytes.append(previous + writeLength)
                }
            }
            c0 += nReadChunks
        }
    }
}


/**
 Writer header:
 - 2 byte magic number
 - 1 byte version
 - 1 byte compression type with filter
 - 4 byte float scalefactor
 - 8 byte dim0 dim (slow)
 - 8 byte dom0 dim1 (fast)
 - 8 byte chunk dim0
 - 8 byte chunk dim1
 - Reserve space for reference table
 - Data block
 */
public final class OmFileWriter {
    public let dim0: Int
    public let dim1: Int
    
    public let chunk0: Int
    public let chunk1: Int
    
    public init(dim0: Int, dim1: Int, chunk0: Int, chunk1: Int) {
        self.dim0 = dim0
        self.dim1 = dim1
        self.chunk0 = chunk0
        self.chunk1 = chunk1
    }
    
    /**
     Write new or overwrite new compressed file. Data must be supplied with a closure which supplies the current position in dimension 0. Typically this is the location offset. The closure must return either an even number of elements of `chunk0 * dim1` elements or all remaining elements at once.
     
     One chunk should be around 2'000 to 16'000 elements. Fewer or more are not useful!
     
     If `fsync` is true, data will be flushed every 32MB
     
     Note: `chunk0` can be a uneven multiple of `dim0`. E.g. for 10 location, we can use chunks of 3, so the last chunk will only cover 1 location.
     */
    public func write<Backend: OmFileWriterBackend>(fn: Backend, compressionType: CompressionType, scalefactor: Float, fsync: Bool, supplyChunk: (_ dim0Offset: Int) throws -> ArraySlice<Float>) throws {
        
        let state = try OmFileWriterState<Backend>(fn: fn, dim0: dim0, dim1: dim1, chunk0: chunk0, chunk1: chunk1, compression: compressionType, scalefactor: scalefactor, fsync: fsync)
        
        try state.writeHeader()
        while state.c0 < state.nDim0Chunks {
            let uncompressedInput = try supplyChunk(state.c0 * state.chunk0)
            try state.write(uncompressedInput)
        }
        try state.writeTail()
    }
    
    /// Write new file. Throw error is file exists
    /// Uses a temporary file and then atomic move
    /// If `overwrite` is set, overwrite existing files atomically
    @discardableResult
    public func write(file: String, compressionType: CompressionType, scalefactor: Float, overwrite: Bool, supplyChunk: (_ dim0Offset: Int) throws -> ArraySlice<Float>) throws -> FileHandle {
        if !overwrite && FileManager.default.fileExists(atPath: file) {
            throw OmFileFormatSwiftError.fileExistsAlready(filename: file)
        }
        let fileTemp = "\(file)~"
        try FileManager.default.removeItemIfExists(at: fileTemp)
        let fn = try FileHandle.createNewFile(file: fileTemp)
        try write(fn: fn, compressionType: compressionType, scalefactor: scalefactor, fsync: true, supplyChunk: supplyChunk)
        try FileManager.default.moveFileOverwrite(from: fileTemp, to: file)
        return fn
    }
    
    //public func write(file: String, compressionType: CompressionType, scalefactor: Float, readers: [OmFileR]) throws {
        
    //}
    
    /// Write to memory
    public func writeInMemory(compressionType: CompressionType, scalefactor: Float, supplyChunk: (_ dim0Offset: Int) throws -> ArraySlice<Float>) throws -> Data {
        let data = DataAsClass(data: Data())
        try write(fn: data, compressionType: compressionType, scalefactor: scalefactor, fsync: true, supplyChunk: supplyChunk)
        return data.data
    }
    
    /// Write all data at once without any streaming
    public func writeInMemory(compressionType: CompressionType, scalefactor: Float, all: [Float]) throws -> Data {
        return try writeInMemory(compressionType: compressionType, scalefactor: scalefactor, supplyChunk: { range in
            return ArraySlice(all)
        })
    }
    
    /// Write all data at once without any streaming
    /// If `overwrite` is set, overwrite existing files atomically
    @discardableResult
    public func write(file: String, compressionType: CompressionType, scalefactor: Float, all: [Float], overwrite: Bool = false) throws -> FileHandle {
        try write(file: file, compressionType: compressionType, scalefactor: scalefactor, overwrite: overwrite, supplyChunk: { range in
            return ArraySlice(all)
        })
    }
}


fileprivate struct OmHeader {
    /// Magic number for the file header
    let magicNumber1: UInt8 = Self.magicNumber1
    
    /// Magic number for the file header
    let magicNumber2: UInt8 = Self.magicNumber2
    
    /// Version. Version 1 was setting compression type incorrectly. Version 2 just fixes compression type.
    let version: UInt8 = Self.version
    
    /// Type of compression and coding. E.g. delta, zigzag coding is then implemented in different compression routines
    let compression: UInt8
    
    /// The scalefactor that is applied to all write data
    let scalefactor: Float
    
    /// Number of elements in dimension 0... The slow one
    let dim0: Int
    
    /// Number of elements in dimension 1... The fast one. E.g. time-series
    let dim1: Int
    
    /// Number of elements to chunk in dimension 0. Must be lower or equals `chunk0`
    let chunk0: Int
    
    /// Number of elements to chunk in dimension 1. Must be lower or equals `chunk1`
    let chunk1: Int
    
    /// OM header
    static var magicNumber1: UInt8 = 79
    
    /// OM header
    static var magicNumber2: UInt8 = 77
    
    /// Default version
    static var version: UInt8 = 2
    
    /// Size in bytes of the header
    static var length: Int { 40 }
}
