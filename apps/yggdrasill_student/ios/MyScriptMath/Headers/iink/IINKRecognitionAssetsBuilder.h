// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>


/**
 * Represents a recognition assets builder.
 */
@interface IINKRecognitionAssetsBuilder : NSObject
{

}


//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * Lists the recognition assets types supported by this recognition assets builder.
 *
 * @return the list of supported recognition assets types.
 */
@property (nonatomic, readonly, nonnull) NSArray<NSString *> *supportedRecognitionAssetsTypes;

/**
 * The last compilation errors.
 */
@property (nonatomic, readonly, nonnull) NSString *compilationErrors;


//==============================================================================
#pragma mark - Methods
//==============================================================================

/**
 * Get the list of symbols supported by a resource.
 *
 * @param resourcePath the path of the resource.
 * @return the list of supported symbols.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when the symbols could not be loaded from the resource.
 * @since 3.0
 */
- (nullable NSString *)getSupportedSymbols:(nonnull NSString *)resourcePath
                                     error:(NSError * _Nullable * _Nullable)error
                                     NS_SWIFT_NAME(getSupportedSymbols(resourcePath:));

/**
 * Compiles data into a recognition asset.
 *
 * @param type the type of asset that will be generated.
 * @param data the data to compile.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when type is not supported.
 *   * IINKErrorRuntime when the content of data could not be compiled into a recognition asset.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)compile:(nonnull NSString *)type
           data:(nonnull NSString *)data
          error:(NSError * _Nullable * _Nullable)error;

/**
 * Saves the previously compiled recognition asset.
 *
 * @param fileName the destination file.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when there is no valid recognition asset to store.
 *   * IINKErrorRuntime when an I/O operation fails.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)store:(nonnull NSString *)fileName
        error:(NSError * _Nullable * _Nullable)error;

@end
