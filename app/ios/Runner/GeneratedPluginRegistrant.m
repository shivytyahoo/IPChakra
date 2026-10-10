//
//  Generated file. Do not edit.
//

// clang-format off

#import "GeneratedPluginRegistrant.h"

#if __has_include(<flutter_v2ray_client/FlutterV2rayPlugin.h>)
#import <flutter_v2ray_client/FlutterV2rayPlugin.h>
#else
@import flutter_v2ray_client;
#endif

#if __has_include(<openvpn_flutter/OpenVPNFlutterPlugin.h>)
#import <openvpn_flutter/OpenVPNFlutterPlugin.h>
#else
@import openvpn_flutter;
#endif

#if __has_include(<shared_preferences_foundation/SharedPreferencesPlugin.h>)
#import <shared_preferences_foundation/SharedPreferencesPlugin.h>
#else
@import shared_preferences_foundation;
#endif

#if __has_include(<wireguard_flutter/WireguardFlutterPlugin.h>)
#import <wireguard_flutter/WireguardFlutterPlugin.h>
#else
@import wireguard_flutter;
#endif

@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {
  [FlutterV2rayPlugin registerWithRegistrar:[registry registrarForPlugin:@"FlutterV2rayPlugin"]];
  [OpenVPNFlutterPlugin registerWithRegistrar:[registry registrarForPlugin:@"OpenVPNFlutterPlugin"]];
  [SharedPreferencesPlugin registerWithRegistrar:[registry registrarForPlugin:@"SharedPreferencesPlugin"]];
  [WireguardFlutterPlugin registerWithRegistrar:[registry registrarForPlugin:@"WireguardFlutterPlugin"]];
}

@end
