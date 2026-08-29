#import "AppDelegate.h"
#import <ReactNativeNavigation/ReactNativeNavigation.h>

#import <React/RCTBundleURLProvider.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static NSData *MMBase64Decode(NSString *value) {
  return [[NSData alloc] initWithBase64EncodedString:value options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

static NSString *MMBase64Encode(NSData *value) {
  return [value base64EncodedStringWithOptions:0];
}

static NSString *MMSHA1(NSString *value) {
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA1_DIGEST_LENGTH];
  CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA1_DIGEST_LENGTH; index++) [result appendFormat:@"%02x", digest[index]];
  return result;
}

static NSString *MMD5(NSString *value) {
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_MD5_DIGEST_LENGTH];
  CC_MD5(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *result = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_MD5_DIGEST_LENGTH; index++) [result appendFormat:@"%02x", digest[index]];
  return result;
}

static NSString *MMAES(NSString *text, NSString *key, NSString *iv, NSString *mode, BOOL decrypt) {
  NSData *input = MMBase64Decode(text ?: @"");
  NSData *keyData = MMBase64Decode(key ?: @"");
  NSData *ivData = MMBase64Decode(iv ?: @"");
  if (!input || !keyData) return @"";

  BOOL cbc = [mode containsString:@"CBC"];
  size_t outputLength = 0;
  NSMutableData *output = [NSMutableData dataWithLength:input.length + kCCBlockSizeAES128];
  uint8_t paddedIV[kCCBlockSizeAES128] = {0};
  if (cbc && ivData.length) memcpy(paddedIV, ivData.bytes, MIN(ivData.length, sizeof(paddedIV)));
  CCCryptorStatus status = CCCrypt(decrypt ? kCCDecrypt : kCCEncrypt,
    kCCAlgorithmAES,
    cbc ? kCCOptionPKCS7Padding : 0,
    keyData.bytes,
    keyData.length,
    cbc ? paddedIV : NULL,
    input.bytes,
    input.length,
    output.mutableBytes,
    output.length,
    &outputLength);
  if (status != kCCSuccess) return @"";
  output.length = outputLength;
  if (!decrypt) return MMBase64Encode(output);
  return [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
}

static NSData *MMRSAData(NSString *text, NSString *key, NSString *padding, BOOL decrypt) {
  NSData *input = MMBase64Decode(text ?: @"");
  NSData *keyData = MMBase64Decode(key ?: @"");
  if (!input || !keyData) return nil;
  NSDictionary *attributes = @{
    (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
    (__bridge id)kSecAttrKeyClass: decrypt ? (__bridge id)kSecAttrKeyClassPrivate : (__bridge id)kSecAttrKeyClassPublic,
  };
  CFErrorRef keyError = NULL;
  SecKeyRef keyRef = SecKeyCreateWithData((__bridge CFDataRef)keyData, (__bridge CFDictionaryRef)attributes, &keyError);
  if (!keyRef) {
    if (keyError) CFRelease(keyError);
    return nil;
  }
  SecKeyAlgorithm algorithm = [padding containsString:@"OAEP"] ?
    kSecKeyAlgorithmRSAEncryptionOAEPSHA1 : kSecKeyAlgorithmRSAEncryptionRaw;
  CFErrorRef operationError = NULL;
  CFDataRef resultRef = decrypt
    ? SecKeyCreateDecryptedData(keyRef, algorithm, (__bridge CFDataRef)input, &operationError)
    : SecKeyCreateEncryptedData(keyRef, algorithm, (__bridge CFDataRef)input, &operationError);
  NSData *result = resultRef ? CFBridgingRelease(resultRef) : nil;
  if (operationError) CFRelease(operationError);
  CFRelease(keyRef);
  return result;
}

@interface MouCacheModule : NSObject <RCTBridgeModule>
@end

@implementation MouCacheModule
RCT_EXPORT_MODULE(CacheModule)
RCT_EXPORT_METHOD(getAppCacheSize:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  resolve(@0);
}
RCT_EXPORT_METHOD(clearAppCache:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  resolve(nil);
}
@end

@interface MouUtilsModule : NSObject <RCTBridgeModule>
@end

@implementation MouUtilsModule
RCT_EXPORT_MODULE(UtilsModule)
RCT_EXPORT_METHOD(exitApp) {}
RCT_EXPORT_METHOD(getSupportedAbis:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(@[@"arm64"]); }
RCT_EXPORT_METHOD(installApk:(NSString *)path provider:(NSString *)provider resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { reject(@"IOS_ONLY", @"APK installation is only available on Android", nil); }
RCT_EXPORT_METHOD(screenkeepAwake) { [UIApplication.sharedApplication.keyWindow setUserInteractionEnabled:YES]; }
RCT_EXPORT_METHOD(screenUnkeepAwake) {}
RCT_EXPORT_METHOD(getWIFIIPV4Address:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(@""); }
RCT_EXPORT_METHOD(getDeviceName:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(UIDevice.currentDevice.name ?: @"Moumusic"); }
RCT_EXPORT_METHOD(isNotificationsEnabled:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(@NO); }
RCT_EXPORT_METHOD(openNotificationPermissionActivity:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(@NO); }
RCT_EXPORT_METHOD(shareText:(NSString *)shareTitle title:(NSString *)title text:(NSString *)text) {}
RCT_EXPORT_METHOD(getSystemLocales:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(NSLocale.currentLocale.localeIdentifier ?: @"zh_CN"); }
RCT_EXPORT_METHOD(getWindowSize:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  CGSize size = UIScreen.mainScreen.bounds.size;
  resolve(@{@"width": @(size.width), @"height": @(size.height)});
}
RCT_EXPORT_METHOD(listenWindowSizeChanged) {}
RCT_EXPORT_METHOD(isIgnoringBatteryOptimization:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(@NO); }
RCT_EXPORT_METHOD(requestIgnoreBatteryOptimization:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(@NO); }
@end

@interface MouCryptoModule : NSObject <RCTBridgeModule>
@end

@implementation MouCryptoModule
RCT_EXPORT_MODULE(CryptoModule)
RCT_EXPORT_METHOD(generateRsaKey:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *attributes = @{
    (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
    (__bridge id)kSecAttrKeySizeInBits: @2048,
  };
  CFErrorRef error = NULL;
  SecKeyRef privateKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes, &error);
  if (!privateKey) {
    if (error) CFRelease(error);
    reject(@"RSA", @"Unable to create RSA key", nil);
    return;
  }
  SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey);
  NSData *privateData = CFBridgingRelease(SecKeyCopyExternalRepresentation(privateKey, NULL));
  NSData *publicData = CFBridgingRelease(SecKeyCopyExternalRepresentation(publicKey, NULL));
  if (publicKey) CFRelease(publicKey);
  CFRelease(privateKey);
  resolve(@{ @"publicKey": MMBase64Encode(publicData ?: [NSData data]), @"privateKey": MMBase64Encode(privateData ?: [NSData data]) });
}
RCT_EXPORT_METHOD(rsaEncrypt:(NSString *)text key:(NSString *)key padding:(NSString *)padding resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(MMBase64Encode(MMRSAData(text, key, padding, NO) ?: [NSData data])); }
RCT_EXPORT_METHOD(rsaDecrypt:(NSString *)text key:(NSString *)key padding:(NSString *)padding resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve([[NSString alloc] initWithData:(MMRSAData(text, key, padding, YES) ?: [NSData data]) encoding:NSUTF8StringEncoding] ?: @""); }
RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(rsaEncryptSync:(NSString *)text key:(NSString *)key padding:(NSString *)padding) { return MMBase64Encode(MMRSAData(text, key, padding, NO) ?: [NSData data]); }
RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(rsaDecryptSync:(NSString *)text key:(NSString *)key padding:(NSString *)padding) { return [[NSString alloc] initWithData:(MMRSAData(text, key, padding, YES) ?: [NSData data]) encoding:NSUTF8StringEncoding] ?: @""; }
RCT_EXPORT_METHOD(aesEncrypt:(NSString *)text key:(NSString *)key iv:(NSString *)iv mode:(NSString *)mode resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(MMAES(text, key, iv, mode, NO)); }
RCT_EXPORT_METHOD(aesDecrypt:(NSString *)text key:(NSString *)key iv:(NSString *)iv mode:(NSString *)mode resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(MMAES(text, key, iv, mode, YES)); }
RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(aesEncryptSync:(NSString *)text key:(NSString *)key iv:(NSString *)iv mode:(NSString *)mode) { return MMAES(text, key, iv, mode, NO); }
RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(aesDecryptSync:(NSString *)text key:(NSString *)key iv:(NSString *)iv mode:(NSString *)mode) { return MMAES(text, key, iv, mode, YES); }
RCT_EXPORT_METHOD(sha1:(NSString *)input resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(MMSHA1(input ?: @"")); }
@end

@interface MouLyricModule : RCTEventEmitter <RCTBridgeModule>
@end

@implementation MouLyricModule
RCT_EXPORT_MODULE(LyricModule)
- (NSArray<NSString *> *)supportedEvents { return @[@"set-position", @"lyric-line-play"]; }
RCT_EXPORT_METHOD(setSendLyricTextEvent:(BOOL)value) {}
RCT_EXPORT_METHOD(showDesktopLyric:(NSDictionary *)info) {}
RCT_EXPORT_METHOD(hideDesktopLyric) {}
RCT_EXPORT_METHOD(play:(double)time) {}
RCT_EXPORT_METHOD(pause) {}
RCT_EXPORT_METHOD(setLyric:(NSString *)lyric translation:(NSString *)translation romalrc:(NSString *)romalrc) {}
RCT_EXPORT_METHOD(setPlaybackRate:(double)rate) {}
RCT_EXPORT_METHOD(toggleTranslation:(BOOL)value) {}
RCT_EXPORT_METHOD(toggleRoma:(BOOL)value) {}
RCT_EXPORT_METHOD(toggleLock:(BOOL)value) {}
RCT_EXPORT_METHOD(setColor:(NSString *)unplay played:(NSString *)played shadow:(NSString *)shadow) {}
RCT_EXPORT_METHOD(setAlpha:(double)value) {}
RCT_EXPORT_METHOD(setTextSize:(double)value) {}
RCT_EXPORT_METHOD(setShowToggleAnima:(BOOL)value) {}
RCT_EXPORT_METHOD(setSingleLine:(BOOL)value) {}
RCT_EXPORT_METHOD(setPosition:(double)x y:(double)y) {}
RCT_EXPORT_METHOD(setMaxLineNum:(double)value) {}
RCT_EXPORT_METHOD(setWidth:(double)value) {}
RCT_EXPORT_METHOD(setLyricTextPosition:(NSString *)x y:(NSString *)y) {}
RCT_EXPORT_METHOD(checkOverlayPermission:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(@NO); }
RCT_EXPORT_METHOD(openOverlayPermissionActivity:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) { resolve(@NO); }
@end

@interface MouUserApiModule : RCTEventEmitter <RCTBridgeModule>
@property(nonatomic, strong) JSContext *context;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, strong) dispatch_queue_t jsQueue;
@property(nonatomic, assign) BOOL inited;
@end

@implementation MouUserApiModule
RCT_EXPORT_MODULE(UserApiModule)

- (instancetype)init {
  if ((self = [super init])) {
    _jsQueue = dispatch_queue_create("com.jiajia2222.moumusic.user-api", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (dispatch_queue_t)methodQueue { return self.jsQueue; }
- (NSArray<NSString *> *)supportedEvents { return @[@"api-action"]; }

- (void)emitAction:(NSString *)action data:(id)data {
  NSString *json = @"";
  if ([data isKindOfClass:[NSString class]]) json = data;
  else if (data) {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
    json = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] ?: @"";
  }
  dispatch_async(dispatch_get_main_queue(), ^{ [self sendEventWithName:@"api-action" body:@{ @"action": action ?: @"", @"data": json }]; });
}

- (void)callJS:(NSString *)action data:(id)data {
  if (!self.context) return;
  JSValue *function = self.context[@"__lx_native__"];
  if (!function || function.isUndefined) return;
  id argument = [NSNull null];
  if (data && data != [NSNull null]) {
    if ([data isKindOfClass:[NSString class]]) argument = data;
    else if ([data isKindOfClass:[NSNumber class]]) argument = [data stringValue];
    else {
      NSData *encoded = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
      argument = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] ?: @"null";
    }
  }
  [function callWithArguments:@[self.key ?: @"", action ?: @"", argument]];
}

- (void)loadUserScript:(NSDictionary *)info {
  self.inited = NO;
  self.key = NSUUID.UUID.UUIDString;
  self.context = [[JSContext alloc] init];
  __weak MouUserApiModule *weakSelf = self;
  self.context.exceptionHandler = ^(JSContext *context, JSValue *exception) {
    [weakSelf emitAction:@"log" data:@{ @"type": @"error", @"log": exception.toString ?: @"User source error" }];
  };
  self.context[@"console"] = @{ @"log": ^(JSValue *value) { NSLog(@"[Moumusic UserApi] %@", value); }, @"error": ^(JSValue *value) { NSLog(@"[Moumusic UserApi] %@", value); } };
  self.context[@"__lx_native_call__"] = ^(NSString *key, NSString *action, NSString *data) {
    if (![key isEqualToString:weakSelf.key]) return;
    id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:[data dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : @"";
    [weakSelf emitAction:action data:parsed ?: @"{\"status\":false}"];
  };
  self.context[@"__lx_native_call__utils_str2b64"] = ^NSString *(NSString *value) { return MMBase64Encode([value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]); };
  self.context[@"__lx_native_call__utils_b642buf"] = ^NSString *(NSString *value) {
    NSData *data = MMBase64Decode(value ?: @"");
    NSMutableArray *bytes = [NSMutableArray arrayWithCapacity:data.length];
    for (NSUInteger index = 0; index < data.length; index++) [bytes addObject:@(((const uint8_t *)data.bytes)[index])];
    NSData *json = [NSJSONSerialization dataWithJSONObject:bytes options:0 error:nil];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"[]";
  };
  self.context[@"__lx_native_call__utils_str2md5"] = ^NSString *(NSString *value) { return MMD5([value stringByRemovingPercentEncoding] ?: value ?: @""); };
  self.context[@"__lx_native_call__utils_aes_encrypt"] = ^NSString *(NSString *text, NSString *key, NSString *iv, NSString *mode) { return MMAES(text, key, iv, mode, NO); };
  self.context[@"__lx_native_call__utils_rsa_encrypt"] = ^NSString *(NSString *text, NSString *key, NSString *padding) { return MMBase64Encode(MMRSAData(text, key, padding, NO) ?: [NSData data]); };
  self.context[@"__lx_native_call__set_timeout"] = ^(NSNumber *identifier, NSNumber *delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, delay.doubleValue) * NSEC_PER_MSEC)), weakSelf.jsQueue, ^{ [weakSelf callJS:@"__set_timeout__" data:identifier]; });
  };
  NSString *preloadPath = [[NSBundle mainBundle] pathForResource:@"user-api-preload" ofType:@"js"];
  NSString *preload = preloadPath ? [NSString stringWithContentsOfFile:preloadPath encoding:NSUTF8StringEncoding error:nil] : nil;
  if (!preload) {
    [self emitAction:@"init" data:@{ @"status": @NO, @"errorMessage": @"Moumusic user source runtime is unavailable" }];
    return;
  }
  [self.context evaluateScript:preload];
  JSValue *setup = self.context[@"lx_setup"];
  if (!setup || setup.isUndefined) {
    [self emitAction:@"init" data:@{ @"status": @NO, @"errorMessage": @"Moumusic user source runtime is unavailable" }];
    return;
  }
  [setup callWithArguments:@[self.key, info[@"id"] ?: @"", info[@"name"] ?: @"Unknown", info[@"description"] ?: @"", info[@"version"] ?: @"", info[@"author"] ?: @"", info[@"homepage"] ?: @"", info[@"script"] ?: @""]];
  [self.context evaluateScript:info[@"script"] ?: @""];
}

RCT_EXPORT_METHOD(loadScript:(NSDictionary *)info) { [self loadUserScript:info]; }
RCT_EXPORT_METHOD(sendAction:(NSString *)action info:(NSString *)info) { [self callJS:action data:info]; }
RCT_EXPORT_METHOD(destroy) { self.context = nil; }
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  RCTBridge *bridge = [[RCTBridge alloc] initWithDelegate:self launchOptions:launchOptions];
  [ReactNativeNavigation bootstrapWithBridge:bridge];
  // You can add your custom initial props in the dictionary below.
  // They will be passed down to the ViewController used by React Native.
  self.initialProps = @{};

  return YES;
}

- (NSArray<id<RCTBridgeModule>> *)extraModulesForBridge:(RCTBridge *)bridge {
  return [ReactNativeNavigation extraModulesForBridge:bridge];
}

- (NSURL *)sourceURLForBridge:(RCTBridge *)bridge
{
  return [self getBundleURL];
}
- (NSURL *)getBundleURL
{
#if DEBUG
  return [[RCTBundleURLProvider sharedSettings] jsBundleURLForBundleRoot:@"index"];
#else
  return [[NSBundle mainBundle] URLForResource:@"main" withExtension:@"jsbundle"];
#endif
}

@end
