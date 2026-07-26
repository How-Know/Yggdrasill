// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <iink/IINKContentBlock.h>
#import <iink/IINKContentSelection.h>
#import <iink/IINKIImagePainter.h>
#import <iink/IINKEditorDelegate.h>
#import <iink/IINKError.h>
#import <iink/IINKMimeType.h>
#import <iink/IINKMathSolverController.h>
#import <iink/IINKParameterSet.h>
#import <iink/IINKPointerEvent.h>
#import <iink/text/IINKIFontMetricsProvider.h>
#import <iink/graphics/IINKRect.h>


@class IINKContentPart;
@class IINKEngine;
@class IINKRenderer;
@class IINKConfiguration;
@class IINKToolController;
@class IINKPlaceholderController;
@protocol IINKGestureDelegate;

/**
 * Error code returned checking if a transformation is allowed on a content selection.
 *
 * @see IINKEditor
 * @since 2.0
 */
typedef NS_ENUM(NSUInteger, IINKTransformError)
{
  /** The transform is allowed. */
  IINKTransformErrorAllowed             = 0,

  /** The transform is not supported on this content selection (internal error). */
  IINKTransformErrorUnsupported         = 1 << 0,
  /** The content selection is `nullptr`. */
  IINKTransformErrorNullSelection       = 1 << 1,
  /** The content selection contains blocks partially selected. */
  IINKTransformErrorPartialBlocks       = 1 << 2,
  /** The content selection contains multiple blocks. */
  IINKTransformErrorMultipleBlocks      = 1 << 3,
  /** The content selection contains beautified blocks. */
  IINKTransformErrorBeautifiedBlocks    = 1 << 4,
  /** The content selection contains text blocks. */
  IINKTransformErrorTextBlocks          = 1 << 5,
  /** The content selection contains math blocks. */
  IINKTransformErrorMathBlocks          = 1 << 6,
  /** The content selection contains drawing blocks. */
  IINKTransformErrorDrawingBlocks       = 1 << 7,
  /** The content selection has guides. */
  IINKTransformErrorGuides              = 1 << 8,
  /** The transform is invalid (cannot be decomposed). */
  IINKTransformErrorInvalid             = 1 << 9,
  /** The transform is non invertible. */
  IINKTransformErrorNonInvertible       = 1 << 10,
  /** The transform has a bad numeric value (infinite or NaN). */
  IINKTransformErrorBadNumeric          = 1 << 11,
  /** The transform has a rotation component. */
  IINKTransformErrorHasRotation         = 1 << 12,
  /** The transform has a scale component. */
  IINKTransformErrorHasScale            = 1 << 13,
  /** The transform has a negative scale component. */
  IINKTransformErrorHasNegativeScale    = 1 << 14,
  /** The transform has a shear component. */
  IINKTransformErrorHasShear            = 1 << 15,
  /** The transform has a translation component. */
  IINKTransformErrorHasTranslation      = 1 << 16,
};

/**
 * Wrapper object for an `IINKTransformError` value.
 */
@interface IINKTransformErrorValue : NSObject
{

}

@property (nonatomic) IINKTransformError value;

/**
 * Create a new `IINKTransformErrorValue` instance.
 * @param value the error value.
 */
- (nullable instancetype)initWithValue:(IINKTransformError)value;

/**
 * Builds a new `IINKTransformErrorValue` instance.
 * @param value the error value.
 */
+ (nonnull IINKTransformErrorValue *)valueWithError:(IINKTransformError)value;

@end

/**
 * Describes the selection modes.
 *
 * @since 2.0
 */
typedef NS_ENUM(NSUInteger, IINKContentSelectionMode)
{
  /** No active selection. */
  IINKContentSelectionModeNone      = 0,

  /** Active selection's mode is Lasso. */
  IINKContentSelectionModeLasso     = 1,

  /** Active selection's mode is Item. */
  IINKContentSelectionModeItem      = 2,

  /** Active selection's mode is Resize. */
  IINKContentSelectionModeResize    = 3,

  /** Active selection's mode is Reflow. */
  IINKContentSelectionModeReflow    = 4
};

/**
 * Wrapper object for an `IINKContentSelectionMode` value.
 */
@interface IINKContentSelectionModeValue : NSObject
{

}

@property (nonatomic) IINKContentSelectionMode value;

/**
 * Create a new `IINKContentSelectionModeValue` instance.
 * @param value the mode value.
 */
- (nullable instancetype)initWithValue:(IINKContentSelectionMode)value;

/**
 * Builds a new `IINKContentSelectionModeValue` instance.
 * @param value the mode value.
 */
+ (nonnull IINKContentSelectionModeValue *)valueWithMode:(IINKContentSelectionMode)value;

@end

/**
 * Predefined Text Box Formats.
 *
 * @since 2.0
 */
typedef NS_ENUM(NSUInteger, IINKTextFormat)
{
  /** Header 1 format. */
  IINKTextFormatH1                  = 0,
  /** Header 2 format. */
  IINKTextFormatH2                  = 1,
  /** Paragraph format. */
  IINKTextFormatParagraph           = 2,
  /** Bullet list format. */
  IINKTextFormatListBullet          = 3,
  /** Checkbox list format. */
  IINKTextFormatListCheckbox        = 4,
  /** Numbered list format. */
  IINKTextFormatListNumbered        = 5
};

/**
 * Represents a selection indentation levels.
 *
 * @since 2.1
 */
typedef struct _IINKIndentationLevels
{
  /** The lowest indentation level. */
  size_t low;
  /** The highest indentation level. */
  size_t high;
  /** The maximum indentation level. */
  size_t max;
} IINKIndentationLevels;

CG_INLINE IINKIndentationLevels
IINKIndentationLevelsMake(size_t low, size_t high, size_t max)
{
  IINKIndentationLevels t;
  t.low  = low;
  t.high = high;
  t.max  = max;
  return t;
}

/**
 * Wrapper object for an `IINKTextFormat` value.
 */
@interface IINKTextFormatValue : NSObject
{

}

@property (nonatomic) IINKTextFormat value;

/**
 * Create a new `IINKTextFormatValue` instance.
 * @param value the format type value.
 */
- (nullable instancetype)initWithValue:(IINKTextFormat)value;

/**
 * Builds a new `IINKTextFormatValue` instance.
 * @param value the format type value.
 */
+ (nonnull IINKTextFormatValue *)valueWithTextFormat:(IINKTextFormat)value;

@end


/**
 * Defines how the background image is fitted into the part.
 *
 * @since 4.5
 */
typedef NS_ENUM(NSUInteger, IINKImageFit)
{
  /** Stretch image to fill the part entirely, aspect ratio may not be preserved. */
  IINKImageFitFill    = 0,
  /** Fit the image by preserving the aspect ratio, the whole image will be visible, some empty space may remain. */
  IINKImageFitContain = 1,
  /** Fit the image by preserving the aspect ratio, the whole part will be covered but the image may be cropped. */
  IINKImageFitCover   = 2
};


/**
 * The Editor is the entry point to modify a part.
 * An editor is associated with a single part.
 *
 * @see IINKContentPart.
 */
@interface IINKEditor : NSObject
{

}


//==============================================================================
#pragma mark - Delegate
//==============================================================================

/**
 * The delegate that will receive editor events.
 */
@property (weak, nonatomic, nullable) id<IINKEditorDelegate> delegate;

/**
 * Adds a delegate to this editor without changing the `delegate` property.
 * @param delegate the delegate to add.
 */
- (void)addDelegate:(nonnull id<IINKEditorDelegate>)delegate;

/**
 * Removes a delegate added by `addDelegate:`
 * @param delegate the delegate to remove.
 */
- (void)removeDelegate:(nonnull id<IINKEditorDelegate>)delegate;

//==============================================================================
#pragma mark - Gesture Delegate
//==============================================================================

/**
 * The delegate that will receive gesture handler events.
 */
@property (weak, nonatomic, nullable) id<IINKGestureDelegate> gestureDelegate;

//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The `Engine` to which this editor is attached.
 */
@property (nonatomic, readonly, nonnull) IINKEngine *engine;

/**
 * The `Renderer` associated with this editor.
 */
@property (strong, nonatomic, readonly, nonnull) IINKRenderer *renderer;

/**
 * The part managed by this editor.
 */
@property (strong, nonatomic, nullable) IINKContentPart *part;

/**
 * Sets the part managed by this editor.
 *
 * @param part the part.
 * @param error the recipient for the error description object
 *
 *   * IINKErrorRuntime  when no `IFontMetricProvider` has been set,
 *   via `setFontMetricsProvider()`.
 *   * IINKErrorRuntime  when `part` is already bound.
 *   * IINKErrorRuntime  when this editor cannot be configured.
*/
- (BOOL)setPart:(nullable IINKContentPart*)part
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(part:));

/**
 * Sets the part managed by this editor.
 *
 * @param part the part.
 * @param forceReconfigure tells whether to force the reconfiguration or not.
 *   This call may trigger a complete reprocess of the `part`, interactivity
 *   will be limited until that processing is over.
 * @param error the recipient for the error description object
 *
 *   * IINKErrorRuntime  when no `IFontMetricProvider` has been set,
 *   via `setFontMetricsProvider()`.
 *   * IINKErrorRuntime  when `part` is already bound.
 *   * IINKErrorRuntime  when this editor cannot be configured.
 *
 * @since 4.5
*/
- (BOOL)setPart:(nullable IINKContentPart*)part
  forceReconfigure:(BOOL)forceReconfigure
             error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(part:forceReconfigure:));

/**
 * The configuration associated with this editor.
 */
@property (nonatomic, readonly, nonnull) IINKConfiguration *configuration;

/**
 * The tool controller associated with this editor.
 *
 * @since 2.0
 */
@property (nonatomic, readonly, nonnull) IINKToolController *toolController;

/**
 * The `PlaceholderController` associated with this editor.
 *
 * @since 3.2
 */
@property (nonatomic, readonly, nullable) IINKPlaceholderController *placeholderController;

/**
 * The `MathSolverController` associated with this editor.
 *
 * @since 4.0
 */
@property (nonatomic, readonly, nullable) IINKMathSolverController *mathSolverController;

//==============================================================================
#pragma mark - Content Manipulation
//==============================================================================

/**
 * Removes all content from the part.
 * @param error the error thrown if any
 */
- (BOOL)clearWithError:(NSError * _Nullable * _Nullable)error;

/**
 * Whether undo can be performed on the part or not.
 */
@property (nonatomic, readonly) BOOL canUndo;

/**
 * Undo the last action on part.
 */
- (void)undo;

/**
 * Whether redo can be performed on the part or not.
 */
@property (nonatomic, readonly) BOOL canRedo;

/**
 * Redo the last action reverted by `undo` on part.
 */
- (void)redo;

/**
 * The number of operations performed on the part, since content part was opened.
 *
 * @note the undo stack is partially purged from time to time to control memory consumption.
 *   The number of possible undo operations at a given time is `possibleUndoCount`,
 *   while the total number of operations since content part was opened is `undoStackIndex`.
 */
@property (nonatomic, readonly) NSInteger undoStackIndex;

/**
 * The number of operations that can be undone.
 */
@property (nonatomic, readonly) NSInteger possibleUndoCount;

/**
 * The number of operations that can be redone.
 */
@property (nonatomic, readonly) NSInteger possibleRedoCount;

/**
 * Returns the id of an undo or redo action, based on its position in the stack index.
 * Valid stack index values range from (current stack index - possible undo count) to (current stack index + possible redo count - 1).
 *
 * @param stackIndex the index in the stack of the undo/redo action to retrieve.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when `stackIndex` is invalid.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the id of the undo/redo operation at the specific index in the undo/redo stack.
 */
- (nullable NSString *)getUndoRedoIdAt:(int)stackIndex
                                 error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(undoRedoId(at:));

/**
 * Resets the undo/redo stack of this editor.
 *
 * @since 4.5
 */
- (void)clearUndoRedoStack;

//==============================================================================
#pragma mark - Pointer Events
//==============================================================================

/**
 * Registers a pointer down event.
 *
 * @param point pointer event coordinates (view coordinates in pixel).
 * @param t pointer event timestamp, in ms since Unix EPOCH.
 * @param f normalized pressure, in [0,1].
 * @param type the type of input.
 * @param pointerId the id of the pointer.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when pointerType is invalid.
 *   * IINKErrorInvalidArgument when x or y is not a number.
 *   * IINKErrorInvalidArgument when t exceeds year 9999.
 *   * IINKErrorInvalidArgument when f is not a number or is negative.
 *   * IINKErrorPointerSequence when `pointerDown()` has already been called.
 *   * IINKErrorRuntime in "Text Document" parts, when no view size is set.
 * @return the render item identifier of the starting stroke if any, otherwise
 *   an empty string.
 */
- (nullable NSString *)pointerDown:(CGPoint)point
                                at:(int64_t)t
                             force:(float)f
                              type:(IINKPointerType)type
                         pointerId:(NSInteger)pointerId
                             error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(pointerDown(point:timestamp:force:type:pointerId:));

/**
 * Registers a pointer down event.
 *
 * @param point pointer event coordinates (view coordinates in pixel).
 * @param t pointer event timestamp, in ms since Unix EPOCH.
 * @param f normalized pressure, in [0,1].
 * @param tilt the tilt in radians. 0 is perpendicular, Pi/2 if flat on screen.
 * @param orientation the orientation in radians. 0 is pointing up, -Pi/2 is left, Pi/2 is right, +/-Pi is down.
 * @param type the type of input.
 * @param pointerId the id of the pointer.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when pointerType is invalid.
 *   * IINKErrorInvalidArgument when x or y is not a number.
 *   * IINKErrorInvalidArgument when t exceeds year 9999.
 *   * IINKErrorInvalidArgument when f is not a number or is negative.
 *   * IINKErrorInvalidArgument when tilt is not a number or is outside 0..Pi/2.
 *   * IINKErrorInvalidArgument when orientation is not a number or is outside -Pi..Pi.
 *   * IINKErrorPointerSequence when `pointerDown()` has already been called.
 *   * IINKErrorRuntime in "Text Document" parts, when no view size is set.
 * @return the render item identifier of the starting stroke if any, otherwise
 *   an empty string.
 *
 * @since>4.0</since>
 */
- (nullable NSString *)pointerDown:(CGPoint)point
                                at:(int64_t)t
                             force:(float)f
                              tilt:(float)tilt
                       orientation:(float)orientation
                              type:(IINKPointerType)type
                         pointerId:(NSInteger)pointerId
                             error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(pointerDown(point:timestamp:force:tilt:orientation:type:pointerId:));

/**
 * Registers a pointer move event.
 *
 * @param point pointer event coordinates (view coordinates in pixel).
 * @param t pointer event timestamp, in ms since Unix EPOCH.
 * @param f normalized pressure, in [0,1].
 * @param type the type of input.
 * @param pointerId the id of the pointer.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when pointerType is invalid.
 *   * IINKErrorInvalidArgument when x or y is not a number.
 *   * IINKErrorInvalidArgument when t exceeds year 9999.
 *   * IINKErrorInvalidArgument when f is not a number or is negative.
 *   * IINKErrorInvalidArgument when stroke has too many points.
 *   * IINKErrorPointerSequence when `pointerDown()` has not been called before.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)pointerMove:(CGPoint)point
                 at:(int64_t)t
              force:(float)f
               type:(IINKPointerType)type
          pointerId:(NSInteger)pointerId
              error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(pointerMove(point:timestamp:force:type:pointerId:));

/**
 * Registers a pointer move event.
 *
 * @param point pointer event coordinates (view coordinates in pixel).
 * @param t pointer event timestamp, in ms since Unix EPOCH.
 * @param f normalized pressure, in [0,1].
 * @param tilt the tilt in radians. 0 is perpendicular, Pi/2 if flat on screen.
 * @param orientation the orientation in radians. 0 is pointing up, -Pi/2 is left, Pi/2 is right, +/-Pi is down.
 * @param type the type of input.
 * @param pointerId the id of the pointer.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when pointerType is invalid.
 *   * IINKErrorInvalidArgument when x or y is not a number.
 *   * IINKErrorInvalidArgument when t exceeds year 9999.
 *   * IINKErrorInvalidArgument when f is not a number or is negative.
 *   * IINKErrorInvalidArgument when tilt is not a number or is outside 0..Pi/2.
 *   * IINKErrorInvalidArgument when orientation is not a number or is outside -Pi..Pi.
 *   * IINKErrorInvalidArgument when stroke has too many points.
 *   * IINKErrorPointerSequence when `pointerDown()` has not been called before.
 * @return `YES` on success, otherwise `NO`.
 *
 * @since>4.0</since>
 */
- (BOOL)pointerMove:(CGPoint)point
                 at:(int64_t)t
              force:(float)f
               tilt:(float)tilt
        orientation:(float)orientation
               type:(IINKPointerType)type
          pointerId:(NSInteger)pointerId
              error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(pointerMove(point:timestamp:force:tilt:orientation:type:pointerId:));

/**
 * Registers a pointer up event.
 *
 * @param point pointer event coordinates (view coordinates in pixel).
 * @param t pointer event timestamp, in ms since Unix EPOCH.
 * @param f normalized pressure, in [0,1].
 * @param type the type of input.
 * @param pointerId the id of the pointer.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when pointerType is invalid.
 *   * IINKErrorInvalidArgument when x or y is not a number.
 *   * IINKErrorInvalidArgument when t exceeds year 9999.
 *   * IINKErrorInvalidArgument when f is not a number or is negative.
 *   * IINKErrorPointerSequence when `pointerDown()` has not been called before.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)pointerUp:(CGPoint)point
               at:(int64_t)t
            force:(float)f
             type:(IINKPointerType)type
        pointerId:(NSInteger)pointerId
            error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(pointerUp(point:timestamp:force:type:pointerId:));

/**
 * Registers a pointer up event.
 *
 * @param point pointer event coordinates (view coordinates in pixel).
 * @param t pointer event timestamp, in ms since Unix EPOCH.
 * @param f normalized pressure, in [0,1].
 * @param tilt the tilt in radians. 0 is perpendicular, Pi/2 if flat on screen.
 * @param orientation the orientation in radians. 0 is pointing up, -Pi/2 is left, Pi/2 is right, +/-Pi is down.
 * @param type the type of input.
 * @param pointerId the id of the pointer.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when pointerType is invalid.
 *   * IINKErrorInvalidArgument when x or y is not a number.
 *   * IINKErrorInvalidArgument when t exceeds year 9999.
 *   * IINKErrorInvalidArgument when f is not a number or is negative.
 *   * IINKErrorInvalidArgument when tilt is not a number or is outside 0..Pi/2.
 *   * IINKErrorInvalidArgument when orientation is not a number or is outside -Pi..Pi.
 *   * IINKErrorPointerSequence when `pointerDown()` has not been called before.
 * @return `YES` on success, otherwise `NO`.
 *
 * @since>4.0</since>
 */
- (BOOL)pointerUp:(CGPoint)point
               at:(int64_t)t
            force:(float)f
             tilt:(float)tilt
      orientation:(float)orientation
             type:(IINKPointerType)type
        pointerId:(NSInteger)pointerId
            error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(pointerUp(point:timestamp:force:tilt:orientation:type:pointerId:));

/**
 * Cancels an ongoing pointer trace.
 *
 * @param pointerId the id of the pointer, `-1` for all.
 * @param error the recipient for the error description object
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)pointerCancel:(NSInteger)pointerId
                error:(NSError * _Nullable * _Nullable)error;

/**
 * Sends a series of pointer events.
 *
 * @note this method can be used to perform batch recognition by representing
 *   the sequence of digital ink strokes as a series of pointer events and
 *   sending them with the gesture processing disabled.
 *
 * @param events the list of events (view coordinates in pixel).
 * @param count the event count.
 * @param processGestures tells whether to process gestures or not.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when a pointer event contains incorrect data.
 *   * IINKErrorInvalidArgument when a stroke has too many points.
 *   * IINKErrorInvalidArgument when events contain more than `20` strokes and processGestures is `true`.
 *   * IINKErrorPointerSequence when event sequence is not allowed.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)pointerEvents:(nonnull IINKPointerEvent *)events
                count:(NSInteger)count
    doProcessGestures:(BOOL)processGestures
                error:(NSError * _Nullable * _Nullable)error;



//==============================================================================
#pragma mark - ViewBox Control
//==============================================================================

/**
 * Sets the size of the view.
 *
 * @param viewSize the view size (view coordinates in pixel).
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `viewSize`'s width or height is negative.
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 */
- (BOOL)setViewSize:(CGSize)viewSize
              error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(viewSize:));
/**
 * Sets the size of the view.
 *
 * @param viewSize the view size (view coordinates in pixel).
 */
- (void)setViewSize:(CGSize)viewSize DEPRECATED_MSG_ATTRIBUTE("Use setViewSize:error: instead.");

/**
 * The size of the view (view coordinates in pixel).
 */
@property (nonatomic, readonly) CGSize viewSize;

/**
 * Clamps the supplied view offset to the area that ensures standard scrolling
 * behavior. For "Text" and "Text Document" it allows scrolling one screen outside
 * of the view box downward. For other part types it allows scrolling one screen
 * outside of the view box in each direction.
 *
 * @param viewOffset the view offset to clamp (document coordinates in mm).
 */
- (void)clampViewOffset:(CGPoint * _Nonnull)viewOffset;

/**
 * Whether scrolling on the part is allowed at this time.
 *
 * @note this applies for example when the editor is resizing or moving an
 *   object.
 */
@property (nonatomic, readonly, getter=isScrollAllowed) BOOL scrollAllowed;


//==============================================================================
#pragma mark - Theme
//==============================================================================

/**
 * The rendering theme style sheet, from a buffer containing
 * CSS styling information.
 */
@property (nonatomic, strong, nonnull) NSString *theme;

/**
 * Changes the rendering theme style sheet, from a buffer containing
 * CSS styling information.
 *
 * @param theme the style sheet, in CSS format.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `theme` is invalid.
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 */
- (BOOL)setTheme:(nullable NSString *)theme
           error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(theme:));


//==============================================================================
#pragma mark - Block Management
//==============================================================================

/**
 * The content block at the root of the current part.
 */
@property (nonatomic, strong, readonly, nullable) IINKContentBlock *rootBlock;

/**
 * Returns the content block associated with a given `id`.
 *
 * @param identifier the identifier of the block.
 * @return the content block associated with `id` or `nil` if there is no
 *   such block in the current part.
 */
- (nullable IINKContentBlock *)getBlockById:(nullable NSString *)identifier;

/**
 * Checks whether a selection is empty.
 *
 * @param selection the selection to check, `nil` means check full part.
 * @return `true` if selection is empty or invalid or editor is not associated with
 *   a part, otherwise `false`.
 */
- (BOOL)isEmpty:(nullable NSObject<IINKIContentSelection> *)selection;

/**
 * The types of blocks that can be added to the part.
 * @note to add a Placeholder block, please use the Editor's PlaceholderController.
 */
@property (nonatomic, readonly, nonnull) NSArray<NSString *> *supportedAddBlockTypes;

/**
 * Returns the supported format for adding a new block with data.
 *
 * @param type the type of the new block.
 *
 * @return an array of the supported mime types.
 */
- (nonnull NSArray<IINKMimeTypeValue *> *)getSupportedAddBlockDataMimeTypes:(nonnull NSString *)type
                                          NS_SWIFT_NAME(supportedAddBlockDataMimeTypes(forType:));


/**
 * Adds a new block to the part.
 *
 * @param position the approximative position of the new block (view coordinates in pixel).
 * @param type the type of the new block.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when type is not supported by current part
 *   type.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when a block already exists at this position,
 *   and is not a "Container" block.
 *   * IINKErrorRuntime when empty space around position is too small
 *   for a new block.
 *
 * @return block the newly added block on success, otherwise `nil`.
 */
- (nullable IINKContentBlock *)addBlock:(CGPoint)position
                                   type:(nonnull NSString *)type
                                  error:(NSError * _Nullable * _Nullable)error
                               NS_SWIFT_NAME(addBlock(at:type:));

/**
 * Adds a new block to the part and fills it with data.
 *
 * @param position the approximative position of the new block (view coordinates in pixel).
 * @param type the type of the new block.
 * @param mimeType the mime type that specifies the format of `data`.
 * @param data the data to put i the new block.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when type is not supported by current part
 *   type.
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when a block already exists at this position,
 *   and is not a "Container" block.
 *   * IINKErrorRuntime when empty space around position is too small
 *   for a new block.
 *   * IINKErrorRuntime when the content of `data` could not be added to
 *   the new block.
 *
 * @return block the newly added block on success, otherwise `nil`.
 */
- (nullable IINKContentBlock *)addBlock:(CGPoint)position
                                   type:(nonnull NSString *)type
                               mimeType:(IINKMimeType)mimeType
                                   data:(nonnull NSString *)data
                                  error:(NSError * _Nullable * _Nullable)error
                               NS_SWIFT_NAME(addBlock(position:type:mimeType:data:));

/**
 * Adds a new image to the part.
 *
 * @note in a "Text Document" part, this method creates a new "Drawing" block in which
 *   the image will be added.
 *
 * @param position the approximative position of the new image (view coordinates in pixel).
 * @param file the image file to add.
 * @param mimeType the mime type that specifies the format of `inputFile`.
 *   * IINKErrorInvalidArgument when `inputFile` does not exist.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `mimeType` is not an image type.
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when a block already exists at this position,
 *   and is not a "Container" block.
 *   * IINKErrorRuntime when empty space around position is too small
 *   for a new block.
 *   * IINKErrorRuntime when an I/O operation fails.
 *
 * @return the block associated with the newly added image on success, otherwise `nil`.
 *   In a ContentPart of type "Text Document", the block will be of type "Drawing".
 */
- (nullable IINKContentBlock *)addImage:(CGPoint)position
                                   file:(nonnull NSString *)file
                               mimeType:(IINKMimeType)mimeType
                                  error:(NSError * _Nullable * _Nullable)error
                               NS_SWIFT_NAME(addImage(position:file:mimeType:));

/**
 * Sets the background image for this part.
 *
 * @param file the image file to use as background, leave empty to remove the background image.
 * @param mimeType the mime type that specifies the format of `file`.
 * @param fit the `IINKImageFit` mode to apply when fitting the background image into the part.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when part is not a fixed page size part.
 *   * IINKErrorInvalidArgument when `mimeType` is not an image type.
 *   * IINKErrorInvalidArgument when `fit` is not a valid `IINKImageFit` value.
 *   * IINKErrorRuntime when `file` does not exist.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *
 * @since 4.5
 */
- (BOOL)setBackgroundImage:(nonnull NSString *)file
                  mimeType:(IINKMimeType)mimeType
                       fit:(IINKImageFit)fit
                     error:(NSError * _Nullable * _Nullable)error
               NS_SWIFT_NAME(setBackgroundImage(file:mimeType:fit:));

/**
 * Gets the background image for this part.
 * Image can then be retrieved via `IINKContentPackage.extractObject()`.
 *
 * @return the url associated with the background image, or an empty string if no background image is set.
 *
 * @since 4.5
 */
- (nonnull NSString *)backgroundImage
    NS_SWIFT_NAME(backgroundImage());

/**
 * Erases a content selection from the part.
 *
 * @param selection the content selection to erase.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when selection is `nil`.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @since>2.0</since>
 */
- (BOOL)erase:(nonnull NSObject<IINKIContentSelection> *)selection
        error:(NSError * _Nullable * _Nullable)error;

/**
 * Return the block at the given position, or `nil` if there is no block
 * at that position.
 *
 * @param position the hit position coordinates (view coordinates in pixel).
 *
 * @return the block below hit position, or `nil` if no block was found.
 */
- (nullable IINKContentBlock *)hitBlock:(CGPoint)position;

/**
 * Returns the lowest sub block at the given position, or `nil` if there is no block
 * at that position.
 *
 * @param position the hit position coordinates (view coordinates in pixel).
 *
 * @return the lowest sub block below hit position, or `nil` if no block was found.
 *
 * @since 4.1
 */
-(nullable IINKContentBlock*)hitSubBlock:(CGPoint)position;


//==============================================================================
#pragma mark - Convert & Import/Export
//==============================================================================

/**
 * Returns the supported target conversion states for the specified selection.
 *
 * @param selection the selection for which the supported target conversion states are
 *   requested, `nil` means full part.
 *
 * @return an array of the supported target conversion states.
 */
- (nonnull NSArray<IINKConversionStateValue *> *)getSupportedTargetConversionState:(nullable NSObject<IINKIContentSelection> *)selection
                                                 NS_SWIFT_NAME(supportedTargetConversionState(forSelection:));
/**
 * Converts the specified content to digital form.
 *
 * @param selection the selection to convert, `nil` means convert full
 *   part.
 * @param targetState the target conversion state for the selection.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorInvalidArgument when the target conversion state is not
 *   reachable from the current state of the specified selection.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)convert:(nullable NSObject<IINKIContentSelection> *)selection
    targetState:(IINKConversionState)targetState
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(convert(selection:targetState:));

/**
 * Returns the supported export formats for specified content.
 *
 * @param selection the block to request, `nil` means full part.
 * @return an array of the supported mime types.
 */
- (nonnull NSArray<IINKMimeTypeValue *> *)getSupportedExportMimeTypes:(nullable NSObject<IINKIContentSelection> *)selection
                                          NS_SWIFT_NAME(supportedExportMimeTypes(forSelection:));

/**
 * Exports the specified content.
 *
 * @note the method is named `export_` because the C++ standard defines
 * `export` as a keyword.
 *
 * @param selection the selection to export, `nil` means export full part.
 * @param mimeType the mime type that specifies the output format.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when the specified mime type is not supported.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorRuntime when there are some ongoing operations on the part
 *   that prevent export, see `idle`.
 * @return the exported content on success, otherwise `nil`.
 */
- (nullable NSString *)export_:(nullable NSObject<IINKIContentSelection> *)selection
                      mimeType:(IINKMimeType)mimeType
                         error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(export(selection:mimeType:));

/**
 * Exports the specified content.
 *
 * @note the method is named `export_` because the C++ standard defines
 * `export` as a keyword.
 *
 * @param selection the selection to export, `nil` means export full part.
 * @param file the file to export to.
 * @param imagePainter an image painter that is required for some output
 *  formats. If you know that the specified output format does not require it you
 *  can leave it null.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorRuntime when imagePainter does not create the expected file.
 *   * IINKErrorRuntime when there are some ongoing operations on the part
 *   that prevent export, see `idle`.
 *   * IINKErrorInvalidArgument when `outputFile` is invalid.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)export_:(nullable NSObject<IINKIContentSelection> *)selection
         toFile:(nonnull NSString *)file
   imagePainter:(nullable id<IINKIImagePainter>)imagePainter
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(export(selection:destinationFile:imagePainter:));

/**
 * Exports the specified content.
 *
 * @note the method is named `export_` because the C++ standard defines
 * `export` as a keyword.
 *
 * @param selection the selection to export, `nil` means export full part.
 * @param file the file to export to.
 * @param mimeType the mime type that specifies the output format.
 * @param imagePainter an image painter that is required for some output
 *  formats. If you know that the specified output format does not require it you
 *  can leave it null.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when the specified mime type is not supported.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorRuntime when imagePainter does not create the expected file.
 *   * IINKErrorRuntime when there are some ongoing operations on the part
 *   that prevent export, see `idle`.
 *   * IINKErrorInvalidArgument when `outputFile` is invalid.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)export_:(nullable NSObject<IINKIContentSelection> *)selection
         toFile:(nonnull NSString *)file
       mimeType:(IINKMimeType)mimeType
   imagePainter:(nullable id<IINKIImagePainter>)imagePainter
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(export(selection:destinationFile:mimeType:imagePainter:));

/**
 * Exports the specified content.
 *
 * @note the method is named `export_` because the C++ standard defines
 * `export` as a keyword.
 *
 * @param selection the selection to export, `nil` means export full part.
 * @param mimeType the mime type that specifies the output format.
 * @param overrideConfiguration the extra configuration used when exporting.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when the specified mime type is not supported.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorRuntime when there are some ongoing operations on the part
 *   that prevent export, see `idle`.
 *   * IINKErrorInvalidArgument when there is nothing to export.
 *   * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 * @return the exported content on success, otherwise `nil`.
 *
 * @since 1.2
 */
- (nullable NSString *)export_:(nullable NSObject<IINKIContentSelection> *)selection
                      mimeType:(IINKMimeType)mimeType
         overrideConfiguration:(nonnull IINKParameterSet *)overrideConfiguration
                         error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(export(selection:mimeType:overrideConfiguration:));

/**
 * Exports the specified content.
 *
 * @note the method is named `export_` because the C++ standard defines
 * `export` as a keyword.
 *
 * @param selection the selection to export, `nil` means export full part.
 * @param file the file to export to.
 * @param imagePainter an image painter that is required for some output
 *  formats. If you know that the specified output format does not require it you
 *  can leave it null.
 * @param overrideConfiguration the extra configuration used when exporting.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorRuntime when imagePainter does not create the expected file.
 *   * IINKErrorRuntime when there are some ongoing operations on the part
 *   that prevent export, see `idle`.
 *   * IINKErrorInvalidArgument when there is nothing to export.
 *   * IINKErrorInvalidArgument when `outputFile` is invalid.
 *   * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 * @return `YES` on success, otherwise `NO`.
 *
 * @since 1.2
 */
- (BOOL)export_:(nullable NSObject<IINKIContentSelection> *)selection
         toFile:(nonnull NSString *)file
   imagePainter:(nullable id<IINKIImagePainter>)imagePainter
overrideConfiguration:(nonnull IINKParameterSet *)overrideConfiguration
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(export(selection:destinationFile:imagePainter:overrideConfiguration:));

/**
 * Exports the specified content.
 *
 * @note the method is named `export_` because the C++ standard defines
 * `export` as a keyword.
 *
 * @param selection the selection to export, `nil` means export full part.
 * @param file the file to export to.
 * @param mimeType the mime type that specifies the output format.
 * @param imagePainter an image painter that is required for some output
 *  formats. If you know that the specified output format does not require it you
 *  can leave it null.
 * @param overrideConfiguration the extra configuration used when exporting.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when the specified mime type is not supported.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorRuntime when imagePainter does not create the expected file.
 *   * IINKErrorRuntime when there are some ongoing operations on the part
 *   that prevent export, see `idle`.
 *   * IINKErrorInvalidArgument when there is nothing to export.
 *   * IINKErrorInvalidArgument when `outputFile` is invalid.
 *   * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 * @return `YES` on success, otherwise `NO`.
 *
 * @since 1.2
 */
- (BOOL)export_:(nullable NSObject<IINKIContentSelection> *)selection
         toFile:(nonnull NSString *)file
       mimeType:(IINKMimeType)mimeType
   imagePainter:(nullable id<IINKIImagePainter>)imagePainter
overrideConfiguration:(nonnull IINKParameterSet *)overrideConfiguration
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(export(selection:destinationFile:mimeType:imagePainter:overrideConfiguration:));

/**
 * Returns the supported import formats for specified content.
 *
 * @param selection the selection to request, `nil` means full part.
 * @return an array of the supported mime types.
 */
- (nonnull NSArray<IINKMimeTypeValue *> *)getSupportedImportMimeTypes:(nullable NSObject<IINKIContentSelection> *)selection
                                          NS_SWIFT_NAME(supportedImportMimeTypes(forSelection:));

/**
 * Imports data into the part, or a selection.
 *
 * @param mimeType the mime type that specifies the format of `data`.
 * @param data the data to import.
 * @param selection the target selection, or `nil` to let editor detect the target.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when the specified mime type is not supported.
 *   * IINKErrorRuntime when `data` could not be imported.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)import_:(IINKMimeType)mimeType
           data:(nonnull NSString *)data
      selection:(nullable NSObject<IINKIContentSelection> *)selection
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(import(mimeType:data:selection:));

/**
 * Imports data into the part, or a selection.
 *
 * @param mimeType the mime type that specifies the format of `data`.
 * @param data the data to import.
 * @param selection the target selection, or `nil` to let editor detect the target.
 * @param overrideConfiguration the extra configuration used when importing.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when the specified mime type is not supported.
 *   * IINKErrorRuntime when `data` could not be imported.
 *   * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)import_:(IINKMimeType)mimeType
           data:(nonnull NSString *)data
      selection:(nullable NSObject<IINKIContentSelection> *)selection
overrideConfiguration:(nonnull IINKParameterSet *)overrideConfiguration
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(import(mimeType:data:selection:overrideConfiguration:));


//==============================================================================
#pragma mark - Copy-Paste
//==============================================================================

/**
 * Copies a block to the internal clipboard.
 *
 * @param selection the selection to copy, `nil` means full part.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when selection cannot be copied.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)copy:(nonnull NSObject<IINKIContentSelection> *)selection
       error:(NSError * _Nullable * _Nullable)error;

/**
 * Pastes the content of the internal clipboard at a given position.
 * Internal clipboard is filled by calling `copy()`. If internal clipboard is
 * empty, this does nothing.
 *
 * @note following limitation applies: the part managed by this editor must
 *   be a "Text Document" and clipboard must contain a single block, that is
 *   not a "Container", from a "Text Document".
 *
 * @param position the target pasted block coordinates (view coordinates in pixel).
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when content of the clipboard cannot be pasted on
 *   the part.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)paste:(CGPoint)position
        error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(paste(at:));


//==============================================================================
#pragma mark - Concurrency
//==============================================================================

/**
 * Whether part modification operations are over.
 */
@property (nonatomic, readonly) BOOL idle;

/**
 * Waits until part modification operations are over.
 */
- (void)waitForIdle;


//==============================================================================
#pragma mark - Font Layouting
//==============================================================================

/**
 * Sets a font metrics provider to this editor.
 *
 * @param fontMetricsProvider a `IINKIFontMetricsProvider`.
 */
- (void)setFontMetricsProvider:(nonnull id<IINKIFontMetricsProvider>)fontMetricsProvider
        NS_SWIFT_NAME(set(fontMetricsProvider:));

//==============================================================================
#pragma mark - Stroking
//==============================================================================

/**
 * Draws pointer events, with current editor style settings, on the given canvas.
 *
 * @param events the list of events (view coordinates in pixel).
 * @param count the event count.
 * @param canvas the canvas on which editor should send the drawing commands.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorInvalidArgument when a pointer event contains incorrect data.
 *   * IINKErrorInvalidArgument when a stroke has too many points.
 *   * IINKErrorPointerSequence when events sequence is not allowed.
 * @return `YES` on success, otherwise `NO`.
 *
 * @since 1.5.1
 */
- (BOOL)drawStroke:(nonnull IINKPointerEvent *)events
             count:(NSInteger)count
            canvas:(nonnull id<IINKICanvas>)canvas
             error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(drawStroke(events:count:canvas:));

//==============================================================================
#pragma mark - Selection Manipulation
//==============================================================================

/**
 * Tells if this editor has an active content selection.
 *
 * @since 2.0
 */
@property (nonatomic, readonly) BOOL hasSelection;

/**
 * The active selection associated with this editor.
 *
 * @since 2.0
 */
@property (weak, nonatomic, nullable) NSObject<IINKIContentSelection> * selection;

/**
 * Sets the specified content selection as the active content selection in this editor.
 *
 * @note it unsets the active content selection if the specified content selection is empty or `nil`.
 *
 * @param selection the content selection to set as active.
 * @param mode the selection mode to set on the selection, `NONE` for default mode.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when the mode is not supported.
 *   * IINKErrorRuntime when selection is not valid.
 *
 * @since 4.5
 */
- (BOOL)setSelection:(nullable NSObject<IINKIContentSelection> *)selection
            withMode:(IINKContentSelectionMode)mode
               error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(selection:withMode:));

/**
 * Returns the active content selection at the given position, or `nil` if there is
 * no active content selection at that position.
 *
 * @param position the hit position coordinates (view coordinates in pixel).
 * @return the content selection below the hit position (i.e. the active content selection),
 *   otherwise `nil`.
 *
 * @since 2.0
 */
- (nullable NSObject<IINKIContentSelection> *)hitSelection:(CGPoint)position;

/**
 * Returns the content block ids intersecting with the specified content selection.
 *
 * @param selection the content selection on which to get the intersecting block ids.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return an array that contains all the content block ids intersecting with the content selection.
 *
 * @since 2.0
 */
- (nullable NSArray<NSString *> *)getIntersectingBlocks:(nonnull NSObject<IINKIContentSelection> *)selection
                                                  error:(NSError * _Nullable * _Nullable)error
                                  NS_SWIFT_NAME(intersectingBlocks(forSelection:));

/**
 * Returns the content block ids included in the specified content selection.
 *
 * @param selection the content selection on which to get the included block ids.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return an array that contains all the content block ids included in the content selection.
 *
 * @since 2.0
 */
- (nullable NSArray<NSString *> *)getIncludedBlocks:(nonnull NSObject<IINKIContentSelection> *)selection
                                              error:(NSError * _Nullable * _Nullable)error
                                  NS_SWIFT_NAME(includedBlocks(forSelection:));

/**
 * Checks if a transformation is allowed on a content selection.
 *
 * @param transform the transformation to check.
 * @param selection the content selection on which to check the transformation.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return an IINKTransformErrorValue object containing error code from enum `IINKTransformError`.
 *
 * @since 2.0
 */
- (nullable IINKTransformErrorValue*)getTransformStatus:(CGAffineTransform)transform
                                              selection:(nonnull NSObject<IINKIContentSelection> *)selection
                                                  error:(NSError * _Nullable * _Nullable)error
                                     NS_SWIFT_NAME(transformStatus(forTransform:selection:));

/**
 * Transforms a selection.
 *
 * @param transform the transformation to apply.
 * @param selection the content selection on which to apply the transformation.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when the transform is not allowed on the content selection.
 *   * IINKErrorInvalidArgument when transform is not valid for this operation.
 *
 * @since 2.0
 */
- (BOOL)applyTransform:(CGAffineTransform)transform
                    on:(nonnull NSObject<IINKIContentSelection> *)selection
                 error:(NSError * _Nullable * _Nullable)error;

/**
 * Applies CSS style properties to a content selection.
 *
 * @param style the CSS style properties to apply.
 * @param selection the content selection on which to apply the style.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *
 * @since 2.0
 */
- (BOOL)applyStyle:(nonnull NSString *)style
                on:(nonnull NSObject<IINKIContentSelection> *)selection
             error:(NSError * _Nullable * _Nullable)error;

/**
 * Returns the supported text formats for specified content selection.
 *
 * @param selection the content selection on which to apply the format.
 * @return an array of the supported text formats.
 *
 * @since 2.0
 */
- (nonnull NSArray<IINKTextFormatValue *> *)getSupportedTextFormats:(nonnull NSObject<IINKIContentSelection> *)selection
                                            NS_SWIFT_NAME(supportedTextFormats(forSelection:));

/**
 * Applies Format to all text blocks in selection.
 *
 * @param format the text format value.
 * @param selection the content selection on which to apply the format.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *
 * @since 2.0
 */
- (BOOL)setTextFormat:(IINKTextFormat)format
                   on:(nonnull NSObject<IINKIContentSelection> *)selection
                error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(textFormat:selection:));

/**
 * Returns the selection mode of the active content selection associated with this editor.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the selection mode of the current content selection.
  *
 * @since 2.0
 */
- (nullable IINKContentSelectionModeValue *)getSelectionModeWithError:(NSError * _Nullable * _Nullable)error
                                            NS_SWIFT_NAME(selectionMode());

/**
 * Sets the specified selection mode to the active content selection associated with this editor.
 *
 * @param mode the selection mode to set on the active content selection.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when the mode is not supported.
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when editor has no active selection.
 *
 * @since 2.0
 */
- (BOOL)setSelectionMode:(IINKContentSelectionMode)mode
                   error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(mode:));

/**
 * Returns the available selection modes for the active content selection associated with this editor.
 *
 * @return the selection mode of the current content selection.
 *
 * @since 2.0
 */
- (nonnull NSArray<IINKContentSelectionModeValue*> *)getAvailableSelectionModes;

/**
 * Returns the available selection modes for the specified content selection.
 *
 * @param selection the content selection on which to get the modes, `nil` for the active selection.
 *
 * @return the selection mode of the current content selection.
 *
 * @since 4.5
 */
- (nonnull NSArray<IINKContentSelectionModeValue*> *)getAvailableSelectionModes:(nullable NSObject<IINKIContentSelection> *)selection;

/**
 * Sets a selection to the specified type.
 *
 * @param type the content type to set. See {@link #getAvailableSelectionTypes()}.
 * @param selection the content selection on which to set the type.
 * @param forceSingleBlock `YES` to force converting the selection to a single block, `NO` otherwise.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when the type is not supported.
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when selection is not valid.
 *   * IINKErrorRuntime when selection is not compatible with the type.
 *
 * @since 2.0.1
 */
- (BOOL)setType:(nonnull NSString *)type
   forSelection:(nonnull NSObject<IINKIContentSelection> *)selection
forceSingleBlock:(BOOL)forceSingleBlock
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(type:selection:forceSingleBlock:));

/**
 * Returns the available types for a selection.
 *
 * @param selection the content selection on which to get the types.
 *
 * @return a vector that contains all the available selection types.
 *
 * @since 2.0.1
 */
- (nonnull NSArray<NSString*> *)getAvailableSelectionTypes:(nullable NSObject<IINKIContentSelection> *)selection;

/**
 * @warning This is a Beta API.
 *
 * Returns the indentation levels of a selection.
 *
 * @param selection the content selection on which to get indentation levels, `nil` means full part.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when selection is not valid.
 *   * IINKErrorRuntime when selection is empty.
 *
 * @return the indentation levels of the selection.
 *
 * @since 2.1
 */
- (IINKIndentationLevels)getIndentationLevels:(nullable NSObject<IINKIContentSelection> *)selection
                                        error:(NSError * _Nullable * _Nullable)error
                         NS_SWIFT_NAME(indent(forSelection:error:));

/**
 * @warning This is a Beta API.
 *
 * Indents/de-indents a selection by the specified offset.
 *
 * @note resulting indentation levels will be clamped to `[0, max_indentation[`.
 *  See {@link #getIndentationLevels()}.
 *
 * @param selection the content selection to indent/de-indent.
 * @param offset the number of levels to indent/de-indent the selection.
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when a sequence of pointer events is ongoing.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when selection is not valid.
 *   * IINKErrorRuntime when selection is empty.
 *   * IINKErrorRuntime when selection is not indentable.
 *
 * @since 2.1
 */
- (BOOL)indent:(nullable NSObject<IINKIContentSelection> *)selection
        offset:(int)offset
         error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(indent:selection:offset:));

/**
 * Returns the bounding box of the given selection.
 *
 * @param selection the content selection for which the box is requested.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when selection is not valid.
 *   * IINKErrorRuntime when selection is empty.
 *
 * @return the bounding box of the selection.
 *
 * @since 3.0
 */
- (nullable IINKRect*)getBox:(nullable NSObject<IINKIContentSelection> *)selection
                       error:(NSError * _Nullable * _Nullable)error
                      NS_SWIFT_NAME(box(forSelection:));

/**
 * Returns the current conversion state of this selection as a bitwise or combination
 * IINKConversionState values.
 *
 * @param selection the content selection for which the conversion state is requested.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when selection is not valid.
 *   * IINKErrorRuntime when selection is empty.
 *
 * @return the conversion state of the selection.
 * @since 3.0
 */
- (nullable IINKConversionStateValue *)getConversionState:(nullable NSObject<IINKIContentSelection> *)selection
                                                    error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(conversionState(forSelection:));

@end
