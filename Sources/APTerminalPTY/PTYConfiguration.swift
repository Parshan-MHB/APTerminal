import Darwin
import Foundation

public enum PTYConfiguration {
    public static let defaultTerminationGracePeriodSeconds: TimeInterval = 1
    public static let defaultTerminationKillTimeoutSeconds: TimeInterval = 2
    public static let defaultReadRetrySleepMicroseconds: useconds_t = 50_000
}
