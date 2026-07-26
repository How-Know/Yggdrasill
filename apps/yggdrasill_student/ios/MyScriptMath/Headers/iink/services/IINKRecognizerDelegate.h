// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>


@class IINKRecognizer;

/**
 * Error code used in IINKRecognizerDelegate::onError:code:message:
 *
 * @since 2.1
 */
typedef NS_ENUM(NSUInteger, IINKRecognizerError)
{
  /** Generic error, refer to the `message` parameter for more information. */
  IINKRecognizerErrorGeneric,
  /** The configuration bundle (*.conf file) cannot be found. */
  IINKRecognizerErrorConfigurationBundleNotFound,
  /** The configuration name cannot be found in the bundle (*.conf file). */
  IINKRecognizerErrorConfigurationNameNotFound,
  /** The configuration refers to a resource file that cannot be found. */
  IINKRecognizerErrorResourceNotFound,
  /** There was an error when parsing the *.conf files. */
  IINKRecognizerErrorInvalidConfiguration,
};

/**
 * The delegate interface for receiving recognizer events.
 *
 * @see IINKRecognizer
 *
 * @since 2.1
 */
@protocol IINKRecognizerDelegate <NSObject>

@required

//==============================================================================
#pragma mark - Required Methods
//==============================================================================

/**
 * Invoked when the result has changed.
 *
 * @param recognizer the recognizer.
 * @param result the new result as a JSON string.
 */
- (void)resultChanged:(nonnull IINKRecognizer*)recognizer result:(nonnull NSString *)result;

@optional

//==============================================================================
#pragma mark - Optional Methods
//==============================================================================

/**
 * Invoked when an error has occurred.
 *
 * @param recognizer the recognizer.
 * @param code the error code.
 * @param message the error message.
 */
- (void)onError:(nonnull IINKRecognizer*)recognizer
           code:(IINKRecognizerError)code
        message:(nonnull NSString*)message;

@end
