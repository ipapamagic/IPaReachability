//
//  IPaReachability.swift
//  Pods
//
//  Created by IPa Chen on 2017/8/24.
//
//

import SystemConfiguration
import Foundation
import IPaLog

func reachabilityCallback(_ reachability:SCNetworkReachability, flags: SCNetworkReachabilityFlags, info: UnsafeMutableRawPointer?) {
    
    guard let info = info else { return }
    
    let reachability = Unmanaged<IPaReachability>.fromOpaque(info).takeUnretainedValue()
    NotificationCenter.default.post(name: NSNotification.Name(rawValue: IPaReachability.kIPaReachabilityChangedNotification), object: reachability)
   
}
@objc open class IPaReachability: NSObject {
    
    public enum IPaNetworkStatus:Int {
        case notReachable = 0
        case reachableByWifi
        case reachableByWWan
        case unknown
    }
    fileprivate var isRunning = false
    fileprivate var isLocalWiFi = false
    fileprivate var reachability: SCNetworkReachability?
    open var connectionRequired: Bool
    {
        get {
            guard let reachability = reachability else {
                return true
            }
            var flags = SCNetworkReachabilityFlags()
            if SCNetworkReachabilityGetFlags(reachability, &flags) {
                return flags.contains(.connectionRequired)
            }
            return false
        }
    }
    open var isNotReachable:Bool {
        get {
            return currentStatus == .notReachable
        }
    }
    open var currentStatus:IPaNetworkStatus {
        get {
            guard let reachability = reachability else {
                return .unknown
            }
            var retVal = IPaNetworkStatus.notReachable
            var flags = SCNetworkReachabilityFlags()
            if SCNetworkReachabilityGetFlags(reachability, &flags) {
                if isLocalWiFi {
                    retVal = self.localWifiStatus(for:flags)
                }
                else {
                    retVal = self.networkStatus(for:flags)
                }
            }
            return retVal
        }
    }
    public class var kIPaReachabilityChangedNotification:String {
        return "ReachabilityChangedNotification"
    }
    
    fileprivate init(reachability: SCNetworkReachability) {
        super.init()
        self.reachability = reachability
        
    }
    fileprivate func printReachability(flags:SCNetworkReachabilityFlags, comment:String)
    {
        IPaLog("Reachability Flag Status:%c%c %c%c%c%c%c%c%c %s\n", args: flags.contains(.isWWAN) ? "W" : "-",
            flags.contains(.reachable) ? "R" : "-",
            flags.contains(.transientConnection) ? "t" : "-",
            flags.contains(.connectionRequired) ? "c" : "-",
            flags.contains(.connectionOnTraffic) ? "C" : "-",
            flags.contains(.interventionRequired) ? "i" : "-",
            flags.contains(.connectionOnDemand) ? "D" : "-",
            flags.contains(.isLocalAddress) ? "l" : "-",
            flags.contains(.isDirect) ? "d" : "-",comment)
    
    }
    open func startNotifier() -> Bool
    {
        guard let reachability = reachability, !isRunning else {
            return false
        }
        var retVal = false
        var context = SCNetworkReachabilityContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = UnsafeMutableRawPointer(Unmanaged<IPaReachability>.passUnretained(self).toOpaque())
        
        if(SCNetworkReachabilitySetCallback(reachability, reachabilityCallback, &context))
        {
            
            if(SCNetworkReachabilityScheduleWithRunLoop(reachability, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue))
            {
                retVal = true
            }
        }
        return retVal;
    }
    open func stopNotifier()
    {
        defer {
            isRunning = false
        }
        guard let reachability = reachability else {
            return
        }
        SCNetworkReachabilitySetCallback(reachability, nil, nil)

        SCNetworkReachabilityUnscheduleFromRunLoop(reachability, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue);
    }
    deinit {
        self.stopNotifier()
        
    }

    open static func reachability(hostName:String) -> IPaReachability?
    {
        guard let reachablilty = SCNetworkReachabilityCreateWithName(nil, (hostName as NSString).utf8String!) else {
            return nil
        }
        let ipaRechability = IPaReachability(reachability: reachablilty)
        ipaRechability.isLocalWiFi = false
        return ipaRechability
    }
    open static func reachability(hostAddress:UnsafePointer<sockaddr_in>) -> IPaReachability?
    {
        
        guard let reachability = hostAddress.withMemoryRebound(to: sockaddr.self, capacity: 1, {
            sockAddress in
            return SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, sockAddress)
        }) else {
            return nil
        }
        let ipaRechability = IPaReachability(reachability: reachability)
        ipaRechability.isLocalWiFi = false
        return ipaRechability
    }
    open static func  reachabilityForInternetConnection() -> IPaReachability?
    {
        var address: sockaddr_in = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout.size(ofValue: address))
        address.sin_family = sa_family_t(AF_INET)
        let reachability = self.reachability(hostAddress: &address)
        reachability?.isLocalWiFi = false
        return reachability
    }
    open static func reachabilityForLocalWiFi() -> IPaReachability?
    {
        var address: sockaddr_in = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout.size(ofValue: address))
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = CFSwapInt32HostToBig(IN_LINKLOCALNETNUM)
        let reachability = self.reachability(hostAddress: &address)
        reachability?.isLocalWiFi = true
        return reachability
    }
    //MARK: Network Flag Handling
    open func localWifiStatus(for flags:SCNetworkReachabilityFlags) -> IPaNetworkStatus
    {
        printReachability(flags: flags, comment: "localWifiStatus")
        var retVal = IPaNetworkStatus.notReachable
        if flags.contains(.reachable) && flags.contains(.isDirect) {
            retVal = .reachableByWifi
        }
        return retVal
    }
    open func networkStatus(for flags:SCNetworkReachabilityFlags) -> IPaNetworkStatus
    {
        printReachability(flags: flags, comment: "networkStatus")
        
        if !flags.contains(.reachable) {
            return .notReachable
        }
        var retVal = IPaNetworkStatus.notReachable
        if !flags.contains(.connectionRequired) {
            retVal = .reachableByWifi
        }
        if flags.contains(.connectionOnDemand) || flags.contains(.connectionOnTraffic) {
            if !flags.contains(.interventionRequired) {
                retVal = .reachableByWifi
            }
        }
        if flags.contains(.isWWAN) {
            retVal = .reachableByWWan
        }
        return retVal
    }

}
