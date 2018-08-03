#import "ReactNativePayments.h"
#import <React/RCTUtils.h>
#import <React/RCTEventDispatcher.h>

@implementation ReactNativePayments
@synthesize bridge = _bridge;

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()

- (NSDictionary *)constantsToExport
{
    return @{
             @"canMakePayments": @([PKPaymentAuthorizationViewController canMakePayments]),
             @"supportedGateways": [GatewayManager getSupportedGateways]
             };
}

RCT_EXPORT_METHOD(createPaymentRequest: (NSDictionary *)methodData
                  details: (NSDictionary *)details
                  options: (NSDictionary *)options
                  callback: (RCTResponseSenderBlock)callback)
{
    NSString *merchantId = methodData[@"merchantIdentifier"];
    NSDictionary *gatewayParameters = methodData[@"paymentMethodTokenizationParameters"][@"parameters"];
    
    if (gatewayParameters) {
        self.hasGatewayParameters = true;
        self.gatewayManager = [GatewayManager new];
        [self.gatewayManager configureGateway:gatewayParameters merchantIdentifier:merchantId];
    }
    
    self.paymentRequest = [[PKPaymentRequest alloc] init];
    self.paymentRequest.merchantIdentifier = merchantId;
    self.paymentRequest.merchantCapabilities = PKMerchantCapability3DS;
    self.paymentRequest.countryCode = methodData[@"countryCode"];
    self.paymentRequest.currencyCode = methodData[@"currencyCode"];
    self.paymentRequest.supportedNetworks = [self getSupportedNetworksFromMethodData:methodData];
    self.paymentRequest.paymentSummaryItems = [self getPaymentSummaryItemsFromDetails:details];
    self.paymentRequest.shippingMethods = [self getShippingMethodsFromDetails:details];
    
    [self setRequiredAddressFieldsFromOptions:options];
    
    // Set options so that we can later access it.
    self.initialOptions = options;
    
    callback(@[[NSNull null]]);
}

RCT_EXPORT_METHOD(show:(RCTResponseSenderBlock)callback)
{
    
    self.viewController = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest: self.paymentRequest];
    self.viewController.delegate = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *rootViewController = RCTPresentedViewController();
        [rootViewController presentViewController:self.viewController animated:YES completion:nil];
        callback(@[[NSNull null]]);
    });
}

RCT_EXPORT_METHOD(abort: (RCTResponseSenderBlock)callback)
{
    [self.viewController dismissViewControllerAnimated:YES completion:nil];
    
    callback(@[[NSNull null]]);
}

RCT_EXPORT_METHOD(complete: (NSDictionary *)paymentObject
                  callback: (RCTResponseSenderBlock)callback)
{
    NSString * paymentStatus = [paymentObject valueForKey:@"status"];
    
    if ([paymentStatus isEqualToString: @"success"]) {
        self.completion(PKPaymentAuthorizationStatusSuccess);
    } else {
        NSArray * errors = [paymentObject objectForKey:@"errors"];
        for (id error in errors) {
            if ([[error valueForKey:@"error"] isEqual: @"billingContactInvalid"]) {
                self.completion(PKPaymentAuthorizationStatusInvalidBillingPostalAddress);
            } else {
                self.completion(PKPaymentAuthorizationStatusFailure);
            }
        }
        
    }
    callback(@[[NSNull null]]);
}


-(void) paymentAuthorizationViewControllerDidFinish:(PKPaymentAuthorizationViewController *)controller
{
    [controller dismissViewControllerAnimated:YES completion:nil];
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:onuserdismiss" body:nil];
}

RCT_EXPORT_METHOD(handleDetailsUpdate: (NSDictionary *)details
                  callback: (RCTResponseSenderBlock)callback)

{
    if (!self.shippingContactCompletion && !self.shippingMethodCompletion) {
        // TODO:
        // - Call callback with error saying shippingContactCompletion was never called;
        
        return;
    }
    
    NSArray<PKShippingMethod *> *shippingMethods = [self getShippingMethodsFromDetails:details];
    
    NSArray<PKPaymentSummaryItem *> *paymentSummaryItems = [self getPaymentSummaryItemsFromDetails:details];
    
    
    if (self.shippingMethodCompletion) {
        self.shippingMethodCompletion(
                                      PKPaymentAuthorizationStatusSuccess,
                                      paymentSummaryItems
                                      );
        
        // Invalidate `self.shippingMethodCompletion`
        self.shippingMethodCompletion = nil;
    }
    
    if (self.shippingContactCompletion) {
        // Display shipping address error when shipping is needed and shipping method count is below 1
        if (self.initialOptions[@"requestShipping"] && [shippingMethods count] == 0) {
            return self.shippingContactCompletion(
                                                  PKPaymentAuthorizationStatusInvalidShippingPostalAddress,
                                                  shippingMethods,
                                                  paymentSummaryItems
                                                  );
        } else {
            self.shippingContactCompletion(
                                           PKPaymentAuthorizationStatusSuccess,
                                           shippingMethods,
                                           paymentSummaryItems
                                           );
        }
        // Invalidate `aself.shippingContactCompletion`
        self.shippingContactCompletion = nil;
        
    }
    
    // Call callback
    callback(@[[NSNull null]]);
    
}

// DELEGATES
// ---------------
- (void) paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                        didAuthorizePayment:(PKPayment *)payment
                                 completion:(void (^)(PKPaymentAuthorizationStatus))completion
{
    // Store completion for later use
    self.completion = completion;
    
    if (self.hasGatewayParameters) {
        [self.gatewayManager createTokenWithPayment:payment completion:^(NSString * _Nullable token, NSError * _Nullable error) {
            if (error) {
                [self handleGatewayError:error];
                return;
            }
            
            [self handleUserAccept:payment paymentToken:token];
        }];
    } else {
        [self handleUserAccept:payment paymentToken:nil];
    }
}


// Shipping Contact
- (void) paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                   didSelectShippingContact:(PKContact *)contact
                                 completion:(nonnull void (^)(PKPaymentAuthorizationStatus, NSArray<PKShippingMethod *> * _Nonnull, NSArray<PKPaymentSummaryItem *> * _Nonnull))completion
{
    self.shippingContactCompletion = completion;
    
    CNPostalAddress *postalAddress = contact.postalAddress;
    // street, subAdministrativeArea, and subLocality are supressed for privacy
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:onshippingaddresschange"
                                                    body:@{
                                                           @"recipient": [NSNull null],
                                                           @"organization": [NSNull null],
                                                           @"addressLine": [NSNull null],
                                                           @"city": postalAddress.city,
                                                           @"region": postalAddress.state,
                                                           @"country": [postalAddress.ISOCountryCode uppercaseString],
                                                           @"postalCode": postalAddress.postalCode,
                                                           @"phone": [NSNull null],
                                                           @"languageCode": [NSNull null],
                                                           @"sortingCode": [NSNull null],
                                                           @"dependentLocality": [NSNull null]
                                                           }];
}

// Shipping Method delegates
- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                   didSelectShippingMethod:(PKShippingMethod *)shippingMethod
                                completion:(void (^)(PKPaymentAuthorizationStatus, NSArray<PKPaymentSummaryItem *> * _Nonnull))completion
{
    self.shippingMethodCompletion = completion;
    
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:onshippingoptionchange" body:@{
                                                                                                         @"selectedShippingOptionId": shippingMethod.identifier
                                                                                                         }];
    
}

// PRIVATE METHODS
// https://developer.apple.com/reference/passkit/pkpaymentnetwork
// ---------------
- (NSArray *_Nonnull)getSupportedNetworksFromMethodData:(NSDictionary *_Nonnull)methodData
{
    NSMutableDictionary *supportedNetworksMapping = [[NSMutableDictionary alloc] init];
    
    CGFloat iOSVersion = [[[UIDevice currentDevice] systemVersion] floatValue];
    
    if (iOSVersion >= 8) {
        [supportedNetworksMapping setObject:PKPaymentNetworkAmex forKey:@"amex"];
        [supportedNetworksMapping setObject:PKPaymentNetworkMasterCard forKey:@"mastercard"];
        [supportedNetworksMapping setObject:PKPaymentNetworkVisa forKey:@"visa"];
    }
    
    if (iOSVersion >= 9) {
        [supportedNetworksMapping setObject:PKPaymentNetworkDiscover forKey:@"discover"];
        [supportedNetworksMapping setObject:PKPaymentNetworkPrivateLabel forKey:@"privatelabel"];
    }
    
    if (iOSVersion >= 9.2) {
        [supportedNetworksMapping setObject:PKPaymentNetworkChinaUnionPay forKey:@"chinaunionpay"];
        [supportedNetworksMapping setObject:PKPaymentNetworkInterac forKey:@"interac"];
    }
    
    if (iOSVersion >= 10.1) {
        [supportedNetworksMapping setObject:PKPaymentNetworkJCB forKey:@"jcb"];
        [supportedNetworksMapping setObject:PKPaymentNetworkSuica forKey:@"suica"];
    }
    
    if (iOSVersion >= 10.3) {
        [supportedNetworksMapping setObject:PKPaymentNetworkCarteBancaire forKey:@"cartebancaires"];
        [supportedNetworksMapping setObject:PKPaymentNetworkIDCredit forKey:@"idcredit"];
        [supportedNetworksMapping setObject:PKPaymentNetworkQuicPay forKey:@"quicpay"];
    }
    
    if (iOSVersion >= 11) {
        [supportedNetworksMapping setObject:PKPaymentNetworkCarteBancaires forKey:@"cartebancaires"];
    }
    
    // Setup supportedNetworks
    NSArray *jsSupportedNetworks = methodData[@"supportedNetworks"];
    NSMutableArray *supportedNetworks = [NSMutableArray array];
    for (NSString *supportedNetwork in jsSupportedNetworks) {
        [supportedNetworks addObject: supportedNetworksMapping[supportedNetwork]];
    }
    
    return supportedNetworks;
}

- (NSArray<PKPaymentSummaryItem *> *_Nonnull)getPaymentSummaryItemsFromDetails:(NSDictionary *_Nonnull)details
{
    // Setup `paymentSummaryItems` array
    NSMutableArray <PKPaymentSummaryItem *> *paymentSummaryItems = [NSMutableArray array];
    
    // Add `displayItems` to `paymentSummaryItems`
    NSArray *displayItems = details[@"displayItems"];
    if (displayItems.count > 0) {
        for (NSDictionary *displayItem in displayItems) {
            [paymentSummaryItems addObject: [self convertDisplayItemToPaymentSummaryItem:displayItem]];
        }
    }
    
    // Add total to `paymentSummaryItems`
    NSDictionary *total = details[@"total"];
    [paymentSummaryItems addObject: [self convertDisplayItemToPaymentSummaryItem:total]];
    
    return paymentSummaryItems;
}

- (NSArray<PKShippingMethod *> *_Nonnull)getShippingMethodsFromDetails:(NSDictionary *_Nonnull)details
{
    // Setup `shippingMethods` array
    NSMutableArray <PKShippingMethod *> *shippingMethods = [NSMutableArray array];
    
    // Add `shippingOptions` to `shippingMethods`
    NSArray *shippingOptions = details[@"shippingOptions"];
    if (shippingOptions.count > 0) {
        for (NSDictionary *shippingOption in shippingOptions) {
            [shippingMethods addObject: [self convertShippingOptionToShippingMethod:shippingOption]];
        }
    }
    
    return shippingMethods;
}

- (PKPaymentSummaryItem *_Nonnull)convertDisplayItemToPaymentSummaryItem:(NSDictionary *_Nonnull)displayItem;
{
    NSDecimalNumber *decimalNumberAmount = [NSDecimalNumber decimalNumberWithString:displayItem[@"amount"][@"value"]];
    PKPaymentSummaryItem *paymentSummaryItem = [PKPaymentSummaryItem summaryItemWithLabel:displayItem[@"label"] amount:decimalNumberAmount];
    
    return paymentSummaryItem;
}

- (PKShippingMethod *_Nonnull)convertShippingOptionToShippingMethod:(NSDictionary *_Nonnull)shippingOption
{
    PKShippingMethod *shippingMethod = [PKShippingMethod summaryItemWithLabel:shippingOption[@"label"] amount:[NSDecimalNumber decimalNumberWithString: shippingOption[@"amount"][@"value"]]];
    shippingMethod.identifier = shippingOption[@"id"];
    
    // shippingOption.detail is not part of the PaymentRequest spec.
    if ([shippingOption[@"detail"] isKindOfClass:[NSString class]]) {
        shippingMethod.detail = shippingOption[@"detail"];
    } else {
        shippingMethod.detail = @"";
    }
    
    return shippingMethod;
}

- (void)setRequiredAddressFieldsFromOptions:(NSDictionary *_Nonnull)options
{
    // Request Shipping
    if (options[@"requestShipping"]) {
        self.paymentRequest.requiredShippingAddressFields = PKAddressFieldPostalAddress;
    }
    
    if (options[@"requestBilling"]) {
        if (@available(iOS 11.0, *)) {
            self.paymentRequest.requiredBillingContactFields = [NSSet setWithObject:PKContactFieldPostalAddress];
        } else {
            self.paymentRequest.requiredBillingAddressFields = PKAddressFieldPostalAddress;
        }
        
    }
    
    if (options[@"requestPayerName"]) {
        self.paymentRequest.requiredShippingAddressFields = self.paymentRequest.requiredShippingAddressFields | PKAddressFieldName;
    }
    
    if (options[@"requestPayerPhone"]) {
        self.paymentRequest.requiredShippingAddressFields = self.paymentRequest.requiredShippingAddressFields | PKAddressFieldPhone;
    }
    
    if (options[@"requestPayerEmail"]) {
        self.paymentRequest.requiredShippingAddressFields = self.paymentRequest.requiredShippingAddressFields | PKAddressFieldEmail;
    }
}

- (NSString*) convertPaymentTypeToString:(PKPaymentMethodType) paymentType {
    NSString *result = nil;
    
    // https://developer.apple.com/documentation/apple_pay_on_the_web/applepaypaymentmethodtype
    switch(paymentType) {
        case PKPaymentMethodTypeDebit:
            result = @"debit";
            break;
        case PKPaymentMethodTypeCredit:
            result = @"credit";
            break;
        case PKPaymentMethodTypePrepaid:
            result = @"prepaid";
            break;
        case PKPaymentMethodTypeStore:
            result = @"store";
            break;
            
        default:
            result = @"unknown";
    }
    
    return result;
}

- (NSString *)getBillingContact:(PKContact *) billingContact {
    
    // Using BPA required format : https://github.com/EurostarDigital/eurostar_bpa/blob/d76753ce31a95b684cc43cdbbfe0001539054c57/app/shared/actions/helpers.js#L3062
    
    NSMutableDictionary *tmp = [NSMutableDictionary dictionary];
    CNPostalAddress *postalAddress = billingContact.postalAddress;
    
    if (billingContact.name.familyName) tmp[@"familyName"] = billingContact.name.familyName;
    if (billingContact.name.givenName) tmp[@"givenName"] = billingContact.name.givenName;
    if (billingContact.name.phoneticRepresentation.familyName) tmp[@"phoneticFamilyName"] = billingContact.name.familyName;
    if (billingContact.name.phoneticRepresentation.givenName) tmp[@"phoneticGivenName"] = billingContact.name.givenName;
    
    if (postalAddress.street) {
        NSArray *streetArray = [postalAddress.street componentsSeparatedByString:@"\n"];
        tmp[@"addressLines"] = streetArray;
    }
    if (postalAddress.city) tmp[@"locality"] = postalAddress.city;
    if (postalAddress.subLocality) tmp[@"sublocality"] = postalAddress.subLocality;
    if (postalAddress.subAdministrativeArea) tmp[@"subAdministrativeArea"] = postalAddress.subAdministrativeArea;
    if (postalAddress.state) tmp[@"administrativeArea"] = postalAddress.state;
    if (postalAddress.postalCode) tmp[@"postalCode"] = postalAddress.postalCode;
    if (postalAddress.country) tmp[@"country"] = postalAddress.country;
    if (postalAddress.ISOCountryCode) tmp[@"countryCode"] = postalAddress.ISOCountryCode;
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:tmp
                                                       options: 0
                                                         error:&error];
    
    if (!jsonData) {
        NSLog(@"Got an error: %@", error);
        return nil;
    }
    
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
}

- (NSString *) getPaymentMethod:(PKPaymentMethod *) paymentMethod {
    NSMutableDictionary *tmp = [NSMutableDictionary dictionary];
    NSString *paymentType = [self convertPaymentTypeToString:paymentMethod.type];
    
    if (paymentMethod.displayName) tmp[@"displayName"] = paymentMethod.displayName;
    if (paymentMethod.network) tmp[@"network"] = paymentMethod.network;
    if (paymentMethod.type) tmp[@"type"] = paymentType;
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:tmp
                                                       options: 0
                                                         error:&error];
    
    if (!jsonData) {
        NSLog(@"Got an error: %@", error);
        return nil;
    }
    
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

-(BOOL)isValidString:(NSString *) string {
    NSString *nameRegex = @"^[ ',-.0-9A-Za-zÀ-ÿ]*$";
    NSPredicate *nameValidate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", nameRegex];
    
    return [nameValidate evaluateWithObject:string];
}


-(BOOL)isValidPostCode:(NSString *) postCode {
    
    if (!postCode || ![self isValidString:postCode] || postCode.length > 10) {
        return NO;
    }
    return YES;
    
}

-(BOOL)isValidStreet:(NSString *) street {
    
    NSArray* addressLines = [street componentsSeparatedByString: @"\n"];
    NSString* line1 = [addressLines objectAtIndex: 0];
    NSString* line2 = nil;
    if([addressLines count] >= 2) {
        line2 = [addressLines objectAtIndex: 1];
    }
    
    if(!line1 || line1.length > 35 || ![self isValidString:line1]) {
        return NO;
    }
    
    if(line2 && (![self isValidString:line2] || line2.length > 35)) {
        return NO;
    }
    
    return YES;
}

-(BOOL)isValidCityName:(NSString *) city {
    
    if(!city || ![self isValidString:city] || city.length > 20) {
        return NO;
    }
    
    return YES;
}

-(BOOL)isValidStateName:(NSString *) state {
    
    if(![self isValidString:state] || state.length > 35) {
        return NO;
    }
    
    return YES;
}

-(BOOL)isValidBillingContact:(CNPostalAddress *) address {
    // using BPA as reference: https://github.com/EurostarDigital/eurostar_bpa/blob/18103af998c74f852bc233c047cf20306e8acf90/app/shared/validators/checkout-form/billing-address.js
    if(
       ![self isValidPostCode:address.postalCode] ||
       ![self isValidStreet:address.street] ||
       ![self isValidCityName:address.city] ||
       ![self isValidStateName:address.state]
    ) {
        return NO;
    }
    
    return YES;
}

-(void)handleUserAccept:(PKPayment *_Nonnull)payment
           paymentToken:(NSString *_Nullable)token
{
    NSString *transactionId = payment.token.transactionIdentifier;
    
//    if(![self isValidBillingContact:payment.billingContact.postalAddress]) {
//        return self.completion(PKPaymentAuthorizationStatusInvalidBillingPostalAddress);
//    }
    
    NSString *billingContact = [self getBillingContact:payment.billingContact];
    NSString *paymentMethod = [self getPaymentMethod:payment.token.paymentMethod];
    NSString *paymentData = [[NSString alloc] initWithData:payment.token.paymentData encoding:NSUTF8StringEncoding];
    
    NSMutableDictionary *paymentResponse = [[NSMutableDictionary alloc]initWithCapacity:4];
    paymentResponse[@"transactionIdentifier"] = transactionId;
    paymentResponse[@"paymentData"] = paymentData;
    paymentResponse[@"paymentMethod"] = paymentMethod;
    if(billingContact) {
        paymentResponse[@"billingContact"] = billingContact;
    }
    
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:onuseraccept"
                                                    body:paymentResponse
     ];
}

- (void)handleGatewayError:(NSError *_Nonnull)error
{
    [self.bridge.eventDispatcher sendDeviceEventWithName:@"NativePayments:ongatewayerror"
                                                    body: @{
                                                            @"error": [error localizedDescription]
                                                            }
     ];
}

@end
