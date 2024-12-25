@_implementationOnly import OmFileFormatC
import Foundation


public enum OmFileFormatSwiftError: Error {
    case cannotOpenFile(filename: String, errno: Int32, error: String)
    case cannotCreateFile(filename: String, errno: Int32, error: String)
    case cannotTruncateFile(filename: String, errno: Int32, error: String)
    case cannotOpenFile(errno: Int32, error: String)
    case cannotMoveFile(from: String, to: String, errno: Int32, error: String)
    case chunkHasWrongNumberOfElements
    case dimensionOutOfBounds(range: Range<Int>, allowed: Int)
    case chunkDimensionIsSmallerThenOverallDim
    case dimensionMustBeLargerThan0
    case notAOmFile
    case fileExistsAlready(filename: String)
    case posixFallocateFailed(error: Int32)
    case ftruncateFailed(error: Int32)
    case omDecoder(error: String)
    case omEncoder(error: String)
    case notAnOpenMeteoFile
}


public enum DataType: UInt8, Codable {
    case none = 0
    case int8 = 1
    case uint8 = 2
    case int16 = 3
    case uint16 = 4
    case int32 = 5
    case uint32 = 6
    case int64 = 7
    case uint64 = 8
    case float = 9
    case double = 10
    case string = 11
    case int8_array = 12
    case uint8_array = 13
    case int16_array = 14
    case uint16_array = 15
    case int32_array = 16
    case uint32_array = 17
    case int64_array = 18
    case uint64_array = 19
    case float_array = 20
    case double_array = 21
    case string_array = 22
    
    func toC() -> OmDataType_t {
        return OmDataType_t(rawValue: UInt32(self.rawValue))
    }
}

public enum CompressionType: UInt8, Codable {
    /// Lossy compression using 2D delta coding and scalefactor. Only support float ad scaled to 16 bit integer
    /// TODO rename to `pfor_16bit_delta2d`
    case p4nzdec256 = 0
    
    /// Lossless compression using 2D xor coding
    /// /// TODO rename to `fpx_xor2d`
    case fpxdec32 = 1
    
    ///  Similar to `p4nzdec256` but apply `log10(1+x)` before
    ///  /// TODO rename to `pfor_16bit_delta2d_logarithmic`
    case p4nzdec256logarithmic = 3
    
    // TODO: Use a new compression type to properly implement data type switching. Deprecate the old one
    //case pforNEW
    
    public var bytesPerElement: Int {
        switch self {
        case .p4nzdec256:
            fallthrough
        case .p4nzdec256logarithmic:
            return 2
        case .fpxdec32:
            return 4
        }
    }
    
    func toC() -> OmCompression_t {
        switch self {
        case .p4nzdec256:
            return COMPRESSION_PFOR_16BIT_DELTA2D
        case .fpxdec32:
            return COMPRESSION_FPX_XOR2D
        case .p4nzdec256logarithmic:
            return COMPRESSION_PFOR_16BIT_DELTA2D_LOGARITHMIC
        }
    }
}


