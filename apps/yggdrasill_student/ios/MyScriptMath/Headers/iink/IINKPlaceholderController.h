// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/IINKContentBlock.h>
#import <iink/IINKContentSelection.h>
#import <iink/IINKMimeType.h>


/**
 * Defines how a placeholder shall behave regarding user interactions.
 *
 * @since 3.2
 */
typedef struct _IINKPlaceholderInteractivityOptions
{
  BOOL selectOnTapAllowed;    /**< `YES` to allow selection on tap, otherwise `NO`. */
  BOOL selectOnLassoAllowed;  /**< `YES` to allow selection on lasso, otherwise `NO`. */
  BOOL resizeAllowed;         /**< `YES` to allow scaling, otherwise `NO`. */
  BOOL rotationAllowed;       /**< `YES` to allow rotations, otherwise `NO`. */
  BOOL keepAspectRatio;       /**< `YES` to keep the aspect ratio after transforms, otherwise `NO`. */
} IINKPlaceholderInteractivityOptions;

/**
 * A PlaceholderController allows to add and update placeholders in an editor.
 *
 * @since 3.2
 */
@interface IINKPlaceholderController : NSObject
{

}

//==============================================================================
#pragma mark - Methods
//==============================================================================

/**
 * Adds a new placeholder image to the part.
 *
 * @param box the position of the new image (view coordinates in pixel).
 * @param inputFile the image file to add.
 * @param mimeType the mime type that specifies the format of `inputFile`.
 * @param userData custom additional data.
 * @param selectOnAdd `true` to select the image when it is added, otherwise `false`.
 * @param interactivityOptions the allowed interactivity features.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when the dimensions of `box` are not valid.
 *   * IINKErrorInvalidArgument when `inputFile` does not exist.
 *   * IINKErrorInvalidArgument when `mimeType` is not an image type.
 *   * IINKErrorRuntime when editor is not associated with a Raw Content part.
 *   * IINKErrorRuntime when an I/O operation fails.
 * @return the block associated with the newly added placeholder on success, otherwise `nil`.
 */
- (nullable IINKContentBlock *)add:(CGRect)box
                         inputFile:(nonnull NSString *)inputFile
                          mimeType:(IINKMimeType)mimeType
                          userData:(nonnull NSString *)userData
                       selectOnAdd:(BOOL)selectOnAdd
              interactivityOptions:(IINKPlaceholderInteractivityOptions)interactivityOptions
                             error:(NSError * _Nullable * _Nullable)error;

/**
 * Updates the specified placeholder image and moves it to the front.
 *
 * @param placeholder the placeholder image to update.
 * @param box the position of the new image (view coordinates in pixel).
 * @param inputFile the image file to add.
 * @param mimeType the mime type that specifies the format of `inputFile`.
 * @param userData custom additional data.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `placeholder` is not a valid placeholder image.
 *   * IINKErrorInvalidArgument when the dimensions of `box` are not valid.
 *   * IINKErrorInvalidArgument when `inputFile` does not exist.
 *   * IINKErrorInvalidArgument when `mimeType` is not an image type.
 *   * IINKErrorRuntime when editor is not associated with a Raw Content part.
 */
- (BOOL)update:(nonnull NSObject<IINKIContentSelection> *)placeholder
           box:(CGRect)box
     inputFile:(nonnull NSString *)inputFile
      mimeType:(IINKMimeType)mimeType
      userData:(nonnull NSString *)userData
         error:(NSError * _Nullable * _Nullable)error
               NS_SWIFT_NAME(update(placeholder:box:inputFile:mimeType:userData:));

/**
 * Sets the custom user data of a placeholder image.
 *
 * @param placeholder the placeholder image to update.
 * @param userData custom additional data.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `placeholder` is not a valid placeholder image.
 *   * IINKErrorRuntime when editor is not associated with a Raw Content part.
 */
- (BOOL)setUserData:(nonnull NSObject<IINKIContentSelection> *)placeholder
           userData:(nonnull NSString *)userData
              error:(NSError * _Nullable * _Nullable)error
                    NS_SWIFT_NAME(set(placeholder:userData:));

/**
 * Returns the user data corresponding to a placeholder image.
 *
 * @param placeholder the placeholder image.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `placeholder` is not a valid placeholder image.
 *   * IINKErrorRuntime when editor is not associated with a Raw Content part.
 * @return the user data.
 */
- (nullable NSString *)getUserData:(nonnull NSObject<IINKIContentSelection> *)placeholder
                             error:(NSError * _Nullable * _Nullable)error
                                   NS_SWIFT_NAME(userData(placeholder:));


/**
 * Set a placeholder image visibility.
 *
 * @param placeholder the placeholder image to update.
 * @param visible `true` to set the placeholder image visble, otherwise it will be set invisible
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `placeholder` is not a valid placeholder image.
 *   * IINKErrorRuntime when editor is not associated with a Raw Content part.
 */
- (BOOL)setVisible:(nonnull NSObject<IINKIContentSelection> *)placeholder
           visible:(BOOL)visible
             error:(NSError * _Nullable * _Nullable)error
                   NS_SWIFT_NAME(set(placeholder:visible:));

/**
 * Returns the visiblity of a placeholder image.
 *
 * @param placeholder the placeholder image to update.
 * @return `YES` if the placeholder image is visible, otherwise `NO`.
 */
- (BOOL)isVisible:(nonnull NSObject<IINKIContentSelection> *)placeholder
                  NS_SWIFT_NAME(isVisible(placeholder:));

/**
 * Indicates whether a content selection is a placeholder.
 *
 * @param selection the content selection.
 * @return `YES` if the selection image is a placeholder, otherwise `NO`.
 */
- (BOOL)isPlaceholder:(nonnull NSObject<IINKIContentSelection> *)selection
                  NS_SWIFT_NAME(isPlaceholder(selection:));

@end
