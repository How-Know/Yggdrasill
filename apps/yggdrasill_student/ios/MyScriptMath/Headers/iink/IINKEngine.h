// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/IINKIRenderTarget.h>

@class IINKConfiguration;
@class IINKRenderer;
@class IINKEditor;
@class IINKContentPackage;
@class IINKParameterSet;
@class IINKRecognitionAssetsBuilder;
@class IINKRecognizer;
@class IINKToolController;
@class IINKOffscreenEditor;
@class IINKItemIdHelper;
@class IINKHandwritingGenerator;


/**
 * Represents a Package open option.
 * @since 1.2
 */
typedef NS_ENUM(NSUInteger, IINKPackageOpenOption)
{
  /** Open an existing package. */
  IINKPackageOpenOptionExisting,
  /** Create a new package if it does not exist. */
  IINKPackageOpenOptionCreate,
  /** Create a new package, failing if it already exists. */
  IINKPackageOpenOptionCreateNew,
  /** If the package already exists then its content is discarded. */
  IINKPackageOpenOptionTruncateExisting
};


/**
 * Wrapper object for an `IINKPackageOpenOption` value.
 */
@interface IINKPackageOpenOptionValue : NSObject
{

}

@property (nonatomic) IINKPackageOpenOption value;

/**
 * Create a new `IINKPackageOpenOptionValue` instance.
 * @param value the package open option value.
 */
- (nullable instancetype)initWithValue:(IINKPackageOpenOption)value;

/**
 * Builds a new `IINKPackageOpenOptionValue` instance.
 * @param value the package open option value.
 */
+ (nonnull IINKPackageOpenOptionValue *)valueWithPackageOpenOption:(IINKPackageOpenOption)value;

@end

/**
 * Represents the iink runtime environment.
 */
@interface IINKEngine : NSObject
{

}

//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The configuration associated with this engine.
 */
@property (nonatomic, readonly, nonnull) IINKConfiguration *configuration;

/**
 * Lists the part types supported by this engine.
 *
 * @return the list of supported part types.
 */
@property (nonatomic, readonly, nonnull) NSArray<NSString *> *supportedPartTypes;

/**
 * Lists the recognizer types supported by this engine.
 *
 * @return the list of supported recognizer types.
 *
 * @since 2.1
 */
@property (nonatomic, readonly, nonnull) NSArray<NSString *> *supportedRecognizerTypes;

/**
 * The version of iink SDK.
 *
 * @since 2.3
 */
@property (atomic, readonly, nonnull) NSString *version;

//==============================================================================
#pragma mark - Constructors
//==============================================================================

/**
 * Create a new `Engine` instance.
 * @param aCertificate certificate bytes data.
 */
- (nullable instancetype)initWithCertificate:(nonnull NSData *)aCertificate;


//==============================================================================
#pragma mark - Factories
//==============================================================================

/**
 * Creates a new renderer.
 *
 * @param dpiX the physical horizontal resolution of the display in dots per
 *   inch.
 * @param dpiY the physical vertical resolution of the display in dots per
 *   inch.
 * @param target the render target.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument if `dpiX` is not a number, is zero or is negative.
 *   * IINKErrorInvalidArgument if `dpiY` is not a number, is zero or is negative.
 * @return the newly created renderer, otherwise `nil`.
 */
- (nullable IINKRenderer *)createRendererWithDpiX:(float)dpiX dpiY:(float)dpiY
                                           target:(nullable id<IINKIRenderTarget>)target
                                            error:(NSError * _Nullable * _Nullable)error
                           NS_SWIFT_NAME(createRenderer(dpiX:dpiY:target:));

/**
 * Creates a new renderer.
 *
 * @param dpiX the physical horizontal resolution of the display in dots per
 *   inch.
 * @param dpiY the physical vertical resolution of the display in dots per
 *   inch.
 * @param target the render target.
 * @return the newly created renderer, otherwise `nil`.
 */
- (nullable IINKRenderer *)createRendererWithDpiX:(float)dpiX dpiY:(float)dpiY target:(nullable id<IINKIRenderTarget>)target
                            DEPRECATED_MSG_ATTRIBUTE("Use createRendererWithDpiX:dpiY:target:error: instead.");

/**
 * Creates a new tool controller.
 *
 * @return the newly created tool controller.
 *
 * @since 2.0
 */
- (nonnull IINKToolController *)createToolController;

/**
 * Creates a new editor.
 *
 * @param renderer the renderer to be used to display editor's content.
 * @param toolController the tool controller to be used to manage tools,
 *   or `nil` for default one.
 * @return the newly created editor on success, otherwise `nil`.
 */
- (nullable IINKEditor *)createEditor:(nonnull IINKRenderer *)renderer
                   withToolController:(nullable IINKToolController *)toolController
                         NS_SWIFT_NAME(createEditor(renderer:toolController:));

/**
 * Creates an empty parameter set.
 *
 * @return the newly created parameter set on success, otherwise `nil`.
 */
- (nullable IINKParameterSet *)createParameterSet;

/**
 * Creates a new recognition assets builder.
 *
 * @return the newly created recognition assets builder on success, otherwise `nil`.
 */
- (nullable IINKRecognitionAssetsBuilder *)createRecognitionAssetsBuilder;

/**
 * Creates a new recognizer.
 *
 * @param scaleX the scale to convert input horizontal coordinates unit into mm,
 *   such that (X coordinate unit * scaleX = mm).
 * @param scaleY the scale to convert input vertical coordinates unit into mm,
 *   such that (Y coordinate unit * scaleY = mm).
 * @param type the type of the new recognizer.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument if `scaleX` is not a number, is zero or is negative.
 *   * IINKErrorInvalidArgument if `scaleY` is not a number, is zero or is negative.
 *   * IINKErrorRuntime when `type` is "Text" and the search path of the configuration manager is empty.
 *   * IINKErrorRuntime when `type` is "Text", guides are enabled and the language does not allow guides.
 *   * IINKErrorRuntime when `type` is "Text", guides are enabled and the line gap is zero or is negative
 * @return the newly created recognizer, otherwise `nil`.
 *
 * @since 2.1
 */
- (nullable IINKRecognizer *)createRecognizerWithScaleX:(float)scaleX scaleY:(float)scaleY
                                                   type:(nonnull NSString *)type
                                                  error:(NSError * _Nullable * _Nullable)error
                           NS_SWIFT_NAME(createRecognizer(scaleX:scaleY:type:));

/**
 * Creates a new offscreen editor.
 *
 * @param scaleX the scale to convert input horizontal coordinates unit into mm,
 *   such that (X coordinate unit * scaleX = mm).
 * @param scaleY the scale to convert input vertical coordinates unit into mm,
 *   such that (Y coordinate unit * scaleY = mm).
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument if `scaleX` is not a number, is zero or is negative.
 *   * IINKErrorInvalidArgument if `scaleY` is not a number, is zero or is negative.
 * @return the newly created offscreen editor, otherwise `nil`.
 *
 * @since 2.1
 */
-(nullable IINKOffscreenEditor *)createOffscreenEditorWithScaleX:(float)scaleX scaleY:(float)scaleY
                                                           error:(NSError * _Nullable * _Nullable)error
                          NS_SWIFT_NAME(createOffscreenEditor(scaleX:scaleY:));

/**
 * Creates a new item id helper associated with an offscreen editor.
 *
 * @param offscreenEditor the associated offscreen editor.
 * @return the newly created item id helper, otherwise `nil`.
 *
 * @since 2.1
 */
-(nullable IINKItemIdHelper *)createItemIdHelperWithOffscreenEditor:(nonnull IINKOffscreenEditor *)offscreenEditor
                          NS_SWIFT_NAME(createItemIdHelper(offscreenEditor:));

/**
 * Creates a new handwriting generator.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when the handwriting generator cannot be created.
 * @return the newly created handwriting generator.
 *
 * @since 4.1
 */
-(nullable IINKHandwritingGenerator *)createHandwritingGenerator:(NSError * _Nullable * _Nullable)error
                                      NS_SWIFT_NAME(createHandwritingGenerator());

//==============================================================================
#pragma mark - Package Management
//==============================================================================

/**
 * Creates a new package.
 *
 * @param fileName the package file.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when a package with associated fileName already exists.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorInvalidArgument when a package associated with the same
 *   fileName is already opened, it can be accessed via a call to openPackage().
 * @return the package on success, otherwise `nil`.
 */
- (nullable IINKContentPackage *)createPackage:(nonnull NSString *)fileName
                                         error:(NSError * _Nullable * _Nullable)error;

/**
 * Opens the specified package.
 *
 * @param fileName the package file.
 * @param openOption the package open option.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime if `openOption` is `IINKPackageOpenOptionExisting`,
 *   when a package with associated fileName does not exist.
 *   * IINKErrorRuntime if `openOption` is `IINKPackageOpenOptionCreateNew`,
 *   when a package with associated fileName already exists.
 *   * IINKErrorInvalidArgument if `openOption` is `IINKPackageOpenOptionCreateNew`,
 *   when a package associated with the same fileName is already opened.
 *   * IINKErrorRuntime when an I/O operation fails.
 * @return the package on success, otherwise `nil`.
 */
- (nullable IINKContentPackage *)openPackage:(nonnull NSString *)fileName
                                  openOption:(IINKPackageOpenOption)openOption
                                       error:(NSError * _Nullable * _Nullable)error;

/**
 * Opens the specified package using `IINKPackageOpenOptionExisting`.
 *
 * @param fileName the package file.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when a package with associated fileName does not exist.
 *   * IINKErrorRuntime when an I/O operation fails.
 * @return the package on success, otherwise `nil`.
 */
- (nullable IINKContentPackage *)openPackage:(nonnull NSString *)fileName
                                       error:(NSError * _Nullable * _Nullable)error;

/**
 * Deletes the specified package.
 *
 * @param fileName the package file.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorInvalidArgument when a package associated with the same
 *   fileName is already opened.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)deletePackage:(nonnull NSString *)fileName
                error:(NSError * _Nullable * _Nullable)error;

@end
