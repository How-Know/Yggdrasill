// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/IINKMimeType.h>
#import <iink/IINKParameterSet.h>
#import <iink/IINKPointerEvent.h>
#import <iink/IINKIContentSelection.h>
#import <iink/services/IINKHandwritingProfile.h>


@class IINKEngine;
@class IINKContentSelection;

@protocol IINKHandwritingGeneratorDelegate;

/**
 * A builder for handwriting profiles.
 *
 * @since 4.1
 */
@interface IINKHandwritingProfileBuilder : NSObject
{

}

//==============================================================================
#pragma mark - Profile Generation
//==============================================================================

/**
 * The number of predefined writing profiles.
 *
 * @since 4.2
 */
- (NSInteger)predefinedProfileCount;

/**
 * Returns the predefined writing profile at the specified index.
 *
 * @param index the index of the predefined writing profile.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `index` is not in the expected range.
 * @return the predefined writing profile.
 *
 * @since 4.2
 */
- (nullable IINKHandwritingProfile *)getPredefinedProfileAt:(NSInteger)index
                                                      error:(NSError * _Nullable * _Nullable)error
                                     NS_SWIFT_NAME(predefinedProfile(at:));

/**
 * Creates a writing profile from a ContentSelection.
 *
 * @param selection the ContentSelection to be used for writing profile generation.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument  when `selection` is `nil` or does not contain enough recognized text.
 * @return the newly created writing profile.
 */
- (nullable IINKHandwritingProfile *)createFromSelection:(nonnull NSObject<IINKIContentSelection> *)selection
                                                   error:(NSError * _Nullable * _Nullable)error
                                     NS_SWIFT_NAME(create(fromSelection:));

/**
 * Creates a writing profile from a ContentPackage file name.
 *
 * @param fileName the ContentPackage file name.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when file cannot be opened.
 *  * IINKErrorInvalidArgument when file does not contain enough recognized text.
 * @return the newly created writing profile.
 */
- (nullable IINKHandwritingProfile *)createFromFile:(nonnull NSString *)fileName
                                              error:(NSError * _Nullable * _Nullable)error
                                     NS_SWIFT_NAME(create(fromFile:));

/**
 * Loads a writing profile from file.
 *
 * @param fileName the profile file name.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `fileName` is not a valid profile.
 * @return the newly loaded writing profile.
 */
- (nullable IINKHandwritingProfile *)load:(nonnull NSString *)fileName
                                    error:(NSError * _Nullable * _Nullable)error
                                     NS_SWIFT_NAME(load(_:));

/**
 * Stores a writing profile to file.
 *
 * @param profile the writing profile.
 * @param fileName the profile file name.
 * @param error the recipient for the error description object
 *  * IINKErrorInvalidArgument when `profile` is a predefined HandwritingProfile.
 *  * IINKErrorInvalidArgument when `fileName` is not a valid profile.
 */
- (BOOL)store:(nonnull IINKHandwritingProfile *)profile
                                         fileName:(nonnull NSString *)fileName
                                            error:(NSError * _Nullable * _Nullable)error
                                                NS_SWIFT_NAME(store(profile:toFile:));

@end
