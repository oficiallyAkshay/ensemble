@_exported import Foundation

#if os(Windows)
// Windows has no pid_t; the core's agent adapter protocol uses a plain 32-bit integer for process ids.
public typealias pid_t = Int32
#endif
