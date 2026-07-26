// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>


/**
 * Wrapper object for an `BOOL` value.
 */
@interface IINKBoolValue : NSObject
{
}

@property (nonatomic) BOOL value;

/**
 * Create a new `IINKBoolValue` instance.
 * @param value the BOOL value.
 */
- (nullable instancetype)initWithValue:(BOOL)value;

/**
 * Builds a new `IINKBoolValue` instance.
 * @param value the BOOL value.
 */
+ (nonnull IINKBoolValue *)valueWithBool:(BOOL)value;

@end


/**
 * Wrapper object for an `double` value.
 */
@interface IINKDoubleValue : NSObject
{
}

@property (nonatomic) double value;

/**
 * Create a new `IINKDoubleValue` instance.
 * @param value the double value.
 */
- (nullable instancetype)initWithValue:(double)value;

/**
 * Builds a new `IINKDoubleValue` instance.
 * @param value the double value.
 */
+ (nonnull IINKDoubleValue *)valueWithDouble:(double)value;

@end


/**
 * Represents a set of parameters values.
 */
@interface IINKParameterSet : NSObject
{

}


//==============================================================================
#pragma mark - Methods
//==============================================================================

/**
 * Injects JSON content into this parameter set.
 *
 * @param jsonText JSON parameters values.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when jsonText is not valid JSON.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)inject:(nonnull NSString *)jsonText
         error:(NSError * _Nullable * _Nullable)error;

/**
 * Returns the string value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a string.
 * @return the value if present, otherwise `nil`.
 */
- (nullable NSString *)getStringForKey:(nonnull NSString *)key
                                 error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(string(forKey:));

/**
 * Returns the string value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param defaultValue the value to return when `key` is not present.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` is not a string.
 * @return the value.
 */
- (nullable NSString *)getStringForKey:(nonnull NSString *)key
                         defaultValue:(nonnull NSString *)defaultValue
                                error:(NSError * _Nullable * _Nullable)error
                      NS_SWIFT_NAME(string(forKey:defaultValue:));

/**
 * Sets the string value associated with `key`.
 *
 * @param value the string value to set.
 * @param key the key of the value to set.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` exists and is not a string.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)setString:(nonnull NSString *)value
           forKey:(nonnull NSString *)key
            error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(string:forKey:));

/**
 * Returns the boolean value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a boolean.
 * @return the value if present, otherwise `nil`.
 */
- (nullable IINKBoolValue *)getBooleanForKey:(nonnull NSString *)key
                                       error:(NSError * _Nullable * _Nullable)error
                            NS_SWIFT_NAME(boolean(forKey:));

/**
 * Returns the boolean value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param defaultValue the value to return when `key` is not present.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` is not a boolean.
 * @return the value if present, otherwise `nil`.
 */
- (nullable IINKBoolValue *)getBooleanForKey:(nonnull NSString *)key
                                defaultValue:(BOOL)defaultValue
                                       error:(NSError * _Nullable * _Nullable)error
                            NS_SWIFT_NAME(boolean(forKey:defaultValue:));

/**
 * Sets the boolean value associated with `key`.
 *
 * @param value the boolean value to set.
 * @param key the key of the value to set.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` exists and is not a boolean.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)setBoolean:(BOOL)value
            forKey:(nonnull NSString *)key
             error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(boolean:forKey:));

/**
 * Returns the numeric value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a number.
 * @return the value on success, if present, otherwise `nil.`.
 */
- (nullable IINKDoubleValue*)getNumberForKey:(nonnull NSString *)key
                                       error:(NSError * _Nullable * _Nullable)error
                             NS_SWIFT_NAME(number(forKey:));

/**
 * Returns the numeric value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param defaultValue the value to return when `key` is not present.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` is not a number.
 * @return the value on success, otherwise `nil.`.
 */
- (nullable IINKDoubleValue*)getNumberForKey:(nonnull NSString *)key
             defaultValue:(double)defaultValue
                    error:(NSError * _Nullable * _Nullable)error
          NS_SWIFT_NAME(number(forKey:defaultValue:));

/**
 * Sets the numeric value associated with `key`.
 *
 * @param value the numeric value to set.
 * @param key the key of the value to set.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` exists and is not a number.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)setNumber:(double)value
           forKey:(nonnull NSString *)key
            error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(number:forKey:));

/**
 * Returns the string array value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a string array.
 * @return the value on success, otherwise `nil`.
 */
- (nullable NSArray<NSString *> *)getStringArrayForKey:(nonnull NSString *)key
                                                 error:(NSError * _Nullable * _Nullable)error
                                  NS_SWIFT_NAME(stringArray(forKey:));

/**
 * Returns the string array value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param defaultValue the value to return when `key` is not present.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` is not a string array.
 * @return the value.
 *
 * @since 1.4
 */
- (nullable NSArray<NSString *> *)getStringArrayForKey:(nonnull NSString *)key
                                         defaultValue:(nonnull NSArray<NSString *> *)defaultValue
                                                error:(NSError * _Nullable * _Nullable)error
                                 NS_SWIFT_NAME(stringArray(forKey:defaultValue:));

/**
 * Sets the string array value associated with `key`.
 *
 * @param value the value to set.
 * @param key the key of the value to set.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` exists and is not a string array.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)setStringArray:(nonnull NSArray<NSString *> *)value
                forKey:(nonnull NSString *)key
                 error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(stringArray:forKey:));

/**
 * Returns the number array value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a number array.
 * @return the value.
 *
 * @since 3.1
 */
- (nullable NSArray<IINKDoubleValue *> *)getNumberArrayForKey:(nonnull NSString *)key
                                                        error:(NSError * _Nullable * _Nullable)error
                                             NS_SWIFT_NAME(numberArray(forKey:));

/**
 * Returns the number array value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param defaultValue the value to return when `key` is not present.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a number array.
 * @return the value.
 *
 * @since 3.1
 */
- (nullable NSArray<IINKDoubleValue *> *)getNumberArrayForKey:(nonnull NSString *)key
                                                defaultValue:(nonnull NSArray<IINKDoubleValue *> *)defaultValue
                                                       error:(NSError * _Nullable * _Nullable)error
                                            NS_SWIFT_NAME(numberArray(forKey:defaultValue:));

/**
 * Sets the number array value associated with `key`.
 *
 * @param key the key of the value to set.
 * @param value the value to set.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` is not a number array.
 *
 * @since 3.1
 */
- (BOOL)setNumberArray:(nonnull NSArray<IINKDoubleValue *> *)value
                forKey:(nonnull NSString *)key
                 error:(NSError * _Nullable * _Nullable)error
     NS_SWIFT_NAME(set(numberArray:forKey:));

/**
 * Returns a parameter set object representing the section associated with
 * `key`. Sections correspond to the hierarchical organization of keys
 * according to their dots. For example, if you have keys "a.b.c" and "a.b.d"
 * there is a section "a.b" that contains keys "c" and "d", as well as a
 * section "a" containing "b.c" and "b.d".
 *
 * @param key the key of the section to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a section.
 * @return the section on success, otherwise `nil`.
 */
- (nullable IINKParameterSet *)getSectionForKey:(nonnull NSString *)key
                                          error:(NSError * _Nullable * _Nullable)error
                               NS_SWIFT_NAME(section(forKey:));


//==============================================================================
#pragma mark - Deprecated Methods
//==============================================================================

/**
 * Returns the string value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a string.
 * @return the value if present, otherwise `nil`.
 */
- (nullable NSString *)getString:(nonnull NSString *)key
                           error:(NSError * _Nullable * _Nullable)error
    DEPRECATED_MSG_ATTRIBUTE("Use getStringForKey:error: instead");

/**
 * Returns the string value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param defaultValue the value to return when `key` is not present.
 * @return the value.
 */
- (nonnull NSString *)getString:(nonnull NSString *)key
                        orValue:(nonnull NSString *)defaultValue
    DEPRECATED_MSG_ATTRIBUTE("Use getStringForKey:defaultValue: instead");

/**
 * Sets the string value associated with `key`.
 *
 * @param key the key of the value to set.
 * @param value the string value to set.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` exists and is not a string.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)setString:(nonnull NSString *)key
            value:(nonnull NSString *)value
        error:(NSError * _Nullable * _Nullable)error
    DEPRECATED_MSG_ATTRIBUTE("Use setString:forKey:error: instead");

/**
 * Returns the boolean value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a boolean.
 * @return the value if present, otherwise `nil`.
 */
- (BOOL)getBoolean:(nonnull NSString *)key
             error:(NSError * _Nullable * _Nullable)error
    DEPRECATED_MSG_ATTRIBUTE("Use getBooleanForKey:error: instead");

/**
 * Returns the boolean value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param defaultValue the value to return when `key` is not present.
 * @return the value.
 */
- (BOOL)getBoolean:(nonnull NSString *)key orValue:(BOOL)defaultValue
    DEPRECATED_MSG_ATTRIBUTE("Use getBooleanForKey:defaultValue: instead");

/**
 * Sets the boolean value associated with `key`.
 *
 * @param key the key of the value to set.
 * @param value the boolean value to set.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` exists and is not a boolean.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)setBoolean:(nonnull NSString *)key value:(BOOL)value
         error:(NSError * _Nullable * _Nullable)error
    DEPRECATED_MSG_ATTRIBUTE("Use setBoolean:forKey:error: instead");

/**
 * Returns the numeric value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a number.
 * @return the value if present, otherwise `NAN.`.
 */
- (double)getNumber:(nonnull NSString *)key
              error:(NSError * _Nullable * _Nullable)error
    DEPRECATED_MSG_ATTRIBUTE("Use getNumberForKey:error: instead");

/**
 * Returns the numeric value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param defaultValue the value to return when `key` is not present.
 * @return the value.
 */
- (double)getNumber:(nonnull NSString *)key orValue:(double)defaultValue
    DEPRECATED_MSG_ATTRIBUTE("Use getNumberForKey:defaultValue: instead");

/**
 * Sets the numeric value associated with `key`.
 *
 * @param key the key of the value to set.
 * @param value the double value to set.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` exists and is not a number.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)setNumber:(nonnull NSString *)key value:(double)value
        error:(NSError * _Nullable * _Nullable)error
    DEPRECATED_MSG_ATTRIBUTE("Use setNumber:forKey:error: instead");

/**
 * Returns the string array value associated with `key`.
 *
 * @param key the key of the value to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a string array.
 * @return the value on success, otherwise `nil`.
 */
- (nullable NSArray<NSString *> *)getStringArray:(nonnull NSString *)key
                                           error:(NSError * _Nullable * _Nullable)error
    DEPRECATED_MSG_ATTRIBUTE("Use getStringArrayForKey:error: instead");

/**
 * Sets the string array value associated with `key`.
 *
 * @param key the key of the value to set.
 * @param value the value to set.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when entry at `key` exists and is not a string array.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)setStringArray:(nonnull NSString *)key value:(nonnull NSArray<NSString *> *)value
             error:(NSError * _Nullable * _Nullable)error
    DEPRECATED_MSG_ATTRIBUTE("Use setStringArray:forKey:error: instead");

/**
 * Returns a parameter set object representing the section associated with
 * `key`. Sections correspond to the hierarchical organization of keys
 * according to their dots. For example, if you have keys "a.b.c" and "a.b.d"
 * there is a section "a.b" that contains keys "c" and "d", as well as a
 * section "a" containing "b.c" and "b.d".
 *
 * @param key the key of the section to obtain.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `key` is not found.
 *   * IINKErrorRuntime when entry at `key` is not a section.
 * @return the section on success, otherwise `nil`.
 */
- (nullable IINKParameterSet *)getSection:(nonnull NSString *)key
                                    error:(NSError * _Nullable * _Nullable)error
    DEPRECATED_MSG_ATTRIBUTE("Use getSectionForKey:error: instead");

@end
