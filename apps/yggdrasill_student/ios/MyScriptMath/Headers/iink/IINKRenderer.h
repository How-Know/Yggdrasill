// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <iink/IINKIRenderTarget.h>
#import <iink/IINKRendererDelegate.h>
#import <iink/graphics/IINKICanvas.h>
#import <iink/graphics/IINKIStrokerFactory.h>

/**
 * The renderer triggers display updates to a `IINKIRenderTarget` and implements
 * rendering to a `IINKICanvas`.
 */
@interface IINKRenderer : NSObject
{

}


//==============================================================================
#pragma mark - Delegate
//==============================================================================

/**
 * The delegate that will receive renderer events.
 */
@property (weak, nonatomic, nullable) id<IINKRendererDelegate> delegate;

/**
 * Adds a delegate to this editor without changing the `delegate` property.
 * @param delegate the delegate to add.
 */
- (void)addDelegate:(nonnull id<IINKRendererDelegate>)delegate;

/**
 * Removes a delegate added by `addDelegate:`
 * @param delegate the delegate to remove.
 */
- (void)removeDelegate:(nonnull id<IINKRendererDelegate>)delegate;


//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The physical horizontal resolution of the display in dots per inch, given at
 * creation of this renderer.
 */
@property (nonatomic, readonly) float dpiX;

/**
 * The physical vertical resolution of the display in dots per inch, given at
 * creation of this renderer.
 */
@property (nonatomic, readonly) float dpiY;

/**
 * The size of a pixel in model coordinates.
 */
@property (nonatomic, readonly) float pixelSize;

/**
 * The current zoom view scale.
 */
@property (nonatomic) float viewScale;

/**
 * The view offset.
 */
@property (nonatomic) CGPoint viewOffset;

/**
 * The transform that maps model coordinates to view coordinates.
 */

@property (nonatomic, readonly) CGAffineTransform viewTransform;

/**
 * The target that receives display update requests from this renderer.
 */
@property (nonatomic, readonly, nullable) id<IINKIRenderTarget> renderTarget;


//==============================================================================
#pragma mark - Zoom
//==============================================================================

/**
 * Increase zoom by a factor.
 *
 * @param factor the zoom modification factor.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `factor` is not a number or is negative.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)zoom:(float)factor error:(NSError * _Nullable * _Nullable)error;

/**
 * Increase zoom by a factor around a given point.
 *
 * @param at point around which to adjust the view (view coordinates in pixel).
 * @param factor the zoom modification factor.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `factor` is not a number or is negative.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)zoom:(CGPoint)at
          by:(float)factor
       error:(NSError * _Nullable * _Nullable)error
       NS_SWIFT_NAME(zoom(at:factor:));


//==============================================================================
#pragma mark - Draw Commands
//==============================================================================

/**
 * Requests asynchronous drawing of a region of the Model layer.
 * Completion of the drawing operation must be indicated by a call to
 * `commitModelDraw()`.
 *
 * @param region region of the part to draw (view coordinates in pixel).
 * @param canvas target canvas.
 *
 * @return the identifier of the drawing request.
 */
- (uint64_t)drawModelAsync:(CGRect)region canvas:(nonnull id<IINKICanvas>)canvas;

/**
 * Indicates that an asynchronous drawing of the Model Layer is over.
 *
 * @param identifier the identifier of the drawing request, as returned by
 *   `drawModelAsync()`.
 */
- (void)commitModelDraw:(uint64_t)identifier;

/**
 * Requests drawing of a region of the Model layer.
 *
 * @param region region of the part to draw (view coordinates in pixel).
 * @param canvas target canvas.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)drawModel:(CGRect)region canvas:(nonnull id<IINKICanvas>)canvas;

/**
 * Requests drawing of a region of the Capture layer.
 *
 * @param region region of the part to draw (view coordinates in pixel).
 * @param canvas target canvas.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)drawCaptureStrokes:(CGRect)region canvas:(nonnull id<IINKICanvas>)canvas;


//==============================================================================
#pragma mark - Stroker
//==============================================================================

/**
 * Registers a custom stroker factory.
 *
 * @param name the value of the -myscript-pen-brush css property that selects
 *   this stroker.
 * @param factory the user provided stroker factory.
 * @param error the recipient for the error description object.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)registerStroker:(nonnull NSString *)name
                factory:(_Nullable id<IINKIStrokerFactory>)factory
                  error:(NSError * _Nullable * _Nullable)error;

/**
 * Unregister custom stroker factory.
 *
 * @param name the stroker factory.
 */
- (void)unregisterStroker:(nonnull NSString *)name;

@end
