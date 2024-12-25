@_implementationOnly import OmFileFormatC
import Foundation


/// This is a wrapper for legay 2D reads using the new multi-dimensional reader
public final class OmFileReader<Backend: OmFileReaderBackend> {
    public let reader: OmFileReader2Array<Backend, Float>
    
    /// The scalefactor that is applied to all write data
    public let scalefactor: Float
    
    /// Type of compression and coding. E.g. delta, zigzag coding is then implemented in different compression routines
    public let compression: CompressionType
    
    /// Number of elements in dimension 0... The slow one
    public let dim0: Int
    
    /// Number of elements in dimension 1... The fast one. E.g. time-series
    public let dim1: Int
    
    /// Number of elements to chunk in dimension 0. Must be lower or equals `chunk0`
    public let chunk0: Int
    
    /// Number of elements to chunk in dimension 1. Must be lower or equals `chunk1`
    public let chunk1: Int
    
    /// Number of elements in this file
    public var count: Int {
        return dim0 * dim1
    }
    
    public init(fn: Backend) throws {
        reader = try OmFileReader2(fn: fn).asArray(of: Float.self)!
        
        let dimensions = reader.getDimensions()
        let chunks = reader.getChunkDimensions()
        
        dim0 = Int(dimensions[0])
        dim1 = Int(dimensions[1])
        chunk0 = Int(chunks[0])
        chunk1 = Int(chunks[1])
        scalefactor = reader.scaleFactor
        compression = reader.compression
    }
    
    /// Prefetch fhe required data regions into memory
    public func willNeed(dim0Slow dim0Read: Range<Int>? = nil, dim1 dim1Read: Range<Int>? = nil) throws {
        guard reader.fn.needsPrefetch else {
            return
        }
        // This function is only used for legacy 2D read functions
        
        let dim0Read = dim0Read ?? 0..<dim0
        let dim1Read = dim1Read ?? 0..<dim1
        
        try withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 2*4) { ptr in
            // read offset
            ptr[0] = UInt64(dim0Read.lowerBound)
            ptr[1] = UInt64(dim1Read.lowerBound)
            // read count
            ptr[2] = UInt64(dim0Read.count)
            ptr[3] = UInt64(dim1Read.count)
            // cube offset
            ptr[4] = 0
            ptr[5] = 0
            // cube dimensions
            ptr[6] = UInt64(dim0Read.count)
            ptr[7] = UInt64(dim1Read.count)
            
            var decoder = OmDecoder_t()
            let error = om_decoder_init(
                &decoder,
                reader.variable,
                2,
                ptr.baseAddress,
                ptr.baseAddress?.advanced(by: 2),
                ptr.baseAddress?.advanced(by: 4),
                ptr.baseAddress?.advanced(by: 6),
                4096, // merge
                65536*4 // io amax
            )
            guard error == ERROR_OK else {
                throw OmFileFormatSwiftError.omDecoder(error: String(cString: om_error_string(error)))
            }
            reader.fn.decodePrefetch(decoder: &decoder)
        }
    }
    
    /// Read data into existing buffers. Can only work with sequential ranges. Reading random offsets, requires external loop.
    ///
    /// This code could be moved to C/Rust for better performance. The 2D delta and scaling code is not yet using vector instructions yet
    /// Future implementations could use async io via lib uring
    ///
    /// `into` is a 2d flat array with `arrayDim1Length` count elements in the fast dimension
    /// `arrayDim1Range` defines the offset in dimension 1 what is applied to the read into array
    /// `arrayDim1Length` if dim0Slow.count is greater than 1, the arrayDim1Length will be used as a stride. Like `nTime` in a 2d fast time array
    /// `dim0Slow` the slow dimension to read. Typically a location range
    /// `dim1Read` the fast dimension to read. Typical a time range
    public func read(into: UnsafeMutablePointer<Float>, arrayDim1Range: Range<Int>, arrayDim1Length: Int, dim0Slow dim0Read: Range<Int>, dim1 dim1Read: Range<Int>) throws {
        
        //assert(arrayDim1Range.count == dim1Read.count)
        
        guard dim0Read.lowerBound >= 0 && dim0Read.lowerBound <= dim0 && dim0Read.upperBound <= dim0 else {
            throw OmFileFormatSwiftError.dimensionOutOfBounds(range: dim0Read, allowed: dim0)
        }
        guard dim1Read.lowerBound >= 0 && dim1Read.lowerBound <= dim1 && dim1Read.upperBound <= dim1 else {
            throw OmFileFormatSwiftError.dimensionOutOfBounds(range: dim1Read, allowed: dim1)
        }
        
        // This function is only used for legacy 2D read functions
        
        try withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 2*4) { ptr in
            // read offset
            ptr[0] = UInt64(dim0Read.lowerBound)
            ptr[1] = UInt64(dim1Read.lowerBound)
            // read count
            ptr[2] = UInt64(dim0Read.count)
            ptr[3] = UInt64(dim1Read.count)
            // cube offset
            ptr[4] = 0
            ptr[5] = UInt64(arrayDim1Range.lowerBound)
            // cube dimensions
            ptr[6] = UInt64(dim0Read.count)
            ptr[7] = UInt64(arrayDim1Length)
            
            var decoder = OmDecoder_t()
            let error = om_decoder_init(
                &decoder,
                reader.variable,
                2,
                ptr.baseAddress,
                ptr.baseAddress?.advanced(by: 2),
                ptr.baseAddress?.advanced(by: 4),
                ptr.baseAddress?.advanced(by: 6),
                4096, // merge
                65536*4 // io amax
            )
            guard error == ERROR_OK else {
                throw OmFileFormatSwiftError.omDecoder(error: String(cString: om_error_string(error)))
            }
            try reader.fn.decode(decoder: &decoder, into: into)
        }
    }
    
    /// Read data. This version is a bit slower, because it is allocating the output buffer
    public func read(dim0Slow dim0Read: Range<Int>?, dim1 dim1Read: Range<Int>?) throws -> [Float] {
        let dim0Read = dim0Read ?? 0..<dim0
        let dim1Read = dim1Read ?? 0..<dim1
        let count = dim0Read.count * dim1Read.count
        return try [Float](unsafeUninitializedCapacity: count, initializingWith: {ptr, countRead in
            try read(into: ptr.baseAddress!, arrayDim1Range: 0..<dim1Read.count, arrayDim1Length: dim1Read.count, dim0Slow: dim0Read, dim1: dim1Read)
            countRead += count
        })
    }
    
    public func readAll() throws -> [Float] {
        reader.fn.prefetchData(offset: 0, count: reader.fn.count)
        return try read(dim0Slow: 0..<dim0, dim1: 0..<dim1)
    }
    
    /// Read interpolated between 4 points. Assuming dim0 is used for lcations and dim1 is a time series
    public func readInterpolated(dim0X: Int, dim0XFraction: Float, dim0Y: Int, dim0YFraction: Float, dim0Nx: Int, dim1 dim1Read: Range<Int>) throws -> [Float] {
        
        // bound x and y
        var dim0X = dim0X
        var dim0XFraction = dim0XFraction
        if dim0X > dim0Nx-2 {
            dim0X = dim0Nx-2
            dim0XFraction = 1
        }
        var dim0Y = dim0Y
        var dim0YFraction = dim0YFraction
        let dim0Ny = dim0 / dim0Nx
        if dim0Y > dim0Ny-2 {
            dim0Y = dim0Ny-2
            dim0YFraction = 1
        }
        
        // reads 4 points. As 2 points are next to each other, we can read a small row of 2 elements at once
        let top = try read(dim0Slow: dim0Y * dim0Nx + dim0X ..< dim0Y * dim0Nx + dim0X + 2, dim1: dim1Read)
        let bottom = try read(dim0Slow: (dim0Y + 1) * dim0Nx + dim0X ..< (dim0Y + 1) * dim0Nx + dim0X + 2, dim1: dim1Read)
        
        // interpolate linearly between
        let nt = dim1Read.count
        return zip(zip(top[0..<nt], top[nt..<2*nt]), zip(bottom[0..<nt], bottom[nt..<2*nt])).map {
            let ((a,b),(c,d)) = $0
            return  a * (1-dim0XFraction) * (1-dim0YFraction) +
                    b * (dim0XFraction) * (1-dim0YFraction) +
                    c * (1-dim0XFraction) * (dim0YFraction) +
                    d * (dim0XFraction) * (dim0YFraction)
        }
    }
    
    /// Read interpolated between 4 points. Assuming dim0 and dim1 are a spatial field
    public func readInterpolated(dim0: Int, dim0Fraction: Float, dim1: Int, dim1Fraction: Float) throws -> Float {
        // bound x and y
        var dim0 = dim0
        var dim0Fraction = dim0Fraction
        if dim0 > self.dim0-2 {
            dim0 = self.dim0-2
            dim0Fraction = 1
        }
        var dim1 = dim1
        var dim1Fraction = dim1Fraction
        if dim1 > self.dim1-2 {
            dim1 = self.dim1-2
            dim1Fraction = 1
        }
        
        // reads 4 points at once
        let points = try read(dim0Slow: dim0 ..< dim0 + 2, dim1: dim1 ..< dim1 + 2)
        
        // interpolate linearly between
        return points[0] * (1-dim0Fraction) * (1-dim1Fraction) +
               points[1] * (dim0Fraction) * (1-dim1Fraction) +
               points[2] * (1-dim0Fraction) * (dim1Fraction) +
               points[3] * (dim0Fraction) * (dim1Fraction)
    }
}

extension Range where Element == Int {
    /// Divide lower and upper bound. For upper bound use `divideRoundedUp`
    func divide(by: Int) -> Range<Int> {
        return lowerBound / by ..< upperBound.divideRoundedUp(divisor: by)
    }
}

extension OmFileReader where Backend == MmapFile {
    public convenience init(file: String) throws {
        let fn = try FileHandle.openFileReading(file: file)
        try self.init(fn: fn)
    }
    
    public convenience init(fn: FileHandle) throws {
        let mmap = try MmapFile(fn: fn)
        try self.init(fn: mmap)
    }
    
    /// Check if the file was deleted on the file system. Linux keep the file alive, as long as some processes have it open.
    public func wasDeleted() -> Bool {
        reader.fn.wasDeleted()
    }
}
